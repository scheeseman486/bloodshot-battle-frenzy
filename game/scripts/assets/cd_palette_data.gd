@tool
class_name CdPaletteData
extends RefCounted
## Native 64-colour lookup texture shared by wall, actor and HUD materials.
## Source palettes are loaded from this level and the two SHELL countdown tables.
const Data = preload("res://scripts/assets/cd_level_decoder.gd")
var banks: Array[PackedColorArray] = []
var colors := PackedColorArray()
var texture: ImageTexture
var bank := -1
var _player_flash_word := -1


func decode(level: Resource, shell: PackedByteArray) -> bool:
	banks.clear()
	colors.clear()
	texture = null
	bank = -1
	if level == null or level.source_bytes.size() < 48:
		return false
	var at := Data._u32(level.source_bytes, 16)
	if at + 128 > level.source_bytes.size() or shell.size() < 0x33c44:
		return false
	for source: Dictionary in [
		{"bytes": level.source_bytes, "offset": at},
		{"bytes": shell, "offset": 0x33b44},
		{"bytes": shell, "offset": 0x33bc4}
	]:
		var palette := PackedColorArray()
		for index: int in range(64):
			var word := Data._u16(source.bytes, int(source.offset) + index * 2)
			if (word & ~0xeee) != 0:
				return false
			palette.append(
				Color(
					float(word & 14) / 14.0,
					float((word >> 4) & 14) / 14.0,
					float((word >> 8) & 14) / 14.0,
					1.0
				)
			)
		banks.append(palette)
	bank = -1
	_player_flash_word = -1
	set_bank(0)
	return true


func set_bank(value: int) -> void:
	if value == bank or value < 0 or value >= banks.size():
		return
	bank = value
	_update_texture()


## The CD hit/death sequence changes source palette colour 37. Resolve this
## into the shared native texture so actors and the native view cover agree.
func set_player_flash(word: int) -> void:
	if word == _player_flash_word:
		return
	_player_flash_word = word
	_update_texture()


func _update_texture() -> void:
	if bank < 0:
		return
	colors = banks[bank].duplicate()
	if _player_flash_word >= 0:
		colors[37] = Color(
			float(_player_flash_word & 14) / 14.0,
			float((_player_flash_word >> 4) & 14) / 14.0,
			float((_player_flash_word >> 8) & 14) / 14.0,
			1.0
		)
	var image := Image.create_empty(64, 1, false, Image.FORMAT_RGBA8)
	for index: int in range(64):
		image.set_pixel(index, 0, colors[index])
	if texture == null:
		texture = ImageTexture.create_from_image(image)
	else:
		texture.update(image)


static func index_palette(base: int, transparent: bool = true) -> PackedColorArray:
	var result := PackedColorArray()
	for index: int in range(16):
		result.append(
			Color(float(base + index) / 255.0, 0, 0, 0 if transparent and index == 0 else 1)
		)
	return result
