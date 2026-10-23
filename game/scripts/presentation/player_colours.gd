extends RefCounted
## Approved 2026-10-20 HUD ramps: docs/research/approved-player-colours.json.
## Recolour the source skull's two red shades; optionally remove only its well.
const Pixels = preload("res://scripts/assets/cd_immutable_texture.gd")
static var _skulls: Dictionary = {}
const NAMES := ["RED", "BLUE", "GREEN", "GOLD"]
const SKULL_RAMPS := [
	[[72, 0, 0], [218, 0, 0]],
	[[0, 25, 72], [0, 76, 218]],
	[[0, 72, 14], [0, 218, 44]],
	[[72, 54, 0], [218, 164, 0]]
]
const ARMOUR_RAMPS := [
	[[36, 0, 36], [109, 0, 36], [145, 0, 0], [218, 36, 36], [218, 109, 36], [255, 182, 72]],
	[[0, 13, 36], [0, 31, 109], [0, 61, 146], [36, 109, 219], [73, 146, 219], [146, 219, 255]],
	[[0, 36, 24], [0, 109, 36], [0, 146, 36], [36, 219, 73], [109, 219, 73], [182, 255, 146]],
	[[36, 36, 0], [109, 73, 0], [146, 109, 0], [219, 182, 36], [219, 219, 73], [255, 255, 146]]
]


static func mask_profiles() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://resources/ui/player_armour_masks.json"))


## Build only the approved per-frame armour mask from original runtime indices.
## Unknown content fails closed; unrelated enemy corpses have no colour marker.
static func armour_mask(indices: Image, profile: Dictionary) -> Image:
	if indices == null or profile.is_empty():
		return null
	if indices.get_size() != Vector2i(int(profile["size"][0]), int(profile["size"][1])):
		return null
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(indices.get_data())
	if digest.finish().hex_encode() != profile.indices_sha256:
		return null
	var mask := Image.create_empty(indices.get_width(), indices.get_height(), false, Image.FORMAT_L8)
	for y: int in range(indices.get_height()):
		for x: int in range(indices.get_width()):
			var pixel := indices.get_pixel(x, y)
			var index := roundi(pixel.r * 255.0) - 32
			if pixel.a == 0 or index < 8 or index > 13:
				continue
			for rect: Array in profile.regions:
				if x >= rect[0] and y >= rect[1] and x < rect[2] and y < rect[3]:
					mask.set_pixel(x, y, Color.WHITE)
					break
	return mask


static func ramp_image() -> Image:
	var image := Image.create_empty(6, 4, false, Image.FORMAT_RGBA8)
	for colour: int in range(4):
		for step: int in range(6):
			var rgb: Array = ARMOUR_RAMPS[colour][step]
			image.set_pixel(step, colour, Color8(rgb[0], rgb[1], rgb[2]))
	return image


## CPU reference for verification/export; the game uses the shared native shader.
## Palette changes take priority over cosmetics at each changed source entry.
static func armour_image(original: Image, indices: Image, mask: Image, colour: int) -> Image:
	var result := original.duplicate() as Image
	if colour <= 0 or colour >= 4 or mask == null:
		return result
	for y: int in range(result.get_height()):
		for x: int in range(result.get_width()):
			if mask.get_pixel(x, y).r < 0.5:
				continue
			var step := roundi(indices.get_pixel(x, y).r * 255.0) - 40
			var baseline: Array = ARMOUR_RAMPS[0][step]
			var pixel := original.get_pixel(x, y)
			if pixel != Color8(baseline[0], baseline[1], baseline[2], roundi(pixel.a * 255)):
				continue
			var rgb: Array = ARMOUR_RAMPS[colour][step]
			result.set_pixel(x, y, Color8(rgb[0], rgb[1], rgb[2], roundi(original.get_pixel(x, y).a * 255)))
	return result


static func skull_image(original: Image, colour: int, transparent_well: bool = false) -> Image:
	assert(colour >= 0 and colour < NAMES.size())
	var result := original.duplicate() as Image
	if colour == 0 and not transparent_well:
		return result
	for y: int in range(result.get_height()):
		for x: int in range(result.get_width()):
			var pixel := result.get_pixel(x, y)
			# The source icon uses these two steel-blue entries only for the well.
			# Keep black skull details and every red ramp pixel; remove no outline.
			var rgb8 := Vector3i(roundi(pixel.r * 255), roundi(pixel.g * 255), roundi(pixel.b * 255))
			if transparent_well and rgb8 in [Vector3i(72, 72, 109), Vector3i(36, 36, 72)]:
				result.set_pixel(x, y, Color(pixel.r, pixel.g, pixel.b, 0))
				continue
			if pixel.a == 0 or pixel.g != 0 or pixel.b != 0:
				continue
			var index := [72, 218].find(roundi(pixel.r * 255.0))
			if index < 0:
				continue
			var rgb: Array = SKULL_RAMPS[colour][index]
			result.set_pixel(x, y, Color8(rgb[0], rgb[1], rgb[2], roundi(pixel.a * 255.0)))
	return result


static func skull_texture(original: Texture2D, colour: int, transparent_well: bool = false) -> Texture2D:
	var key := "%s:%d:%s" % [original.get_instance_id(), colour, transparent_well]
	if not _skulls.has(key):
		_skulls[key] = Pixels.create(skull_image(Pixels.pixels(original), colour, transparent_well))
	return _skulls[key]
