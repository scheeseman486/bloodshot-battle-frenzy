@tool
class_name CdSmallFontCatalog
extends RefCounted
## Small font recovered from verified European CD artwork at runtime. This
## catalog combines source glyphs with the owner-authored missing characters.
## Only source coordinates, metrics and hashes ship; original pixels never do.
const ImmutableTexture = preload("res://scripts/assets/cd_immutable_texture.gd")
const MANIFEST := "res://resources/ui/cd_small_font_inventory.json"
static var _native_fonts: Dictionary = {}

var inventory: Dictionary = {}
var last_error := ""
var _frontend: RefCounted
var _source_textures := {}
var _addition_textures := {}
var _addition_advances := {}
var _native_font: FontFile


func configure(frontend: RefCounted) -> bool:
	if frontend == null:
		last_error = "Small font requires the verified European CD frontend catalog."
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not parsed is Dictionary or int(parsed.get("schema", 0)) != 1:
		last_error = "Invalid small-font coordinate inventory."
		return false
	_frontend = frontend
	inventory = parsed
	_source_textures.clear()
	_addition_textures.clear()
	_addition_advances.clear()
	_native_font = null
	last_error = ""
	return true


func glyph(code: int) -> Texture2D:
	if _addition_textures.has(code):
		return _addition_textures[code]
	return _source_glyph(code)


func _source_glyph(code: int) -> Texture2D:
	if _frontend == null:
		return null
	if code == 32:
		if not _source_textures.has(code):
			_source_textures[code] = ImmutableTexture.create(
				Image.create_empty(4, 9, false, Image.FORMAT_RGBA8)
			)
		return _source_textures[code]
	var key := String.chr(code)
	if not inventory.glyphs.has(key):
		return null
	if not _source_textures.has(code):
		var record: Dictionary = inventory.glyphs[key].source
		var source: Image
		if record.kind == "slide":
			source = _frontend.slide_image(int(record.index))
		else:
			source = ImmutableTexture.pixels(_frontend.ui.weapon_panel(int(record.index)))
		var rect := Rect2i(int(record.rect[0]), int(record.rect[1]), int(record.rect[2]), 9)
		_source_textures[code] = ImmutableTexture.create(_white_mask(source, rect))
	return _source_textures[code]


func available_codes() -> Array[int]:
	var result: Array[int] = []
	if _frontend == null:
		return result
	result.append(32)
	for key: String in inventory.glyphs:
		result.append(key.unicode_at(0))
	for code: int in _addition_textures:
		if not result.has(code):
			result.append(code)
	result.sort()
	return result


func advance(code: int) -> int:
	if code == 9:
		return 16  # Native formatting: four four-pixel spaces.
	if code == 32:
		return 4
	if _addition_advances.has(code):
		return int(_addition_advances[code])
	var key := String.chr(code)
	if inventory.get("glyphs", {}).has(key):
		return int(inventory.glyphs[key].advance)
	return int(_addition_advances.get(code, 0))


## Import the authored layer alone, at worksheet scale/offsets. The runtime CD
## supplies recovered characters; only explicitly approved extensions may add ink.
## Labels, guides and source references are separate GIMP layers, never assets.
func set_additions(sheet: Image) -> bool:
	if inventory.is_empty() or sheet == null or sheet.get_size() != Vector2i(320, 208):
		last_error = "Authored small-font overlay must use the 320 by 208 worksheet."
		return false
	var textures := {}
	var advances := {}
	var allowed: Array = inventory.missing.duplicate()
	allowed.append_array(inventory.get("authored_extensions", []))
	for key: String in allowed:
		var code := key.unicode_at(0)
		var image := _white_mask(sheet, worksheet_rect(code))
		if image.is_invisible():
			continue
		if inventory.glyphs.has(key):
			var original := ImmutableTexture.pixels(_source_glyph(code))
			# Source starts one row below the new eight-row ascent.
			image.blend_rect(original, Rect2i(Vector2i.ZERO, original.get_size()), Vector2i(0, 1))
		var right := 0
		for y: int in range(image.get_height()):
			for x: int in range(image.get_width()):
				if image.get_pixel(x, y).a == 1.0:
					right = maxi(right, x + 1)
		if right > 0:
			textures[code] = ImmutableTexture.create(image.get_region(Rect2i(0, 0, right, 10)))
			advances[code] = right + int(inventory.metrics.tracking)
	_addition_textures = textures
	_addition_advances = advances
	_native_font = null
	last_error = ""
	return true


static func worksheet_rect(code: int) -> Rect2i:
	var cell := code - 32
	@warning_ignore("integer_division")
	return Rect2i((cell % 16) * 20 + 4, 32 + (cell / 16) * 24 + 11, 12, 10)


static func _white_mask(source: Image, rect: Rect2i) -> Image:
	var image := Image.create_empty(rect.size.x, rect.size.y, false, Image.FORMAT_RGBA8)
	for y: int in range(rect.size.y):
		for x: int in range(rect.size.x):
			if source.get_pixel(rect.position.x + x, rect.position.y + y) == Color.WHITE:
				image.set_pixel(x, y, Color.WHITE)
	return image


## Only new ink ships. Original shapes still decode from the verified CD.
func load_authored_additions() -> bool:
	var record: Dictionary = inventory.authored_asset
	var bytes := FileAccess.get_file_as_bytes(record.path)
	var hash_value := HashingContext.new()
	hash_value.start(HashingContext.HASH_SHA256)
	hash_value.update(bytes)
	if hash_value.finish().hex_encode() != record.sha256:
		last_error = "Authored small-font asset hash mismatch."
		return false
	var sheet := Image.new()
	if sheet.load_png_from_buffer(bytes) != OK:
		last_error = "Cannot decode authored small-font additions."
		return false
	return set_additions(sheet)


## Build a native bitmap FontFile in memory, with the approved 12 px line advance.
## Untouched CD glyphs retain their seven-row ascent; new ink may rise one row.
func native_font() -> FontFile:
	if _native_font != null:
		return _native_font
	var signature := []
	for code: int in available_codes():
		signature.append([code, advance(code), glyph(code).get_instance_id(), _addition_textures.has(code)])
	var key := var_to_bytes(signature).hex_encode()
	if _native_fonts.has(key):
		_native_font = _native_fonts[key]
		return _native_font
	var font := FontFile.new()
	font.fixed_size = 12
	font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	font.allow_system_fallback = false
	font.set_cache_ascent(0, 12, 8)
	font.set_cache_descent(0, 12, 4)  # Two descender rows plus two rows of leading.
	var atlas := Image.create_empty(256, 72, false, Image.FORMAT_RGBA8)
	var size_key := Vector2i(12, 0)
	for code: int in available_codes():
		var image := ImmutableTexture.pixels(glyph(code))
		var cell := code - 32
		@warning_ignore("integer_division")
		var origin := Vector2i((cell % 16) * 16, (cell / 16) * 12)
		atlas.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), origin)
		font.set_glyph_advance(0, 12, code, Vector2(advance(code), 0))
		font.set_glyph_offset(
			0, size_key, code, Vector2(0, -8 if _addition_textures.has(code) else -7)
		)
		font.set_glyph_size(0, size_key, code, image.get_size())
		font.set_glyph_uv_rect(0, size_key, code, Rect2(origin, image.get_size()))
		font.set_glyph_texture_idx(0, size_key, code, 0)
	font.set_texture_image(0, size_key, 0, atlas)
	_native_font = font
	_native_fonts[key] = font
	return font
