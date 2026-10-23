@tool
class_name CdFrontendCatalog
extends RefCounted
## European CD frontend original-media catalog. Decoded resources stay in memory.
const ImmutableTexture = preload("res://scripts/assets/cd_immutable_texture.gd")
var last_error := ""
const Rnc = preload("res://scripts/assets/rnc2_decoder.gd")
const Data = preload("res://scripts/assets/cd_level_decoder.gd")
const Ui = preload("res://scripts/assets/cd_ui_catalog.gd")
const HASHES := [
	"e14a82de8151da5e48f98e55f315ccc56feccf7e9e87c0fb86d2412c0a866a4c",
	"e96ddb13dbe99087d1cd526bc15e022ac76c42b2efce14703fef9214ac8193a4",
	"384f23e8ab6d597c4760db3a901e5ca7d9796d6bda651a5e60164caa216c8dd9"
]
const TABLES := {
	"main": 0x2e12e,
	"options": 0x2e17c,
	"language": 0x2e19e,
	"preferences": 0x2e1ba,
	"sound_test": 0x2e1f6,
	"battle": 0x2e206
}
var descriptors: Array[Dictionary] = []
var menus: Dictionary = {}
var ui := Ui.new()
var _shell := PackedByteArray()
var _slides := PackedByteArray()
var _textures := {}
var _expanded := {}
var _layouts := {}
var _demos := {}


func demo(index: int) -> Dictionary:
	if index < 0 or index >= 3:
		return {}
	if _demos.has(index):
		return _demos[index]
	var pointer := Data._u32(_shell, 0x232b6 + index * 4)
	var at := pointer - 0x8000
	var result := {
		"pointer": pointer,
		"player": Data._u16(_shell, at),
		"level": Data._u16(_shell, at + 2),
		"records": [],
		"actions": []
	}
	at += 4
	while at + 6 <= _shell.size():
		var tag := Data._u16(_shell, at)
		var first := Data._u16(_shell, at + 2)
		var second := Data._u16(_shell, at + 4)
		result.records.append({"tag": tag, "first": first, "second": second})
		at += 6
		if (tag & 0xc000) in [0x8000, 0xc000]:
			if (tag & 0x1fff) == 0x1fff:
				_demos[index] = result
				return result
			result.actions.append(
				{
					"kind": "activate" if (tag & 0xc000) == 0x8000 else "remove",
					"actor": tag & 0x1fff,
					"target": 1 if (tag & 0x2000) != 0 else 0,
					"update": first
				}
			)
	last_error = "Unterminated European CD demo stream"
	return {}


func startup_program(part: String, language: int = 69) -> Array[Dictionary]:
	# Native sequence structure follows $3A8FA..$3AD7A. Addresses refer to
	# source asset descriptors or localized text; their bytes stay on the CD.
	var result: Array[Dictionary] = []
	if part == "logos":
		for index: int in [0, 3, 2]:
			result.append({"kind": "slide", "address": 0x3b582 + index * 14, "hold": 180})
		result.append({"kind": "fade", "hold": 48})
		result.append({"kind": "blank", "hold": 10})
	elif part == "title":
		result.append({"kind": "fade", "hold": 48})
		result.append({"kind": "blank", "hold": 10})
		result.append({"kind": "slide", "address": 0x3b5ba, "hold": 150})
		result.append(
			{"kind": "overlay", "address": 0x3b5d6 if language == 68 else 0x3b5c8, "hold": 300}
		)
		result.append({"kind": "fade", "hold": 48})
	elif part == "story":
		var rows := [
			[11, 150, [[0x34b9a, 0], [0x34be2, 100], [0x34cb2, 0]]],
			[10, 150, [[0x34d8a, 0], [0x34e98, 100]]],
			[14, 150, [[0x34f4e, 0]]],
			[7, 150, [[0x3506c, 100]]],
			[12, 150, [[0x35222, 0]]],
			[13, 200, [[0x352e2, 100]]],
			[8, 150, [[0x35390, 0], [0x355b2, 0]]],
			[9, 150, [[0x356f4, 50], [0x358d8, 100]]]
		]
		for row: Array in rows:
			result.append({"kind": "slide", "address": 0x3b582 + int(row[0]) * 14, "hold": row[1]})
			for caption: Array in row[2]:
				result.append({"kind": "text", "address": caption[0], "hold": caption[1]})
		result.append({"kind": "fade", "hold": 48})
		result.append({"kind": "wait", "hold": 50})
	return result


func noise_tiles() -> Texture2D:
	if not _textures.has("noise"):
		var colors := PackedColorArray()
		for value: int in range(16):
			colors.append(Color(float(value) / 15.0, float(value) / 15.0, float(value) / 15.0, 1))
		var image := Image.create_empty(256, 8, false, Image.FORMAT_RGBA8)
		for index: int in range(32):
			var tile := Ui.tile_image(ui._main, 0xc5da + index * 32, colors)
			image.blit_rect(tile, Rect2i(0, 0, 8, 8), Vector2i(index * 8, 0))
		_textures["noise"] = ImmutableTexture.create(image)
	return _textures["noise"]


func noise_targets() -> Array:
	var result: Array = []
	for index: int in range(24):
		var at := 0x2707c + index * 3
		result.append(Vector3i(_shell[at],_shell[at+1],_shell[at+2]))
	return result


func noise_seeds() -> Texture2D:
	if not _textures.has("seeds"):
		# The source seeds with a hardware timer plus its own code words. Retain
		# the code-word entropy and use a fixed native start phase, independent
		# of gameplay RNG. Runtime pixel noise never becomes a ripped asset.
		var image := Image.create_empty(960, 1, false, Image.FORMAT_RGBA8)
		var sum := 0
		for index: int in range(480):
			sum = (
				(
					sum
					+ Data._u16(_shell, index * 2)
					- Data._u16(_shell, index * 2 + 2)
					+ 959
					- index
				)
				& 65535
			)
			image.set_pixel(index * 2, 0, Color(float(sum >> 8) / 255.0, 0, 0, 1))
			image.set_pixel(index * 2 + 1, 0, Color(float(sum & 255) / 255.0, 0, 0, 1))
		_textures["seeds"] = ImmutableTexture.create(image)
	return _textures["seeds"]


func decode(main: PackedByteArray, shell: PackedByteArray, slides: PackedByteArray) -> bool:
	descriptors.clear()
	menus.clear()
	_textures.clear()
	_expanded.clear()
	_layouts.clear()
	_demos.clear()
	for index: int in range(3):
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update([main, shell, slides][index])
		if hash.finish().hex_encode() != HASHES[index]:
			last_error = "Frontend source differs from the verified European CD"
			return false
	_shell = shell
	_slides = slides
	var palette := PackedColorArray()
	for index: int in range(64):
		palette.append(_color(Data._u16(shell, 0x33c44 + index * 2)))
	if not ui.decode(main, shell, palette):
		last_error = ui.last_error
		return false
	for at: int in range(0x33582, 0x33654, 14):
		descriptors.append(
			{
				"pixels": Data._u32(shell, at) - 0x96726,
				"size": Data._u16(shell, at + 4),
				"mapping": Data._u32(shell, at + 6) - 0x96726,
				"palette": Data._u32(shell, at + 10) - 0x96726
			}
		)
	for name: String in TABLES:
		menus[name] = _menu(int(TABLES[name]) - 0x8000)
	last_error = ""
	return true


func _menu(at: int) -> Dictionary:
	var result := {"row": Data._u16(_shell, at), "items": []}
	var count := Data._u16(_shell, at + 2)
	at += 4
	for index: int in range(count):
		var pointer := Data._u32(_shell, at)
		var choices := Data._u16(_shell, at + 4)
		at += 6
		var entry := {"text": pointer, "choices": choices, "address": 0, "values": []}
		if choices != 0:
			entry.address = Data._u32(_shell, at)
			at += 4
			for choice: int in range(choices):
				entry.values.append(Data._u32(_shell, at))
				at += 4
		result.items.append(entry)
	return result


func text_bytes(pointer: int, language: int = 69) -> PackedByteArray:
	var at := pointer - 0x8000
	if at < 0 or at >= _shell.size():
		return PackedByteArray()
	var seen := {}
	while at + 2 < _shell.size():
		if _shell[at] != 33:
			break
		var code := int(_shell[at + 1])
		if code not in [69, 70, 68, 83] or seen.has(code):
			break
		seen[code] = true
		at += 2
		var end := at
		while end < _shell.size() and _shell[end] != 0:
			end += 1
		if code == language:
			return _shell.slice(at, end)
		at = end
		while at < _shell.size() and _shell[at] == 0:
			at += 1
	return PackedByteArray()


func expanded_slide(index: int) -> PackedByteArray:
	if index < 0 or index >= descriptors.size():
		return PackedByteArray()
	if not _expanded.has(index):
		var bytes := Rnc.new().decode(_slides, int(descriptors[index].pixels))
		if bytes.size() != int(descriptors[index].size):
			last_error = "Invalid original compressed slide"
			return PackedByteArray()
		_expanded[index] = bytes
	return _expanded[index]


func slide_image(index: int, transparent: bool = false) -> Image:
	var pixels := expanded_slide(index)
	if pixels.is_empty():
		return null
	var descriptor: Dictionary = descriptors[index]
	var palette := PackedColorArray()
	for color: int in range(16):
		var value := _color(Data._u16(_slides, int(descriptor.palette) + color * 2))
		value.a = 0 if transparent and color == 0 else 1
		palette.append(value)
	var image := Image.create_empty(256, 224, false, Image.FORMAT_RGBA8)
	var tiles := {}
	for y: int in range(28):
		for x: int in range(32):
			var word := Data._u16(_slides, int(descriptor.mapping) + (y * 32 + x) * 2)
			if not tiles.has(word):
				tiles[word] = Ui.tile_image(
					pixels, (word & 0x7ff) * 32, palette, (word & 0x800) != 0, (word & 0x1000) != 0
				)
			if tiles[word] == null:
				last_error = "Slide tile outside original record"
				return null
			image.blit_rect(tiles[word], Rect2i(0, 0, 8, 8), Vector2i(x * 8, y * 8))
	return image


func slide(index: int, transparent: bool = false) -> Texture2D:
	var key := "%d:%s" % [index, transparent]
	if not _textures.has(key):
		var image := slide_image(index, transparent)
		if image == null:
			return null
		_textures[key] = ImmutableTexture.create(image)
	return _textures[key]


func title() -> Texture2D:
	if not _textures.has("title"):
		var base := slide_image(4)
		base.blend_rect(slide_image(5, true), Rect2i(0, 0, 256, 224), Vector2i.ZERO)
		_textures["title"] = ImmutableTexture.create(base)
	return _textures["title"]


func credit_pages(language: int) -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for index: int in range(6):
		result.append(text_bytes(Data._u32(_shell, 0x260f6 + index * 4), language))
	return result


func sound_ids() -> PackedInt32Array:
	var result := PackedInt32Array()
	for index: int in range(37):
		result.append(Data._u32(_shell, 0x23094 + index * 4))
	return result


func sound_name(index: int) -> PackedByteArray:
	if index < 0 or index >= 37:
		return PackedByteArray()
	var pointer := Data._u32(_shell, 0x23094 + index * 4) - 0x8000
	var at := Data._u32(_shell, pointer + 10) - 0x8000
	var end := at
	while end < _shell.size() and _shell[end] != 0:
		end += 1
	return _shell.slice(at, end)


func sound_origin(index: int) -> Vector2:
	var cells := 0
	for code: int in sound_name(index):
		var glyph: Texture2D = ui.character(code)
		if glyph != null:
			cells += glyph.get_width() / 8
	return Vector2((16 - (cells / 2)) * 8, 176)


func text_layout(
	bytes: PackedByteArray, origin: Vector2, wrap_indent: int = 6, wrap_words: bool = true
) -> Dictionary:
	var key := "%s:%s:%d:%s" % [bytes.hex_encode(), origin, wrap_indent, wrap_words]
	if _layouts.has(key):
		return _layouts[key]
	var position := origin
	var commands: Array = []
	var pauses := {}
	for index: int in range(bytes.size()):
		var code := int(bytes[index])
		if code == 13:
			position = Vector2(origin.x, position.y + 24)
			pauses[index] = 6
			continue
		var glyph: Texture2D = ui.character(code)
		if glyph == null:
			continue
		if code == 32:
			# $2EB8E measures the next word in source font cells. A wrap uses
			# the six-cell menu indent; explicit newlines use the normal indent.
			var cells := 0
			for next: int in range(index + 1, bytes.size()):
				if int(bytes[next]) <= 32:
					break
				var following: Texture2D = ui.character(int(bytes[next]))
				if following != null:
					cells += following.get_width() / 8
			if wrap_words and int(position.x) != 0 and int(position.x / 8) + cells + 3 >= 32:
				position = Vector2(wrap_indent * 8, position.y + 24)
				pauses[index] = 6
				continue
		commands.append({"code": code, "x": int(position.x), "y": int(position.y), "index": index})
		position.x += glyph.get_width()
	_layouts[key] = {"commands": commands, "end": position, "pauses": pauses}
	return _layouts[key]


static func _color(word: int) -> Color:
	return Color(
		float(word & 14) / 14.0, float((word >> 4) & 14) / 14.0, float((word >> 8) & 14) / 14.0, 1
	)


func campaign_pages(
	level: int, kills: int, bonuses: int, rating: int = 0, summary: bool = false
) -> Array[Dictionary]:
	# $3137A clear cards and $3182A final summary. Original wording stays on CD;
	# only explicit source pointers and dynamic numbers form this native schema.
	var pages: Array[Dictionary] = []
	if summary:
		pages.append(
			{
				"origin": Vector2(32, 48),
				"commands":
				[
					_card_text(0x33f12),
					_card_line(),
					_card_text(0x3428e),
					_card_number(level),
					_card_text(0x342c0)
				]
			}
		)
		pages.append(
			{
				"origin": Vector2(32, 48),
				"commands": [_card_text(0x33ff2), {"kind": "rating", "value": rating}]
			}
		)
		return pages
	var message: Array = (
		[_card_text(0x343d2), _card_line(), _card_text(0x34362)]
		if level == 16
		else [
			_card_text(0x341c2),
			_card_line(),
			_card_text(0x3422a),
			_card_number(level),
			_card_text(0x34252)
		]
	)
	pages.append({"origin": Vector2(16, 48), "commands": message})
	pages.append(
		{
			"origin": Vector2(16, 48),
			"commands":
			[
				_card_number(kills & 65535),
				_card_text(0x33f4a),
				_card_line(),
				_card_number(bonuses & 65535),
				_card_text(0x33fa0)
			]
		}
	)
	if level < 16:
		pages.append(
			{
				"origin": Vector2(16, 48),
				"commands": [_card_text(0x342ec), {"kind": "number_stop", "value": level + 1}]
			}
		)
	return pages


func campaign_text(page: Dictionary, language: int = 69) -> PackedByteArray:
	var result := PackedByteArray()
	for command: Dictionary in page.commands:
		match command.kind:
			"text":
				var bytes := text_bytes(int(command.value), language)
				# The English reached-level suffix uses $1B as a line break.
				# Preserve its measured blank indentation before the next word.
				for index: int in range(bytes.size()):
					if bytes[index] == 27:
						bytes[index] = 13
				result.append_array(bytes)
			"newline":
				result.append_array(raw_text(0x321c6))
			"number", "number_stop", "rating":
				if command.kind == "rating":
					result.append(32)
				# $2E86E uses signed comparisons and emits zero for negative D0.
				result.append_array(
					(
						str(int(command.value) if int(command.value) < 0x80000000 else 0)
						. to_ascii_buffer()
					)
				)
				if command.kind != "number":
					result.append(46)
	return result


static func _card_text(pointer: int) -> Dictionary:
	return {"kind": "text", "value": pointer}


static func _card_line() -> Dictionary:
	return {"kind": "newline", "value": 0}


static func _card_number(value: int) -> Dictionary:
	return {"kind": "number", "value": value}


func campaign_layout(page: Dictionary, language: int = 69) -> Dictionary:
	var bytes := campaign_text(page, language)
	var layout := text_layout(bytes, page.origin, int(page.origin.x) / 8).duplicate(true)
	var ticks: Array[int] = []
	var tick := 2
	for index: int in range(bytes.size()):
		ticks.append(tick)
		tick += 5 if layout.pauses.has(index) else 3
	for command: Dictionary in layout.commands:
		command.tick = ticks[int(command.index)]
	layout.duration = tick + 5
	layout.bytes = bytes
	return layout


func raw_text(pointer: int) -> PackedByteArray:
	var at := pointer - 0x8000
	if at < 0 or at >= _shell.size():
		return PackedByteArray()
	var end := at
	while end < _shell.size() and _shell[end] != 0:
		end += 1
	return _shell.slice(at, end)


func campaign_preview(index: int, language: int = 69) -> Texture2D:
	var key := "campaign-card:%d:%d" % [index, language]
	if not _textures.has(key):
		var page: Dictionary
		match index:
			0:
				page = campaign_pages(1, 7, 2)[0]
			1:
				page = campaign_pages(16, 112, 3)[0]
			_:
				page = campaign_pages(16, 112, 3, 2515, true)[1]
		var layout := campaign_layout(page, language)
		var image := Image.create_empty(256, 224, false, Image.FORMAT_RGBA8)
		image.fill(Color.BLACK)
		for glyph: Dictionary in layout.commands:
			if int(glyph.code) > 32:
				var texture: Texture2D = ui.character(int(glyph.code))
				if texture != null:
					var source_image := ImmutableTexture.pixels(texture)
					image.blend_rect(
						source_image,
						Rect2i(Vector2i.ZERO, source_image.get_size()),
						Vector2i(glyph.x, glyph.y)
					)
		_textures[key] = ImmutableTexture.create(image)
	return _textures[key]


func noise_color(index: int) -> Color:
	return preload("res://scripts/presentation/cd_menu_palette.gd").packed_colour(noise_targets()[posmod(index,24)])


func score_layout(rows: Array) -> Dictionary:
	# $31B72 header is immediate; $31B94..31C9A writes right-aligned numeric
	# fields and initials at two PAL samples/character, five between fields.
	var commands: Array = []
	for glyph: Dictionary in text_layout(raw_text(0x31dfe), Vector2(0, 16), 0).commands:
		var command := glyph.duplicate()
		command.tick = 1
		commands.append(command)
	var tick := 2
	var last_empty := false
	for index: int in range(rows.size()):
		var row: Dictionary = rows[index]
		var power := int(row.power) & 0xffffffff
		var fields := [
			str(int(row.level)), str(0 if power >= 0x80000000 else power), str(row.initials)
		]
		for field: int in range(3):
			var bytes: PackedByteArray = fields[field].to_ascii_buffer()
			var width: float = text_layout(bytes, Vector2.ZERO).end.x
			var x: float = 184.0 if field == 2 else [56.0, 160.0][field] - width
			var layout := text_layout(bytes, Vector2(x, 48 + index * 24), 0)
			for glyph: Dictionary in layout.commands:
				var command := glyph.duplicate()
				command.tick = tick + int(glyph.index) * 2
				commands.append(command)
			tick += bytes.size() * 2 + 5
			last_empty = bytes.is_empty()
	# Bounded native handoff replaces the graphics queue's last terminator.
	return {"commands": commands, "duration": tick - (5 if last_empty else 4)}


func score_preview() -> Texture2D:
	if not _textures.has("scores"):
		# Synthetic dynamic values; every glyph/palette still comes from CD.
		var layout := score_layout([{"level": 16, "power": 2515, "initials": "AAA"}])
		var image := Image.create_empty(256, 224, false, Image.FORMAT_RGBA8)
		image.fill(Color.BLACK)
		for glyph: Dictionary in layout.commands:
			if int(glyph.code) > 32:
				var source_image: Image = ImmutableTexture.pixels(ui.character(int(glyph.code)))
				image.blend_rect(
					source_image,
					Rect2i(Vector2i.ZERO, source_image.get_size()),
					Vector2i(glyph.x, glyph.y)
				)
		_textures["scores"] = ImmutableTexture.create(image)
	return _textures["scores"]


func pause_codes() -> Array[Dictionary]:
	# Original non-code six-input table. Translate callbacks into native rules;
	# never execute or emulate these original CPU addresses.
	var result: Array[Dictionary] = []
	var at := 0x30950 - 0x8000
	while at + 12 <= _shell.size() and _shell[at] != 0:
		var sequence: Array = []
		for index: int in range(6):
			sequence.append(int(_shell[at + index]))
		result.append({"sequence": sequence, "callback": Data._u32(_shell, at + 6)})
		at += 12
	return result


func pause_layout(language: int = 69) -> Dictionary:
	var bytes := text_bytes(0x33ab2, language)
	var width: float = text_layout(bytes, Vector2.ZERO).end.x
	return text_layout(bytes, Vector2((256 - width) / 2, 112))


func pause_preview(language: int = 69) -> Texture2D:
	var key := "pause:%d" % language
	if not _textures.has(key):
		var image := Image.create_empty(256, 224, false, Image.FORMAT_RGBA8)
		image.fill(Color.BLACK)
		for glyph: Dictionary in pause_layout(language).commands:
			if int(glyph.code) > 32:
				var original: Image = ImmutableTexture.pixels(ui.character(int(glyph.code)))
				image.blend_rect(
					original, Rect2i(Vector2i.ZERO, original.get_size()), Vector2i(glyph.x, glyph.y)
				)
		_textures[key] = ImmutableTexture.create(image)
	return _textures[key]
