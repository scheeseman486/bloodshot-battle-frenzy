@tool
extends RefCounted
## Immutable decoded artwork keeps its CPU pixels for persistence. Mutable
## palette/noise textures deliberately use ordinary private ImageTextures.
static var _textures: Dictionary = {}
const PIXELS := &"bloodshot_immutable_pixels"


static func create(image: Image) -> ImageTexture:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(image.get_data())
	var key := (
		"%d:%d:%d:%s:%s"
		% [
			image.get_width(),
			image.get_height(),
			image.get_format(),
			image.has_mipmaps(),
			hash.finish().hex_encode()
		]
	)
	if not _textures.has(key):
		var texture := ImageTexture.create_from_image(image)
		texture.set_meta(PIXELS, image.duplicate())
		_textures[key] = texture
	return _textures[key]


static func pixels(texture: Texture2D) -> Image:
	return texture.get_meta(PIXELS) if texture.has_meta(PIXELS) else texture.get_image()


static func reset_memory() -> void:
	_textures.clear()
