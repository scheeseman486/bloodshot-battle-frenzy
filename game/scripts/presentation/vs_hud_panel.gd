extends RefCounted
## Numeric patch recipe recovered from the owner's saved GIMP composition.
## Build at its 2x authoring grid to retain odd offsets; all pixels come from
## runtime CD artwork and the approved small-font catalog, never new drawing.
const Pixels = preload("res://scripts/assets/cd_immutable_texture.gd")
## Six source wells in column-major inventory order. The unchanged panel is
## 56x61 source pixels; two rows centre the existing 16x16 icons vertically.
const WEAPON_POSITIONS: Array[Vector2] = [
	Vector2(72,16), Vector2(72,32), Vector2(88,16),
	Vector2(88,32), Vector2(104,16), Vector2(104,32)
]
## Compact multiplayer grid for the wide HUD: two columns, three rows, with
## the original multiplayer frame rather than unused single-player wells.
const WIDE_WEAPON_POSITIONS: Array[Vector2] = [
	Vector2(72,8), Vector2(72,24), Vector2(72,40),
	Vector2(88,8), Vector2(88,24), Vector2(88,40)
]

static func compose(ui: RefCounted, font: RefCounted, kills: int, white_index: int) -> Image:
	var donor: Image = Pixels.pixels(ui.frame(true)).get_region(Rect2i(144, 0, 112, 28))
	donor.resize(224, 56, Image.INTERPOLATE_NEAREST)
	var panel := Image.create_empty(224, 56, false, Image.FORMAT_RGBA8)
	# A source black texel replaces the transparent holes and erased separators.
	var black := donor.get_region(Rect2i(0, 0, 1, 1))
	black.resize(224, 56, Image.INTERPOLATE_NEAREST)
	panel.blit_rect(black, Rect2i(0, 0, 224, 56), Vector2i.ZERO)
	panel.blend_rect(donor, Rect2i(0, 0, 224, 56), Vector2i.ZERO)
	for x: int in [96, 144]:
		panel.blit_rect(black, Rect2i(0, 0, 16, 32), Vector2i(x, 16))
	for patch: Array in [[96, 24], [139, 30]]:
		for y: int in [8, 48]:
			panel.blend_rect(donor, Rect2i(18, y, patch[1], 8), Vector2i(patch[0], y))
	_word(panel, font, "KILLS", Vector2i(66, 23), white_index)
	_word(panel, font, ":", Vector2i(134, 23), white_index)
	var digits := "%02d" % clampi(kills, 0, 99)
	_word(panel, font, digits[0], Vector2i(168, 23), white_index)
	_word(panel, font, digits[1], Vector2i(180, 23), white_index)
	return panel


static func _word(panel: Image, font: RefCounted, value: String, origin: Vector2i, white: int) -> void:
	for character: String in value:
		var glyph: Image = Pixels.pixels(font.glyph(character.unicode_at(0)))
		var width := glyph.get_used_rect().end.x
		var ink := Image.create_empty(width, 10, false, Image.FORMAT_RGBA8)
		for y: int in range(glyph.get_height()):
			for x: int in range(width):
				if glyph.get_pixel(x, y).a > 0:
					ink.set_pixel(x, y + (1 if glyph.get_height() == 9 else 0), Color(white / 255.0, 0, 0, 1))
		ink.resize(width * 2, 20, Image.INTERPOLATE_NEAREST)
		panel.blend_rect(ink, Rect2i(Vector2i.ZERO, ink.get_size()), origin)
		origin.x += (width + 1) * 2
