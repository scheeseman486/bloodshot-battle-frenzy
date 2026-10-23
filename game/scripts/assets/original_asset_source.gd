@tool
class_name OriginalAssetSource
extends RefCounted
## Read-only native CHD loader with runtime-derived memory/user-folder caches.
## Original media stays required; CD music is streamed rather than cached.
const ImmutableTexture = preload("res://scripts/assets/cd_immutable_texture.gd")

const CHD_SHA1 := "dba5550a313c4cf9c1686afd5e052896fb40c256"
const EUROPE_CD := "europe-mega-cd-v1"
const TRACK_FRAMES := [3207, 19320, 14147, 1090, 6591, 7838, 13748, 25456, 21556, 19571, 25704, 16380, 20483, 1545, 2510, 25617, 27770]

const AssetCache = preload("res://scripts/assets/cd_asset_cache.gd")
const Preparation = preload("res://scripts/assets/cd_asset_preparation.gd")
const UiCatalog = preload("res://scripts/assets/cd_ui_catalog.gd")
const SmallFontCatalog = preload("res://scripts/assets/cd_small_font_catalog.gd")
const FrontendCatalog = preload("res://scripts/assets/cd_frontend_catalog.gd")
const PaletteData = preload("res://scripts/assets/cd_palette_data.gd")
const MAINOS_SHA256 := "e14a82de8151da5e48f98e55f315ccc56feccf7e9e87c0fb86d2412c0a866a4c"
const Decoder = preload("res://scripts/assets/indexed_image_decoder.gd")
const LevelDecoder = preload("res://scripts/assets/cd_level_decoder.gd")
const ActorCatalog = preload("res://scripts/assets/cd_actor_catalog.gd")
const AudioCatalog = preload("res://scripts/assets/cd_audio_catalog.gd")
const BehaviourTables = preload("res://scripts/assets/cd_behaviour_tables.gd")
const LEVEL_ONE_SHA256 := "2572692a291e58058809982a2e394e24c442536fa4a837ef61945b2b0f5a9b14"
const VERIFIED_LEVELS := {
	"/LEVEL1.LEV": "2572692a291e58058809982a2e394e24c442536fa4a837ef61945b2b0f5a9b14",
	"/LEVEL10.LEV": "f8038ef87f17329f4374320db0c7353f030a0cf891b94b03e56e25940396f8fc",
	"/LEVEL11.LEV": "c5a65dd15abba2eb0a80b6dadd496ebf2d91dcbf1f3a6f50a75e7af4e45b4ebc",
	"/LEVEL12.LEV": "7aa84c3940e47257ab26983758493ae4c10ac6af075d07112d4b9e00f26f1b08",
	"/LEVEL13.LEV": "45e10726e26c932f87b50b398df3a72c79b2361e8e6d72649623f9c97dbd4bc9",
	"/LEVEL14.LEV": "c33ec9bb7e72d8d01cd7028f1c13863dca36a3bd35e150e5c4b26b4b47f755f5",
	"/LEVEL15.LEV": "4bd4344cde3cdf374082967c2bda1bc01933dcc4aa3d4d9da186a4fad5c14d01",
	"/LEVEL16.LEV": "29497157d7a458e7acbd8be01a16fde9be6c39e70c5de33edd28d22435b64451",
	"/LEVEL2.LEV": "248b9fee3b73c32db325e3d600af3657232443e2dbefdaae4053e32828444810",
	"/LEVEL3.LEV": "dfef824272debe9cc8d3a8bb0fd3dc028a05a5a81ff114bf93a9885440337945",
	"/LEVEL4.LEV": "2d48bad80bd9c731103b2ec0549d818c80e45e8fead1d3ba5b74a254c92d3665",
	"/LEVEL5.LEV": "983aa2cf36fb414b200da7299902ed32ed241ad2bb6750bb45b6eafbd51294cd",
	"/LEVEL6.LEV": "59be3bada6ec5a87b048b37fba6a4807d9f39a4cd18fe37c8b2fc4670cab2e26",
	"/LEVEL7.LEV": "6be6ef48ff123d454808c5eb27e80fb56fa1f3f9a891f7f3fef2a6a2bb04189f",
	"/LEVEL8.LEV": "474d55dd81aedc26a2e4ebc58c3e32d3ff390ea99ddeb6c63a62ef2df4282944",
	"/LEVEL9.LEV": "b3a6717489b5cde3bd243be339fb5929640167652129a2a0ae49737e3f26c18c",
}

const VERIFIED_ARENAS := {
	"/ARENA1.LEV": "b39bc520f57d963ac5eb915789eaa53bdba89e2b334fecea3fc32a7d7ff98332",
	"/ARENA2.LEV": "31662ee07ae7df47ce76b3f829f9ef12a51753ba076ca68476aaeaec471386e4",
	"/ARENA3.LEV": "a967e0adc6a142e87fdfe670ab1c86dc66602676fa79c1563d171f2dd81bc540",
}

const SHELL_SHA256 := "e96ddb13dbe99087d1cd526bc15e022ac76c42b2efce14703fef9214ac8193a4"

var last_error: String = ""
var catalog: Dictionary = {}
var _disc_path: String = ""
var _byte_cache: Dictionary = {}
var _texture_cache: Dictionary = {}
var _level_cache: Dictionary = {}
var _behaviour_cache: Resource
var _actor_cache: Dictionary = {}
var _ui_cache: Dictionary = {}
var _palette_cache: Dictionary = {}
var _audio_cache: RefCounted
var _frontend_cache: RefCounted
var _small_font_cache: RefCounted
var _native_disc: Object
var _asset_cache: RefCounted
var cache_directory := "user://asset-cache"
var _original_reads := 0
var _preparation_info: Dictionary = {}
var _decodes: Dictionary = {}


func mount(image_path: String, use_cache: bool = true) -> bool:
	# Invalidate all derived data even when switching to an unavailable image.
	catalog.clear()
	_byte_cache.clear()
	_texture_cache.clear()
	_level_cache.clear()
	_behaviour_cache = null
	_actor_cache.clear()
	_ui_cache.clear()
	_palette_cache.clear()
	_audio_cache = null
	_frontend_cache = null
	_small_font_cache = null
	_native_disc = null
	_asset_cache = null
	_original_reads = 0
	_decodes.clear()
	_preparation_info.clear()
	_disc_path = ProjectSettings.globalize_path(image_path)
	var response := _request(PackedStringArray(["catalog"]))
	if not response.get("ok", false):
		return false
	catalog = response
	if catalog.get("chd_sha1", "") == CHD_SHA1:
		catalog["verified_edition"] = EUROPE_CD
	elif catalog.get("format", "") == "cue" and _verify_cue_content():
		catalog["verified_edition"] = EUROPE_CD
	if use_cache and supported_media():
		_asset_cache = AssetCache.new()
		_asset_cache.open(
			AssetCache.source_identity(catalog, _disc_path),
			AssetCache.decoder_identity(),
			cache_directory
		)
	return true


func supported_media() -> bool:
	return catalog.get("verified_edition", "") == EUROPE_CD


func _verify_cue_content() -> bool:
	var tracks: Array = catalog.get("tracks", [])
	if tracks.size() != TRACK_FRAMES.size():
		return false
	for index: int in range(tracks.size()):
		if int(tracks[index].frames) != TRACK_FRAMES[index]:
			return false
	for entry: Array in [["/MAINOS.BIN", MAINOS_SHA256], ["/SHELL.BIN", SHELL_SHA256]]:
		var bytes: PackedByteArray = read_range(entry[0])
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(bytes)
		if bytes.is_empty() or hash.finish().hex_encode() != entry[1]:
			return false
	return true


func read_range(path: String, offset: int = 0, count: int = -1) -> PackedByteArray:
	last_error = ""
	if catalog.is_empty():
		last_error = "No original disc is mounted."
		return PackedByteArray()
	if offset < 0 or count < -1:
		last_error = "Invalid byte range."
		return PackedByteArray()
	var key := "%s:%d:%d" % [path, offset, count]
	if _byte_cache.has(key):
		return (_byte_cache[key] as PackedByteArray).duplicate()
	if _asset_cache != null and _asset_cache.ready():
		var complete = _asset_cache.lookup("bytes", "%s:0:-1" % path)
		if complete is PackedByteArray:
			if offset > complete.size() or (count >= 0 and count > complete.size() - offset):
				last_error = "Invalid cached byte range."
				return PackedByteArray()
			var cached: PackedByteArray = complete.slice(
				offset, complete.size() if count < 0 else offset + count
			)
			_byte_cache[key] = cached
			return cached.duplicate()
	_original_reads += 1
	var arguments := PackedStringArray(["read", path, "--offset", str(offset)])
	if count >= 0:
		arguments.append_array(["--count", str(count)])
	var response := _request(arguments)
	if not response.get("ok", false):
		return PackedByteArray()
	var bytes: PackedByteArray = str(response["hex"]).hex_decode()
	_byte_cache[key] = bytes
	return bytes.duplicate()


func texture_from_linear_4bpp(
	path: String, offset: int, size: Vector2i, palette: PackedColorArray
) -> Texture2D:
	last_error = ""
	if size.x <= 0 or size.y <= 0 or size.x > 4096 or size.y > 4096 or palette.size() != 16:
		last_error = "Invalid image dimensions or palette."
		return null
	var key := "%s:%d:%s:%s" % [path, offset, str(size), var_to_str(palette)]
	if _texture_cache.has(key):
		return _texture_cache[key]
	var prepared = _cached_asset("textures", key)
	if prepared is Texture2D:
		_texture_cache[key] = prepared
		return prepared
	var count: int = (size.x * size.y + 1) >> 1
	var bytes := read_range(path, offset, count)
	if not last_error.is_empty():
		return null
	_count_decode("image")
	var image := Decoder.decode_linear_4bpp(bytes, size, palette)
	if image == null:
		last_error = "The span is too short for this image layout."
		return null
	var texture := ImmutableTexture.create(image)
	_texture_cache[key] = texture
	return texture


func load_cd_frontend_catalog() -> RefCounted:
	last_error = ""
	if not supported_media():
		last_error = "Frontend artwork requires the verified European CD"
		return null
	if _frontend_cache == null:
		_frontend_cache = _cached_asset("frontend")
	if _frontend_cache == null:
		_count_decode("frontend")
		var frontend := FrontendCatalog.new()
		if not frontend.decode(
			read_range("/MAINOS.BIN"), read_range("/SHELL.BIN"), read_range("/SLIDES.BIN")
		):
			last_error = frontend.last_error
			return null
		_frontend_cache = frontend
	return _frontend_cache


func load_cd_level(path: String = "/LEVEL1.LEV") -> Resource:
	if not VERIFIED_LEVELS.has(path):
		last_error = "This level is outside the verified European CD campaign set."
		return null
	return _load_verified_map(path, str(VERIFIED_LEVELS[path]))


func load_cd_arena(path: String) -> Resource:
	if not VERIFIED_ARENAS.has(path):
		last_error = "This arena is outside the verified European CD battle set."
		return null
	var level: Resource = _load_verified_map(path, str(VERIFIED_ARENAS[path]))
	if level != null:
		level.set_meta("battle_mode", true)
	return level


func _load_verified_map(path: String, expected: String) -> Resource:
	last_error = ""
	if not supported_media():
		last_error = "Map requires the verified European CD"
		return null
	if _level_cache.has(path):
		return _level_cache[path]
	var cached = _cached_asset("levels", path)
	if (
		cached is Resource
		and cached.get_script() == LevelDecoder.Level
		and cached.source_sha256 == expected
	):
		_level_cache[path] = cached
		return cached
	var data := read_range(path)
	if not last_error.is_empty():
		return null
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(data)
	var sha := digest.finish().hex_encode()
	if sha != expected:
		last_error = "Level source hash differs from the verified CD baseline."
		return null
	_count_decode("level")
	var level = LevelDecoder.decode(data)
	if level == null:
		last_error = "Unsupported or invalid CD level tables."
		return null
	level.source_path = path
	level.source_sha256 = sha
	# Consumers treat these cached Resources as read-only source descriptions.
	_level_cache[path] = level
	return level


func load_cd_behaviour_tables() -> Resource:
	last_error = ""
	if not supported_media():
		last_error = "Behaviour tables require the verified European CD."
		return null
	if _behaviour_cache != null:
		return _behaviour_cache
	var cached = _cached_asset("behaviour")
	if (
		cached is Resource
		and cached.get_script() == BehaviourTables
		and cached.source_sha256 == SHELL_SHA256
	):
		_behaviour_cache = cached
		return cached
	var data := read_range("/SHELL.BIN")
	if not last_error.is_empty():
		return null
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(data)
	if digest.finish().hex_encode() != SHELL_SHA256:
		last_error = "SHELL source hash differs from the verified CD baseline."
		return null
	_count_decode("behaviour")
	var tables := BehaviourTables.new()
	if not tables.decode(data):
		last_error = "Unsupported CD behaviour tables."
		return null
	_behaviour_cache = tables
	_behaviour_cache.source_sha256 = SHELL_SHA256
	return _behaviour_cache


func texture_from_cd_wall(level: Resource, wall_index: int) -> Texture2D:
	last_error = ""
	if level == null or wall_index < 0 or wall_index >= level.walls.size():
		last_error = "Invalid wall texture request."
		return null
	var wall: Dictionary = level.walls[wall_index]
	var key := (
		"cd-wall-v1:%s:%d:%d:%s"
		% [_artwork_identity(level), wall.texture_offset, wall.texture_width, str(wall.mirror)]
	)
	if _texture_cache.has(key):
		return _texture_cache[key]
	var prepared = _cached_asset("textures", key)
	if prepared is Texture2D:
		_texture_cache[key] = prepared
		return prepared
	_count_decode("image")
	var image := LevelDecoder.decode_wall_image(
		level.source_bytes, wall.texture_offset, wall.texture_width, level.palette, wall.mirror
	)
	if image == null:
		last_error = "Unsupported wall image span or palette."
		return null
	var texture := ImmutableTexture.create(image)
	_texture_cache[key] = texture
	return texture


func load_cd_actor_catalog(level: Resource) -> Resource:
	last_error = ""
	if level == null or not _verified_map(level):
		last_error = "Actor graphics require a verified European CD map."
		return null
	if _actor_cache.has(level.source_sha256):
		return _actor_cache[level.source_sha256]
	var cached = _cached_asset("actors", level.source_sha256)
	if (
		cached is Resource
		and cached.get_script() == ActorCatalog
		and cached.level_sha256 == level.source_sha256
		and cached.source_sha256 == SHELL_SHA256
	):
		_actor_cache[level.source_sha256] = cached
		return cached
	# The existing table loader verifies the complete SHELL hash, and read_range
	# returns independent bytes from the same in-memory source cache.
	if load_cd_behaviour_tables() == null:
		return null
	_count_decode("actors")
	var catalog_data := ActorCatalog.new()
	if not catalog_data.decode(read_range("/SHELL.BIN"), level):
		last_error = catalog_data.last_error
		return null
	catalog_data.source_sha256 = SHELL_SHA256
	_actor_cache[level.source_sha256] = catalog_data
	return catalog_data


func texture_from_cd_actor(level: Resource, actors: Resource, address: int) -> Texture2D:
	last_error = ""
	if (
		level == null
		or actors == null
		or actors.level_sha256 != level.source_sha256
		or not actors.frames.has(address)
	):
		last_error = "Invalid CD actor frame request."
		return null
	var key := "cd-actor-v1:%s:%s:%x" % [_artwork_identity(level), actors.source_sha256, address]
	if _texture_cache.has(key):
		return _texture_cache[key]
	var prepared = _cached_asset("textures", key)
	if prepared is Texture2D:
		_texture_cache[key] = prepared
		return prepared
	_count_decode("image")
	var image: Image = actors.decode_image(level, address)
	if image == null:
		last_error = "This frame has no pixels in the current level."
		return null
	var texture := ImmutableTexture.create(image)
	_texture_cache[key] = texture
	return texture


func load_cd_palette(level: Resource) -> RefCounted:
	if level != null and level.has_meta("art_level"):
		level = level.get_meta("art_level")
	if level == null or not _verified_map(level) or load_cd_behaviour_tables() == null:
		last_error = "Palette graphics require a verified European CD map."
		return null
	if _palette_cache.has(level.source_sha256):
		return _palette_cache[level.source_sha256]
	var cached = _cached_asset("palettes", level.source_sha256)
	if cached is RefCounted and cached.get_script() == PaletteData:
		_palette_cache[level.source_sha256] = cached
		return cached
	_count_decode("palette")
	var palette := PaletteData.new()
	if not palette.decode(level, read_range("/SHELL.BIN")):
		last_error = "Invalid original level/countdown palettes"
		return null
	_palette_cache[level.source_sha256] = palette
	return palette


## Recovered glyphs are decoded from original media in memory. User artwork is
## loaded from the owner-only overlay; recovered pixels remain CD-backed.
func load_cd_small_font() -> RefCounted:
	var frontend := load_cd_frontend_catalog()
	if frontend == null:
		return null
	if _small_font_cache == null:
		_small_font_cache = _cached_asset("small_font")
	if _small_font_cache == null:
		_count_decode("font")
		var font_catalog := SmallFontCatalog.new()
		if not font_catalog.configure(frontend) or not font_catalog.load_authored_additions():
			last_error = font_catalog.last_error
			return null
		_small_font_cache = font_catalog
	return _small_font_cache


func load_cd_ui(level: Resource) -> RefCounted:
	if level != null and level.has_meta("art_level"):
		level = level.get_meta("art_level")
	if level == null:
		return null
	if _ui_cache.has(level.source_sha256):
		return _ui_cache[level.source_sha256]
	var palette := load_cd_palette(level)
	if palette == null:
		return null
	var main := read_range("/MAINOS.BIN")
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(main)
	if digest.finish().hex_encode() != MAINOS_SHA256:
		last_error = "MAINOS source hash differs from the verified European CD"
		return null
	var cached = _cached_asset("ui", level.source_sha256)
	if cached is RefCounted and cached.get_script() == UiCatalog:
		_ui_cache[level.source_sha256] = cached
		return cached
	_count_decode("ui")
	var ui := UiCatalog.new()
	if not ui.decode(main, read_range("/SHELL.BIN"), palette.banks[0]):
		last_error = ui.last_error
		return null
	_ui_cache[level.source_sha256] = ui
	return ui


func index_texture_from_cd_wall(level: Resource, wall_index: int) -> Texture2D:
	if level == null or wall_index < 0 or wall_index >= level.walls.size():
		last_error = "Invalid wall index texture request"
		return null
	var wall: Dictionary = level.walls[wall_index]
	var key := (
		"wall-indices:%s:%d:%d:%s"
		% [_artwork_identity(level), wall.texture_offset, wall.texture_width, wall.mirror]
	)
	if _texture_cache.has(key):
		return _texture_cache[key]
	var prepared = _cached_asset("textures", key)
	if not _texture_cache.has(key) and prepared is Texture2D:
		_texture_cache[key] = prepared
	if not _texture_cache.has(key):
		var indices := PaletteData.index_palette(0, false)
		indices.append_array(PaletteData.index_palette(16, false))
		_count_decode("image")
		var image := LevelDecoder.decode_wall_image(
			level.source_bytes,
			int(wall.texture_offset),
			int(wall.texture_width),
			indices,
			bool(wall.mirror)
		)
		if image == null:
			return null
		_texture_cache[key] = ImmutableTexture.create(image)
	return _texture_cache[key]


func index_texture_from_cd_actor(level: Resource, actors: Resource, address: int) -> Texture2D:
	if (
		level == null
		or actors == null
		or actors.level_sha256 != level.source_sha256
		or not actors.frames.has(address)
	):
		last_error = "Invalid actor index texture request"
		return null
	var key := "actor-indices:%s:%d" % [_artwork_identity(level), address]
	if _texture_cache.has(key):
		return _texture_cache[key]
	var prepared = _cached_asset("textures", key)
	if not _texture_cache.has(key) and prepared is Texture2D:
		_texture_cache[key] = prepared
	if not _texture_cache.has(key):
		_count_decode("image")
		var image: Image = actors.decode_index_image(level, address)
		if image == null:
			return null
		_texture_cache[key] = ImmutableTexture.create(image)
	return _texture_cache[key]


func _request(arguments: PackedStringArray) -> Dictionary:
	last_error = ""
	if ClassDB.class_exists("BloodshotDisc"):
		return _native_request(arguments)
	if not OS.has_feature("editor"):
		last_error = "The native disc/audio extension is missing. Build and package it with tools/build_audio.py."
		return {}

	var helper := ProjectSettings.globalize_path("res://../tools/disc_image.py")
	var command := PackedStringArray([helper, "--image", _disc_path])
	command.append_array(arguments)
	var output: Array = []
	var status: int = OS.execute("python3", command, output, false)
	var response: Variant = JSON.parse_string("".join(output))
	if response is not Dictionary:
		last_error = "Disc reader did not return JSON (exit %d). Check Python and libchdr." % status
		return {}
	if status != 0 or not response.get("ok", false):
		last_error = str(response.get("error", "Disc reader failed."))
		return {}
	return response


func load_cd_audio_catalog() -> RefCounted:
	last_error = ""
	if not supported_media():
		last_error = "Audio requires the verified European CD."
		return null
	if _audio_cache != null:
		return _audio_cache
	var cached = _cached_asset("audio")
	if cached is RefCounted and cached.get_script() == AudioCatalog:
		_audio_cache = cached
		return cached
	_count_decode("audio")
	var audio := AudioCatalog.new()
	if not audio.decode(read_range("/SHELL.BIN")):
		last_error = audio.last_error
		return null
	_audio_cache = audio
	return audio


func disc_path() -> String:
	return _disc_path


func _native_request(arguments: PackedStringArray) -> Dictionary:
	if arguments[0] == "catalog":
		_native_disc = ClassDB.instantiate("BloodshotDisc")
		if not bool(_native_disc.call("open", _disc_path)):
			last_error = str(_native_disc.call("get_error"))
			return {}
		return _native_disc.call("catalog")
	if _native_disc == null or arguments[0] != "read" or arguments.size() < 2:
		last_error = "Invalid native disc request."
		return {}
	var offset := 0
	var count := -1
	for index: int in range(2, arguments.size(), 2):
		if index + 1 >= arguments.size():
			last_error = "Incomplete native byte range."
			return {}
		if arguments[index] == "--offset":
			offset = int(arguments[index + 1])
		elif arguments[index] == "--count":
			count = int(arguments[index + 1])
	var bytes: PackedByteArray = _native_disc.call("read_file", arguments[1], offset, count)
	last_error = str(_native_disc.call("get_error"))
	if not last_error.is_empty():
		return {}
	return {"ok": true, "hex": bytes.hex_encode()}


static func configured_disc_path() -> String:
	return preload("res://scripts/assets/disc_location.gd").resolve()


func _cached_asset(group: String, key: Variant = null) -> Variant:
	return (
		_asset_cache.lookup(group, key) if _asset_cache != null and _asset_cache.ready() else null
	)


func prepare_asset_cache(progress: Callable = Callable()) -> bool:
	return await Preparation.new().prepare(self, progress)


func cache_groups() -> Dictionary:
	return {
		"bytes": _byte_cache,
		"textures": _texture_cache,
		"levels": _level_cache,
		"behaviour": _behaviour_cache,
		"actors": _actor_cache,
		"ui": _ui_cache,
		"palettes": _palette_cache,
		"audio": _audio_cache,
		"frontend": _frontend_cache,
		"small_font": _small_font_cache
	}


func cache_info() -> Dictionary:
	return {
		"original_file_reads": _original_reads,
		"decodes": _decodes.duplicate(),
		"cache_path": _asset_cache.path if _asset_cache != null else "",
		"storage": _asset_cache.stats.duplicate(true) if _asset_cache != null else {},
		"preparation": _preparation_info.duplicate(true)
	}


func _count_decode(kind: String) -> void:
	_decodes[kind] = int(_decodes.get(kind, 0)) + 1


func _verified_map(level: Resource) -> bool:
	return (
		level != null
		and (
			level.source_sha256
			== str(
				VERIFIED_LEVELS.get(level.source_path, VERIFIED_ARENAS.get(level.source_path, ""))
			)
		)
	)


## Native geometry may reference existing CD artwork without another decode.
## Geometry/network identity stays separate from the immutable image cache key.
func _artwork_identity(level: Resource) -> String:
	var art: Resource = level.get_meta("art_level", level)
	return art.source_sha256
