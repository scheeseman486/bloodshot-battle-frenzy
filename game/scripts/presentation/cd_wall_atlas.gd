@tool
extends RefCounted
## Level-owned native atlas, composed only from runtime CD index images. Padding
## preserves edge samples; the original wall images and palette remain unchanged.
const Pixels = preload("res://scripts/assets/cd_immutable_texture.gd")
const WIDTH := 1024
const MAX_HEIGHT := 4096
var regions: Array[Rect2i] = []
var texture: ImageTexture
var last_error := ""


func build(source: RefCounted, level: Resource) -> bool:
	regions.clear()
	texture = null
	last_error = ""
	var entries := {}
	var cursor := Vector2i(1, 1)
	var row_height := 0
	for index: int in range(level.walls.size()):
		var original: Texture2D = source.index_texture_from_cd_wall(level, index)
		if original == null:
			last_error = source.last_error
			return false
		var key := original.get_instance_id()
		if not entries.has(key):
			# CPU pixels are retained by the prepared cache; never read back a GPU
			# texture while attaching a level or constructing a presentation frame.
			var image: Image = Pixels.pixels(original)
			var size := image.get_size()
			if size.x + 2 > WIDTH or size.y + 2 > MAX_HEIGHT:
				last_error = "CD wall image exceeds native atlas bounds"
				return false
			if cursor.x + size.x + 1 > WIDTH:
				cursor = Vector2i(1, cursor.y + row_height)
				row_height = 0
			var region := Rect2i(cursor, size)
			entries[key] = {"image": image, "region": region}
			cursor.x += size.x + 2
			row_height = maxi(row_height, size.y + 2)
		regions.append(entries[key].region)
	var height := nearest_po2(cursor.y + row_height)
	if height > MAX_HEIGHT:
		last_error = "CD wall atlas exceeds bounded native texture size"
		return false
	var atlas := Image.create_empty(WIDTH, height, false, Image.FORMAT_RGBA8)
	for entry: Dictionary in entries.values():
		var image: Image = entry.image
		var region: Rect2i = entry.region
		atlas.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), region.position)
		# Extrude all four borders, including the corners, into a one-pixel gutter.
		for x: int in range(-1, region.size.x + 1):
			for y: int in [-1, region.size.y]:
				atlas.set_pixelv(
					region.position + Vector2i(x, y),
					image.get_pixel(
						clampi(x, 0, region.size.x - 1), clampi(y, 0, region.size.y - 1)
					)
				)
		for y: int in range(region.size.y):
			atlas.set_pixelv(region.position + Vector2i(-1, y), image.get_pixel(0, y))
			atlas.set_pixelv(
				region.position + Vector2i(region.size.x, y), image.get_pixel(region.size.x - 1, y)
			)
	# The launch-prepared native geometry model retains this runtime atlas.
	# It stays in RAM; original artwork and generated meshes are never shipped.
	texture = ImageTexture.create_from_image(atlas)
	texture.set_meta(Pixels.PIXELS, atlas)
	return true


func uv(wall: int, coordinate: Vector2) -> Vector2:
	var region := Rect2(regions[wall])
	return (region.position + coordinate * region.size) / Vector2(texture.get_size())
