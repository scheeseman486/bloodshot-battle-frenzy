@tool
class_name IndexedImageDecoder
extends RefCounted
## Decode a verified linear packed-4bpp span into a Godot Image. Game-specific
## layouts, compression and palettes must be identified before using this decoder.

static func decode_linear_4bpp(data: PackedByteArray, size: Vector2i, palette: PackedColorArray) -> Image:
	if size.x <= 0 or size.y <= 0 or size.x > 4096 or size.y > 4096 or palette.size() != 16:
		return null
	var pixels: int = size.x * size.y
	if data.size() * 2 < pixels:
		return null
	var rgba := PackedByteArray()
	rgba.resize(pixels * 4)
	for pixel: int in range(pixels):
		var packed: int = data[pixel >> 1]
		var index: int = (packed >> 4) if pixel % 2 == 0 else (packed & 15)
		var color: Color = palette[index]
		rgba[pixel * 4] = color.r8
		rgba[pixel * 4 + 1] = color.g8
		rgba[pixel * 4 + 2] = color.b8
		rgba[pixel * 4 + 3] = color.a8
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, rgba)
