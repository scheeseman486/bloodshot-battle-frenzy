@tool
class_name CdAssetCache
extends RefCounted
## Runtime-only derived assets, never a replacement for mounting original media.
## The file contains primitive data and whitelisted asset records, not serialized
## scripts/objects. Mutable palettes are reconstructed privately for each source.
const ImmutableTexture = preload("res://scripts/assets/cd_immutable_texture.gd")
const VERSION := 1
const HEADER := 88
const MAX_BYTES := 256 * 1024 * 1024
const MAX_NODES := 65536
const DECODER_DEPENDENCIES := [
	"res://scripts/audio/md_audio_catalog.gd",
	"res://scripts/presentation/cd_hud_model.gd",
	"res://scripts/presentation/cd_menu_palette.gd",
	"res://scripts/presentation/cd_text_noise.gd",
	"res://scripts/presentation/cd_pickup_static.gd"
]
const SCRIPTS := {
	"res://scripts/assets/cd_level_data.gd": preload("res://scripts/assets/cd_level_data.gd"),
	"res://scripts/assets/cd_actor_catalog.gd": preload("res://scripts/assets/cd_actor_catalog.gd"),
	"res://scripts/assets/cd_behaviour_tables.gd":
	preload("res://scripts/assets/cd_behaviour_tables.gd"),
	"res://scripts/assets/cd_palette_data.gd": preload("res://scripts/assets/cd_palette_data.gd"),
	"res://scripts/assets/cd_ui_catalog.gd": preload("res://scripts/assets/cd_ui_catalog.gd"),
	"res://scripts/assets/cd_frontend_catalog.gd":
	preload("res://scripts/assets/cd_frontend_catalog.gd"),
	"res://scripts/assets/cd_small_font_catalog.gd":
	preload("res://scripts/assets/cd_small_font_catalog.gd"),
	"res://scripts/assets/cd_audio_catalog.gd": preload("res://scripts/assets/cd_audio_catalog.gd")
}
static var _documents: Dictionary = {}
static var _graphics: Dictionary = {}
static var _prepared: Dictionary = {}
static var _resident_views: Dictionary = {}
var last_error := ""
var path := ""
var stats: Dictionary = {}
var _identity := ""
var _decoder := ""
var _document: Dictionary = {}
var _objects: Dictionary = {}
var _lookups: Dictionary = {}
var _writing: Dictionary = {}
var _references: Dictionary = {}
var _values := 0


func open(identity: String, decoder: String, directory: String = "user://asset-cache") -> bool:
	last_error = ""
	_document = {}
	_objects.clear()
	_lookups.clear()
	_identity = identity
	_decoder = decoder
	path = directory.path_join(_sha(identity.to_utf8_buffer())).path_join(
		_sha(decoder.to_utf8_buffer()) + ".bfc"
	)
	stats = {
		"disk_hit": false,
		"memory_hit": false,
		"file_bytes": 0,
		"raw_bytes": 0,
		"nodes": 0,
		"blobs": 0
	}
	if _documents.has(path):
		_document = _documents[path]
		stats.memory_hit = true
		return true
	if not FileAccess.file_exists(path):
		return false
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _fail("Cannot read asset cache")
	var size = file.get_length()
	if size < HEADER or size > MAX_BYTES + HEADER:
		return _fail("Asset cache size outside bounds")
	var bytes = file.get_buffer(size)
	file.close()
	if bytes.size() != size or bytes.decode_u32(0) != 0x31434642 or bytes.decode_u32(4) != VERSION:
		return _fail("Asset cache header/version mismatch")
	var raw_size = bytes.decode_u64(8)
	if raw_size < 1 or raw_size > MAX_BYTES or bytes.decode_u64(16) != size - HEADER:
		return _fail("Asset cache length mismatch")
	var packed = bytes.slice(HEADER)
	if _digest(packed) != bytes.slice(24, 56):
		return _fail("Asset cache checksum mismatch")
	var raw = packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != raw_size or _digest(raw) != bytes.slice(56, 88):
		return _fail("Asset cache content mismatch")
	# Object decoding is explicitly disabled. Only _read_object() instantiates
	# reviewed asset classes, after the container identity and shape checks.
	var candidate = bytes_to_var(raw)
	if (
		not candidate is Dictionary
		or not candidate.has_all(["identity", "decoder", "groups", "nodes", "blobs"])
	):
		return _fail("Invalid asset cache document")
	if (
		candidate.identity != identity
		or candidate.decoder != decoder
		or not candidate.groups is Dictionary
		or not candidate.nodes is Array
		or not candidate.blobs is Dictionary
		or candidate.nodes.size() > MAX_NODES
	):
		return _fail("Asset cache identity/shape mismatch")
	_document = candidate
	_seal(_document)
	_documents[path] = _document
	stats.merge(
		{
			"disk_hit": true,
			"file_bytes": size,
			"raw_bytes": raw_size,
			"nodes": candidate.nodes.size(),
			"blobs": candidate.blobs.size()
		},
		true
	)
	return true


func capture(groups: Dictionary) -> bool:
	last_error = ""
	_prepared.erase(path)
	_values = 0
	_references.clear()
	_writing = {"identity": _identity, "decoder": _decoder, "groups": {}, "nodes": [], "blobs": {}}
	for key: String in groups:
		_writing.groups[key] = _encode(groups[key], 0)
	if not last_error.is_empty():
		_writing = {}
		return false
	_document = _writing
	_writing = {}
	_objects.clear()
	_lookups.clear()
	_seal(_document)
	_documents[path] = _document
	stats.nodes = _document.nodes.size()
	stats.blobs = _document.blobs.size()
	return true


func save() -> bool:
	if _document.is_empty():
		return _fail("No prepared assets to save")
	var raw = var_to_bytes(_document)
	if raw.size() > MAX_BYTES:
		return _fail("Prepared assets exceed cache bound")
	var packed = raw.compress(FileAccess.COMPRESSION_ZSTD)
	var bytes = PackedByteArray()
	bytes.resize(HEADER)
	bytes.encode_u32(0, 0x31434642)
	bytes.encode_u32(4, VERSION)
	bytes.encode_u64(8, raw.size())
	bytes.encode_u64(16, packed.size())
	var sum = _digest(packed)
	var content = _digest(raw)
	for i: int in range(32):
		bytes[24 + i] = sum[i]
		bytes[56 + i] = content[i]
	bytes.append_array(packed)
	var directory = ProjectSettings.globalize_path(path.get_base_dir())
	var ancestor: String = directory
	while not DirAccess.dir_exists_absolute(ancestor):
		if FileAccess.file_exists(ancestor):
			return _fail("Asset cache folder is blocked by an existing file")
		var parent := ancestor.get_base_dir()
		if parent == ancestor:
			break
		ancestor = parent
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return _fail("Cannot create asset cache folder")
	var temporary = (
		ProjectSettings.globalize_path(path)
		+ ".tmp-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	)
	var file = FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _fail("Cannot write asset cache")
	file.store_buffer(bytes)
	file.flush()
	var written = file.get_error() == OK
	file.close()
	if (
		not written
		or DirAccess.rename_absolute(temporary, ProjectSettings.globalize_path(path)) != OK
	):
		DirAccess.remove_absolute(temporary)
		return _fail("Cannot publish complete asset cache")
	_prune_versions()
	stats.file_bytes = bytes.size()
	stats.raw_bytes = raw.size()
	return true


func lookup(group: String, key: Variant = null) -> Variant:
	if _document.is_empty() or not _document.groups.has(group):
		return null
	# Launch already hydrated these presentation catalogs. Clone their private
	# wrappers with native container copies instead of reconstructing hundreds
	# of immutable images/textures from the persistent graph during attachment.
	var resident: Dictionary = _resident_views.get(path,{})
	if resident.has(group):
		if key == null: return _private_view(resident[group])
		if resident[group].has(key): return _private_view(resident[group][key])
	var value = _document.groups[group]
	if key != null:
		if not value is Dictionary or value.get("t") != "dict":
			return null
		if not _lookups.has(group):
			var index := {}
			for pair: Array in value.items:
				index[_decode(pair[0], 0)] = pair[1]
			_lookups[group] = index
		return _decode(_lookups[group][key], 0) if _lookups[group].has(key) else null
	return _decode(value, 0)


func warm_graphics() -> bool:
	if _document.is_empty():
		return false
	for index: int in range(_document.nodes.size()):
		var node = _document.nodes[index]
		if node is Dictionary and node.get("kind") == "texture" and not node.get("private", false):
			if _read_object(index, 0) == null:
				return false
	return last_error.is_empty()


func ready() -> bool:
	return not _document.is_empty()


static func reset_memory() -> void:
	_documents.clear()
	_graphics.clear()
	_prepared.clear()
	_resident_views.clear()
	ImmutableTexture.reset_memory()


func prepared_inventory() -> Dictionary:
	return _prepared.get(path, {}).duplicate(true)


func mark_prepared(inventory: Dictionary) -> void:
	_prepared[path] = inventory.duplicate(true)


func _encode(value: Variant, depth: int, private_texture: bool = false) -> Variant:
	_values += 1
	if depth > 64 or _values > 2000000:
		_fail("Asset graph exceeds structural bounds")
		return null
	if value is PackedByteArray:
		var hash = _sha(value)
		if not _writing.blobs.has(hash):
			_writing.blobs[hash] = value.duplicate()
		return {"t": "blob", "hash": hash}
	if value is Array:
		var items: Array = []
		for child: Variant in value:
			items.append(_encode(child, depth + 1))
		return {"t": "array", "items": items}
	if value is Dictionary:
		var items: Array = []
		for key: Variant in value:
			items.append([_encode(key, depth + 1), _encode(value[key], depth + 1)])
		return {"t": "dict", "items": items}
	if value is Object:
		var reference = "%d:%s" % [value.get_instance_id(), private_texture]
		if _references.has(reference):
			return {"t": "ref", "id": _references[reference]}
		if _writing.nodes.size() >= MAX_NODES:
			_fail("Too many asset objects")
			return null
		var id = _writing.nodes.size()
		_references[reference] = id
		var node: Dictionary = {}
		_writing.nodes.append(node)
		if value is Image:
			node.merge(
				{
					"kind": "image",
					"width": value.get_width(),
					"height": value.get_height(),
					"format": value.get_format(),
					"mipmaps": value.has_mipmaps(),
					"data": _encode(value.get_data(), depth + 1)
				}
			)
		elif value is ImageTexture:
			var image = ImmutableTexture.pixels(value)
			node.merge(
				{"kind": "texture", "private": private_texture, "image": _encode(image, depth + 1)}
			)
			if not private_texture:
				_graphics[_image_key(image)] = value
		elif value is AudioStreamWAV:
			node.kind = "wav"
			node.fields = {}
			for field: String in [
				"format", "mix_rate", "stereo", "loop_mode", "loop_begin", "loop_end", "data"
			]:
				node.fields[field] = _encode(value.get(field), depth + 1)
		else:
			var script = value.get_script()
			var script_path = script.resource_path if script != null else ""
			if not SCRIPTS.has(script_path):
				_fail("Unsupported asset object: " + value.get_class())
				return null
			node.kind = "script"
			node.script = script_path
			node.fields = {}
			var fields := _stored_fields(value, script_path)
			for field: String in fields:
				node.fields[field] = _encode(
					fields[field],
					depth + 1,
					script_path.ends_with("cd_palette_data.gd") and field == "texture"
				)

		return {"t": "ref", "id": id}
	return value


func _decode(value: Variant, depth: int) -> Variant:
	if depth > 64:
		_fail("Asset graph nesting limit")
		return null
	if not value is Dictionary:
		return value
	match value.get("t", ""):
		"blob":
			var bytes = _document.blobs.get(value.get("hash", ""))
			if not bytes is PackedByteArray:
				_fail("Missing asset data")
				return null
			return bytes.duplicate()
		"ref":
			return _read_object(int(value.get("id", -1)), depth + 1)
		"array":
			var result: Array = []
			for item: Variant in value.get("items", []):
				result.append(_decode(item, depth + 1))
			return result
		"dict":
			var result: Dictionary = {}
			for pair: Array in value.get("items", []):
				if pair.size() != 2:
					_fail("Invalid asset dictionary")
					return null
				result[_decode(pair[0], depth + 1)] = _decode(pair[1], depth + 1)
			return result
	_fail("Unknown asset data tag")
	return null


func _read_object(id: int, depth: int) -> Variant:
	if _objects.has(id):
		return _objects[id]
	if id < 0 or id >= _document.nodes.size() or depth > 64:
		_fail("Invalid asset object reference")
		return null
	var node = _document.nodes[id]
	if not node is Dictionary:
		_fail("Invalid asset object")
		return null
	var result: Object
	match node.get("kind", ""):
		"image":
			var data = _decode(node.get("data"), depth + 1)
			if (
				not data is PackedByteArray
				or node.get("width", 0) < 1
				or node.get("width", 0) > 4096
				or node.get("height", 0) < 1
				or node.get("height", 0) > 4096
				or node.get("format", -1) != Image.FORMAT_RGBA8
			):
				_fail("Invalid cached image")
				return null
			var expected = _image_bytes(node.width, node.height, node.get("mipmaps", false))
			if data.size() != expected:
				_fail("Cached image length mismatch")
				return null
			result = Image.create_from_data(
				node.width, node.height, node.get("mipmaps", false), Image.FORMAT_RGBA8, data
			)
		"texture":
			var image = _decode(node.get("image"), depth + 1)
			if not image is Image:
				_fail("Missing cached texture image")
				return null
			var key = _image_key(image)
			if not node.get("private", false) and _graphics.has(key):
				result = _graphics[key]
			else:
				result = (
					ImageTexture.create_from_image(image)
					if node.get("private", false)
					else ImmutableTexture.create(image)
				)
				if not node.get("private", false):
					_graphics[key] = result
		"wav":
			result = AudioStreamWAV.new()
			for field: String in [
				"format", "mix_rate", "stereo", "loop_mode", "loop_begin", "loop_end", "data"
			]:
				if not node.get("fields", {}).has(field):
					_fail("Invalid cached PCM stream")
					return null
				var v = _decode(node.fields[field], depth + 1)
				if (
					(field == "data" and not v is PackedByteArray)
					or (field == "stereo" and not v is bool)
					or (field not in ["data", "stereo"] and not v is int)
				):
					_fail("Invalid PCM field type")
					return null
				result.set(field, v)
		"script":
			var script_path = node.get("script", "")
			if not SCRIPTS.has(script_path) or not node.get("fields") is Dictionary:
				_fail("Unreviewed asset class")
				return null
			result = SCRIPTS[script_path].new()
			_objects[id] = result
			var fields: Dictionary = {}
			for property: Dictionary in result.get_script().get_script_property_list():
				if (
					(int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0
					and property.name not in ["_native_font", "_native_fonts"]
				):
					fields[property.name] = property
			if node.fields.size() != fields.size():
				_objects.erase(id)
				_fail("Cached asset schema mismatch")
				return null
			for field: String in node.fields:
				var v = _decode(node.fields[field], depth + 1)
				if not fields.has(field) or not _field_type(fields[field], v):
					_objects.erase(id)
					_fail("Cached asset field mismatch")
					return null
				var current = result.get(field)
				if current is Array and current.is_typed():
					var subtype = current.get_typed_builtin()
					for item: Variant in v:
						if subtype != TYPE_NIL and typeof(item) != subtype:
							_objects.erase(id)
							_fail("Cached asset array type mismatch")
							return null
					current.assign(v)
					result.set(field, current)
				else:
					result.set(field, v)
		_:
			_fail("Unknown asset class")
			return null
	_objects[id] = result
	return result


static func _field_type(property: Dictionary, value: Variant) -> bool:
	var type = int(property.type)
	if type == TYPE_NIL:
		return true
	if type == TYPE_OBJECT:
		if value == null:
			return true
		if not value is Object:
			return false
		var expected: String = property.class_name
		return (
			expected.is_empty()
			or value.is_class(expected)
			or (value.get_script() != null and value.get_script().get_global_name() == expected)
		)
	return typeof(value) == type


static func _image_key(image: Image) -> String:
	return (
		"%d:%d:%d:%s:%s"
		% [
			image.get_width(),
			image.get_height(),
			image.get_format(),
			image.has_mipmaps(),
			_sha(image.get_data())
		]
	)


static func _digest(bytes: PackedByteArray) -> PackedByteArray:
	var hash = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		hash.update(bytes)
	return hash.finish()


static func _sha(bytes: PackedByteArray) -> String:
	return _digest(bytes).hex_encode()


static func _freeze(value: Variant) -> void:
	if value is Dictionary:
		if value.is_read_only():
			return
		for child: Variant in value.values():
			_freeze(child)
		value.make_read_only()
	elif value is Array:
		if value.is_read_only():
			return
		for child: Variant in value:
			_freeze(child)
		value.make_read_only()


func _fail(message: String) -> bool:
	last_error = message
	return false


static func _image_bytes(width: int, height: int, mipmaps: bool) -> int:
	var size = width * height * 4
	while mipmaps and (width > 1 or height > 1):
		width = maxi(1, width >> 1)
		height = maxi(1, height >> 1)
		size += width * height * 4
	return size


static func source_identity(catalog: Dictionary, image_path: String) -> String:
	var file = FileAccess.open(image_path, FileAccess.READ)
	if file == null:
		return ""
	var size = file.get_length()
	file.close()
	if catalog.get("format", "") == "cue":
		var identity: Array = [catalog.get("verified_edition", ""), image_path,
			size, FileAccess.get_modified_time(image_path)]
		for part: Dictionary in catalog.get("image_files", []):
			identity.append([part.path, part.size, FileAccess.get_modified_time(part.path)])
		return JSON.stringify(identity)

	return (
		"%s:%s:%d:%d"
		% [catalog.get("chd_sha1", ""), image_path, size, FileAccess.get_modified_time(image_path)]
	)


static func decoder_identity() -> String:
	var parts: Array = [VERSION, Engine.get_version_info().get("hash", "")]
	var pack = OS.get_executable_path().get_basename() + ".pck"
	if FileAccess.file_exists(pack):
		parts.append(FileAccess.get_sha256(pack))
	else:
		for dependency: String in DECODER_DEPENDENCIES:
			parts.append([dependency, FileAccess.get_sha256(dependency)])
		for folder: String in [
			"res://scripts/assets",
			"res://resources/ui",
			"res://resources/fonts",
			"res://resources/assets"
		]:
			var directory = DirAccess.open(folder)
			if directory == null:
				continue
			var files = directory.get_files()
			files.sort()
			for file: String in files:
				if file.get_extension() in ["gd", "json", "png"]:
					parts.append(
						[folder.path_join(file), FileAccess.get_sha256(folder.path_join(file))]
					)
	return _sha(var_to_bytes(parts))


static func _seal(value: Variant) -> void:
	if ClassDB.class_exists("BloodshotPrimitiveCodec"):
		var native = ClassDB.instantiate("BloodshotPrimitiveCodec")
		if native.has_method("freeze_tree"):
			native.freeze_tree(value)
			return
	_freeze(value)


## Cache source artwork and palette banks, never an active view's flash/noise
## clock. Build private canonical values without modifying live resources.
static func _stored_fields(value: Object, script_path: String) -> Dictionary:
	var fields: Dictionary = {}
	for property: Dictionary in value.get_script().get_script_property_list():
		if (
			(int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0
			and property.name != "_native_font"
		):
			fields[property.name] = value.get(property.name)
	if script_path.ends_with("cd_palette_data.gd") and not fields.banks.is_empty():
		fields.bank = 0
		fields._player_flash_word = -1
		fields.colors = fields.banks[0].duplicate()
		var image = Image.create_empty(fields.colors.size(), 1, false, Image.FORMAT_RGBA8)
		for i: int in range(fields.colors.size()):
			image.set_pixel(i, 0, fields.colors[i])
		fields.texture = ImageTexture.create_from_image(image)
	if script_path.ends_with("cd_ui_catalog.gd"):
		fields._textures = fields._textures.duplicate()
		for key: String in fields._textures.keys():
			if (
				key == "text_noise_pattern"
				or key.begins_with("noise_glyph:")
				or key.begins_with("pickup_static:")
			):
				fields._textures.erase(key)
		fields._noise_tick = -1
		fields._noise_pattern_tick = -1
		fields._noise_font = PackedByteArray()
		fields._noise_char_ticks = {}
		fields._static_periods = {}
	return fields


## Keep two completed decoder versions in this owned source namespace. A writer
## publishes before pruning; readers/active sources retain their own RAM data.
func _prune_versions() -> void:
	var directory = DirAccess.open(path.get_base_dir())
	if directory == null:
		return
	var old: Array = []
	for file: String in directory.get_files():
		if (
			file.get_extension() == "bfc"
			and file.get_basename().length() == 64
			and file.get_basename().is_valid_hex_number(false)
		):
			var candidate = path.get_base_dir().path_join(file)
			if candidate != path:
				old.append({"path": candidate, "age": FileAccess.get_modified_time(candidate)})
	old.sort_custom(func(a, b): return a.age > b.age)
	for index: int in range(1, old.size()):
		var previous: String = old[index].path
		DirAccess.remove_absolute(ProjectSettings.globalize_path(previous))
		_documents.erase(previous)
		_prepared.erase(previous)


func discard() -> void:
	_documents.erase(path)
	_prepared.erase(path)
	_document = {}
	_objects.clear()
	_lookups.clear()
	last_error = ""


## Only presentation catalogs enter this fast path; simulation metadata retains
## its original validated hydration. Pixel/PCM resources remain immutable while
## noise clocks, catalog caches, palettes and field containers stay private.
func retain_runtime_views(groups: Dictionary) -> void:
	var views := {}
	for group: String in ["ui", "frontend", "small_font", "audio", "textures"]:
		var value: Variant = groups.get(group)
		if group in ["ui", "textures"]:
			var catalogs := {}
			for key: Variant in value: catalogs[key] = _private_view(value[key])
			views[group] = catalogs
		elif value != null:
			views[group] = _private_view(value)
	_resident_views[path] = views


static func _private_view(value: Variant) -> Variant:
	if not value is Object or value.get_script() == null: return value
	var script: Script = value.get_script()
	if not SCRIPTS.has(script.resource_path): return value
	var copy: Object = script.new()
	var fields := _stored_fields(value,script.resource_path)
	for field: String in fields:
		var original: Variant = fields[field]
		if original is Array or original is Dictionary:
			copy.set(field,original.duplicate(true))
		elif original is Object and original.get_script() != null:
			copy.set(field,_private_view(original))
		else:
			copy.set(field,original)
	return copy
