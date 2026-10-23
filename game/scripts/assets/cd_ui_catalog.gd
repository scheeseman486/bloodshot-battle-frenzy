@tool
class_name CdUiCatalog
extends RefCounted
## Decode the CD's HUD atlas, frame map, font and level map directly to native
## Images/Textures. Tile packing is an asset layout, never a VDP renderer.
const ImmutableTexture = preload("res://scripts/assets/cd_immutable_texture.gd")
const Data = preload("res://scripts/assets/cd_level_decoder.gd")
const Palette = preload("res://scripts/assets/cd_palette_data.gd")
const Model = preload("res://scripts/presentation/cd_hud_model.gd")
const TextNoise = preload("res://scripts/presentation/cd_text_noise.gd")
const PickupStatic = preload("res://scripts/presentation/cd_pickup_static.gd")
const VIEW_RECT := Rect2i(24, 64, 224, 160)
const STATUS_SPANS := {0x339aa: 0x339ca, 0x33afe: 0x33b1e, 0x33b1e: 0x33b46}
var _main: PackedByteArray
var _shell: PackedByteArray
var _palette: PackedColorArray
var _textures: Dictionary = {}
var _map_backgrounds: Dictionary = {}
var glyphs: Dictionary = {}
var last_error := ""
var _static_periods: Dictionary = {}
var _messages: Dictionary = {}
var _noise_tick := -1
var _noise_font := PackedByteArray()
var _noise_char_ticks := {}
var _noise_pattern_tick := -1


func decode(main: PackedByteArray, shell: PackedByteArray, palette: PackedColorArray) -> bool:
	_textures.clear()
	_map_backgrounds.clear()
	_noise_tick = -1
	_noise_char_ticks.clear()
	_noise_pattern_tick = -1
	_static_periods.clear()
	_messages.clear()
	glyphs.clear()
	_main.clear()
	_shell.clear()
	_palette.clear()
	if main.size() < 0xce9a or shell.size() < 0x35d84 or palette.size() != 64:
		last_error = "Truncated CD HUD/font source"
		return false
	_main = main
	_shell = shell
	_palette = palette
	_textures.clear()
	glyphs.clear()
	for index: int in range(58):
		var at := 0x265fa + index * 8
		var pointer := Data._u32(shell, at + 2) - 0x8000
		var width := int(shell[at + 6])
		var height := int(shell[at + 7])
		if (
			width < 1
			or width > 8
			or height < 1
			or height > 3
			or pointer < 0
			or pointer + (height - 1) * 80 + width * 2 > shell.size()
		):
			last_error = "Unsupported CD font glyph"
			return false
		glyphs[Data._u16(shell, at)] = {"offset": pointer, "width": width, "height": height}
	return true


func _colors(bank: int, indexed: bool) -> PackedColorArray:
	if indexed:
		return Palette.index_palette(bank * 16)
	var result := PackedColorArray()
	for index: int in range(16):
		var color := _palette[bank * 16 + index]
		color.a = 0 if index == 0 else 1
		result.append(color)
	return result


## A single source tile is an eight-row, high-nibble-first image. All flips are
## resolved here into native pixels; runtime nodes never interpret tile hardware.
static func tile_image(
	bytes: PackedByteArray,
	offset: int,
	colors: PackedColorArray,
	flip_x: bool = false,
	flip_y: bool = false
) -> Image:
	if offset < 0 or offset + 32 > bytes.size() or colors.size() != 16:
		return null
	var image := Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
	for y: int in range(8):
		for x: int in range(8):
			var sx := 7 - x if flip_x else x
			var sy := 7 - y if flip_y else y
			var packed := int(bytes[offset + sy * 4 + (sx >> 1)])
			image.set_pixel(x, y, colors[(packed >> 4) if sx % 2 == 0 else (packed & 15)])
	return image


func _tile(
	set_name: String,
	index: int,
	bank: int,
	indexed: bool,
	flip_x: bool = false,
	flip_y: bool = false
) -> Image:
	var definition := {"frame": [0x1c9a, 82], "multiplayer_frame": [0x26da, 53], "icons": [0x313a, 235], "font": [0xcba, 127]}
	if not definition.has(set_name) or index < 0 or index >= int(definition[set_name][1]):
		return null
	return tile_image(
		_main, int(definition[set_name][0]) + index * 32, _colors(bank, indexed), flip_x, flip_y
	)


func frame(indexed: bool = false) -> Texture2D:
	var key := "frame:%s" % indexed
	if _textures.has(key):
		return _textures[key]
	var image := Image.create_empty(256, 224, false, Image.FORMAT_RGBA8)
	for y: int in range(28):
		for x: int in range(32):
			# The source's window region belongs to the native 3D camera.
			if VIEW_RECT.has_point(Vector2i(x * 8, y * 8)):
				continue
			var word := Data._u16(_shell, 0x33cc4 + (y * 32 + x) * 2)
			var tile := _tile(
				"frame", word & 0x7ff, 3, indexed, (word & 0x800) != 0, (word & 0x1000) != 0
			)
			if tile == null:
				last_error = "HUD frame references an invalid tile"
				return null
			image.blit_rect(tile, Rect2i(0, 0, 8, 8), Vector2i(x * 8, y * 8))
	_textures[key] = ImmutableTexture.create(image)
	return _textures[key]


func icon(id: int, indexed: bool = false) -> Texture2D:
	# Reward icons include lives34, ammunition36 and health37 ($00BE46).
	if id < 0 or id > 37:
		return null
	var key := "icon:%d:%s" % [id, indexed]
	if not _textures.has(key):
		var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
		var tiles := Model.icon_tiles(id)
		for index: int in range(4):
			var tile := _tile("icons", tiles[index], 3, indexed)
			if tile == null:
				return null
			image.blit_rect(tile, Rect2i(0, 0, 8, 8), Vector2i((index % 2) * 8, (index >> 1) * 8))
		_textures[key] = ImmutableTexture.create(image)
	return _textures[key]


## Compact two-column multiplayer rim, reused for the wide VS weapon grid.
## $037F44 adds $E000 to the original map words: HUD palette bank 3. Its
## right border is the adjoining panel's left rim, as in the single-view HUD.
func multiplayer_weapon_frame(indexed: bool = false) -> Texture2D:
	var key := "multiplayer_weapon_frame:%s" % indexed
	if not _textures.has(key):
		var image := Image.create_empty(40,64,false,Image.FORMAT_RGBA8)
		for y: int in range(8):
			for x: int in range(5):
				var word := Data._u16(_shell,0x343c4 + (y * 32 + x) * 2)
				var tile := _tile("multiplayer_frame",word & 0x7ff,3,indexed,(word & 0x800) != 0,(word & 0x1000) != 0)
				if tile == null:
					last_error = "Multiplayer HUD frame references an invalid tile"
					return null
				image.blit_rect(tile,Rect2i(0,0,8,8),Vector2i(x*8,y*8))
		# Retain the accepted wide HUD's 61-row crop; no artwork resampling.
		_textures[key] = ImmutableTexture.create(image.get_region(Rect2i(0,0,40,61)))
	return _textures[key]


## Owner's classic VS edit: source multiplayer tiles 29/30 cap the two-row
## weapon grid. Cache the source-pixel composition at launch, never an XCF/PNG.
func classic_versus_weapon_frame(indexed: bool = false) -> Texture2D:
	var key := "classic_versus_weapon_frame:%s" % indexed
	if not _textures.has(key):
		var image := ImmutableTexture.pixels(frame(indexed)).get_region(Rect2i(64,0,56,61))
		for y: int in [8,48]:
			for column: int in range(6):
				var tile := _tile("multiplayer_frame",29 + column % 2,3,indexed)
				image.blend_rect(tile,Rect2i(0,0,8,8),Vector2i(8+column*8,y))
		_textures[key] = ImmutableTexture.create(image)
	return _textures[key]


## Exact source generator inputs are exposed for numeric reference regression.
## Retain the last two words of each half: CD $FF140C transfers only 30 words.
func pickup_static_image(halves: Array, indexed: bool = false) -> Image:
	if _main.is_empty() or halves.size() != 2:
		return null
	var packed := PackedByteArray()
	for tile: int in Model.icon_tiles(33):
		packed.append_array(_main.slice(0x313a + tile * 32, 0x313a + (tile + 1) * 32))
	for side: int in range(2):
		var bytes := PickupStatic.half(_shell, int(halves[side].offset), halves[side].timers)
		if bytes.size() != 64:
			return null
		for index: int in range(60):
			packed[side * 64 + index] = bytes[index]
	var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	for tile: int in range(4):
		image.blit_rect(
			tile_image(packed, tile * 32, _colors(3, indexed)),
			Rect2i(0, 0, 8, 8),
			Vector2i((tile % 2) * 8, (tile >> 1) * 8)
		)
	return image


## One mutable texture per palette mode, shared by all flashing HUD slots.
## Pauses retain the same phase; skipped render frames need no catch-up work.
func pickup_static(time: float, indexed: bool = false) -> Texture2D:
	if _main.is_empty():
		return null
	var period := maxi(int(floor(time)), 0)
	var key := "pickup_static:%s" % indexed
	if int(_static_periods.get(key, -1)) != period:
		var image := pickup_static_image(PickupStatic.parameters(time), indexed)
		if image == null:
			return null
		if _textures.has(key):
			_textures[key].update(image)
		else:
			_textures[key] = ImageTexture.create_from_image(image)
		_static_periods[key] = period
	return _textures[key]


## Original death/hit cover uses atlas tile 233 in the actor palette bank.
func player_flash_tile() -> Texture2D:
	if not _textures.has("player_flash"):
		var image := _tile("icons", 233, 2, true)
		if image == null:
			return null
		_textures.player_flash = ImmutableTexture.create(image)
	return _textures.player_flash


## $037660 uploads one 32x32 sight from MAINOS $4E9A + frame*$200.
## Its sixteen tiles are column-major, unlike the row-major HUD icon atlas.
## Convert once to a native transparent texture in the actor/font palette bank.
func weapon_sight(frame_index: int, indexed: bool = false) -> Texture2D:
	if _main.is_empty() or frame_index < 0 or frame_index >= 12:
		return null
	var key := "weapon_sight:%d:%s" % [frame_index, indexed]
	if not _textures.has(key):
		var image := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
		for column: int in range(4):
			for row: int in range(4):
				var tile := tile_image(
					_main, 0x4e9a + frame_index * 512 + (column * 4 + row) * 32, _colors(2, indexed)
				)
				image.blit_rect(tile, Rect2i(0, 0, 8, 8), Vector2i(column * 8, row * 8))
		_textures[key] = ImmutableTexture.create(image)
	return _textures[key]


## Original weapon picture/name panel, $C8CE. Ten cards, eight source reveal
## phases; tile IDs have a 120-byte row stride in the original SHELL table.
func weapon_panel(weapon: int, phase: int = 0, indexed: bool = false) -> Texture2D:
	if _main.is_empty() or weapon < 0 or weapon >= 10 or phase < 0 or phase >= 8:
		return null
	var key := "weapon_panel:%d:%d:%s" % [weapon, phase, indexed]
	if not _textures.has(key):
		var image := Image.create_empty(48, 40, false, Image.FORMAT_RGBA8)
		for row: int in range(5):
			for column: int in range(6):
				var tile := Data._u16(
					_shell, 0x34ac4 + phase * 600 + weapon * 12 + row * 120 + column * 2
				)
				var pixels := tile_image(_main, 0x669a + tile * 32, _colors(2, indexed))
				if pixels == null:
					return null
				image.blit_rect(pixels, Rect2i(0, 0, 8, 8), Vector2i(column * 8, row * 8))
		_textures[key] = ImmutableTexture.create(image)
	return _textures[key]


## Keep original byte glyph IDs, including accented characters. The original
## language markers are E/F/D/S; the current native campaign defaults to E.
func message_layout(source_id: int, language: int = 69) -> Dictionary:
	var key := "%d:%d" % [source_id, language]
	if _messages.has(key):
		return _messages[key]
	if _shell.is_empty() or not STATUS_SPANS.has(source_id) or language not in [69, 70, 68, 83]:
		return {}
	var at := source_id - 0x8000
	var end := int(STATUS_SPANS[source_id]) - 0x8000
	while at + 1 < end:
		if int(_shell[at]) == 33 and int(_shell[at + 1]) == language:
			at += 2
			var bytes := PackedByteArray()
			while at < end and int(_shell[at]) != 0:
				bytes.append(_shell[at])
				at += 1
			if at >= end:
				return {}
			var width := 0
			for code: int in bytes:
				var folded := code + 32 if code >= 65 and code <= 90 else code
				if not glyphs.has(folded):
					return {}
				width += int(glyphs[folded].width) * 8
			@warning_ignore("integer_division")
			var position := Vector2i(128 - (width / 16) * 8, 112)
			var commands: Array = []
			var x := position.x
			for code: int in bytes:
				commands.append([code, x, position.y])
				var folded := code + 32 if code >= 65 and code <= 90 else code
				x += int(glyphs[folded].width) * 8
			_messages[key] = {
				"bytes": bytes, "position": position, "commands": commands, "width": width
			}
			return _messages[key]
		at += 1
	return {}


func message_texture(source_id: int, language: int = 69, indexed: bool = false) -> Texture2D:
	var key := "message:%d:%d:%s" % [source_id, language, indexed]
	if not _textures.has(key):
		var layout := message_layout(source_id, language)
		if layout.is_empty() or int(layout.width) == 0:
			return null
		var image := Image.create_empty(int(layout.width), 24, false, Image.FORMAT_RGBA8)
		for command: Array in layout.commands:
			var glyph: Texture2D = character(int(command[0]), indexed)
			image.blit_rect(
				glyph.get_image(),
				Rect2i(Vector2i.ZERO, glyph.get_size()),
				Vector2i(int(command[1]) - int(layout.position.x), 0)
			)
		_textures[key] = ImmutableTexture.create(image)
	return _textures[key]


func meter_tile(
	index: int, indexed: bool = false, flip_x: bool = false, flip_y: bool = false
) -> Texture2D:
	var key := "meter:%d:%s:%s:%s" % [index, indexed, flip_x, flip_y]
	if not _textures.has(key):
		var image := _tile("icons", index, 3, indexed, flip_x, flip_y)
		if image == null:
			return null
		_textures[key] = ImmutableTexture.create(image)
	return _textures[key]


func character(code: int, indexed: bool = false) -> Texture2D:
	if code >= 65 and code <= 90:
		code += 32
	if not glyphs.has(code):
		return null
	var key := "glyph:%d:%s" % [code, indexed]
	if not _textures.has(key):
		var glyph: Dictionary = glyphs[code]
		var image := Image.create_empty(int(glyph.width) * 8, 24, false, Image.FORMAT_RGBA8)
		for y: int in range(int(glyph.height)):
			for x: int in range(int(glyph.width)):
				var word := Data._u16(_shell, int(glyph.offset) + y * 80 + x * 2)
				var tile := _tile(
					"font", word & 0x7ff, 2, indexed, (word & 0x800) != 0, (word & 0x1000) != 0
				)
				if tile == null:
					return null
				image.blit_rect(tile, Rect2i(0, 0, 8, 8), Vector2i(x * 8, y * 8))
		_textures[key] = ImmutableTexture.create(image)
	return _textures[key]


func minimap_image(level: Resource, position: Vector2i, angle: int, indexed: bool = false) -> Image:
	if level.has_meta("native_spawns"):
		return _native_minimap(level, position, angle, indexed)
	var bytes: PackedByteArray = level.source_bytes
	var width := Data._u16(bytes, 32)
	var height := Data._u16(bytes, 34)
	var stride := width >> 3
	var bitmap_at := Data._u32(bytes, 36)
	var background_at := Data._u32(bytes, 40)
	var scale := Data._u16(bytes, 30)
	if (
		width < 8
		or width % 8 != 0
		or height < 1
		or scale < 1
		or bitmap_at + stride * height > bytes.size()
		or background_at + 960 > bytes.size()
	):
		return null
	@warning_ignore("integer_division")
	var map_x := int(float(position.x - Data._s16(bytes, 26)) / scale) - 24
	@warning_ignore("integer_division")
	var map_y := height - int(float(position.y - Data._s16(bytes, 28)) / scale) - 21
	var colors := _colors(2, indexed)
	var heading := posmod(angle + 1024, 16384) >> 11
	var image: Image = _minimap_background(level, heading, indexed).duplicate()
	for y: int in range(40):
		for x: int in range(48):
			var mx := map_x + x
			var my := map_y + y
			# $03369A/$033804 advances raw bitmap rows without clipping X.
			# Preserve that source edge behaviour instead of adding a new crop.
			var address := bitmap_at + my * stride + (mx >> 3)
			if address >= 0 and address < bytes.size():
				if (int(bytes[address]) & (0x80 >> (mx & 7))) != 0:
					image.set_pixel(x, y, colors[3])
	return image


## Runtime-only templates contain original tile backgrounds and heading arrows.
## Each view copies its template before drawing the live bitmap, preserving the
## original raw-row wrapping. No position-dependent images accumulate in cache.
func _minimap_background(level: Resource, heading: int, indexed: bool) -> Image:
	# Native content choice: only the three VS arenas and lobby use the CD's
	# unlabelled master. The lobby shares LEVEL1's artwork catalog, so keep the
	# background choice in the key as well as each map's own geometry identity.
	var master: bool = level.source_path in [
		"/ARENA1.LEV", "/ARENA2.LEV", "/ARENA3.LEV", "/NATIVE/LOBBY"
	]
	var key := "%s:%s:%d:%d" % [
		level.source_sha256, "master" if master else "level", heading, int(indexed)
	]
	if _map_backgrounds.has(key):
		return _map_backgrounds[key]
	var bytes: PackedByteArray = _main if master else level.source_bytes
	var background_at := 0x2d7a if master else Data._u32(bytes, 40)
	var colors := _colors(2, indexed)
	var image := Image.create_empty(48, 40, false, Image.FORMAT_RGBA8)
	for ty: int in range(5):
		for tx: int in range(6):
			var tile_index := ty * 6 + tx
			var tile: Image
			if tile_index in [14, 15]:
				tile = tile_image(_shell, 0x33924 + heading * 64 + (tile_index - 14) * 32, colors)
			else:
				tile = tile_image(bytes, background_at + tile_index * 32, colors)
			image.blit_rect(tile, Rect2i(0, 0, 8, 8), Vector2i(tx * 8, ty * 8))
	_map_backgrounds[key] = image
	return image


func prepare_minimap(level: Resource) -> void:
	for heading: int in range(8):
		minimap_image(level, level.spawn, heading * 2048 - 1024, true)


func text_noise_colors() -> PackedColorArray:
	return _colors(2, false)


func text_noise_pattern(tick: int) -> Texture2D:
	var key := "text_noise_pattern"
	if _noise_pattern_tick != tick:
		_noise_pattern_tick = tick
		var mask := PackedByteArray()
		mask.resize(128)
		mask.fill(255)
		var bytes := TextNoise.generate(mask, _main, tick)
		var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
		for pixel: int in range(256):
			var ink := (int(bytes[pixel / 2]) >> (4 if pixel % 2 == 0 else 0)) & 15
			image.set_pixel(pixel % 16, pixel / 16, Color(float(ink) / 255, 0, 0, 1))
		if _textures.has(key):
			_textures[key].update(image)
		else:
			_textures[key] = ImageTexture.create_from_image(image)
	return _textures[key]


func character_noise(code: int, tick: int) -> Texture2D:
	if code >= 65 and code <= 90:
		code += 32
	if not glyphs.has(code):
		return null
	if _noise_tick != tick:
		_noise_tick = tick
		_noise_font = TextNoise.generate(_main.slice(0xcba, 0xcba + 4064), _main, tick)
	var key := "noise_glyph:%d" % code
	if int(_noise_char_ticks.get(code, -1)) != tick:
		_noise_char_ticks[code] = tick
		var glyph: Dictionary = glyphs[code]
		var image := Image.create_empty(int(glyph.width) * 8, 24, false, Image.FORMAT_RGBA8)
		for y: int in range(int(glyph.height)):
			for x: int in range(int(glyph.width)):
				var mapping := Data._u16(_shell, int(glyph.offset) + y * 80 + x * 2)
				var tile := tile_image(
					_noise_font,
					(mapping & 0x7ff) * 32,
					_colors(2, false),
					(mapping & 0x800) != 0,
					(mapping & 0x1000) != 0
				)
				image.blit_rect(tile, Rect2i(0, 0, 8, 8), Vector2i(x * 8, y * 8))
		if _textures.has(key):
			_textures[key].update(image)
		else:
			_textures[key] = ImageTexture.create_from_image(image)
	return _textures[key]


## Native rooms have no original bitmap. Draw their authored geometry over the
## runtime CD minimap frame; no shared/network state is required for this view.
func _native_minimap(level: Resource, position: Vector2i, angle: int, indexed: bool) -> Image:
	var heading := posmod(angle + 1024, 16384) >> 11
	var image: Image = _minimap_background(level, heading, indexed).duplicate()
	var colors := _colors(2, indexed)
	for wall: Dictionary in level.walls:
		var a: Vector2 = Vector2(wall.start - position) / 64.0
		var b: Vector2 = Vector2(wall.finish - position) / 64.0
		a = Vector2(24 + a.x, 20 - a.y)
		b = Vector2(24 + b.x, 20 - b.y)
		var steps := maxi(1, int(ceil(a.distance_to(b))))
		for step: int in range(steps + 1):
			var point := Vector2i(a.lerp(b, float(step) / steps).round())
			if point.x >= 0 and point.x < 48 and point.y >= 0 and point.y < 40:
				image.set_pixelv(point, colors[3])
	return image
