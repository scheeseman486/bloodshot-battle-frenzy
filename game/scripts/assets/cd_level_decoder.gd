@tool
class_name CdLevelDecoder
extends RefCounted
## European CD layout; see docs/research/cd-level-format.md for CPU evidence.

const Level = preload("res://scripts/assets/cd_level_data.gd")

static func _u16(data: PackedByteArray, offset: int) -> int:
	return (data[offset] << 8) | data[offset + 1]


static func _s16(data: PackedByteArray, offset: int) -> int:
	var value := _u16(data, offset)
	return value - 65536 if value >= 32768 else value


static func _u32(data: PackedByteArray, offset: int) -> int:
	return (_u16(data, offset) << 16) | _u16(data, offset + 2)


static func _span(data: PackedByteArray, offset: int, count: int) -> bool:
	return offset >= 48 and count > 0 and offset <= data.size() and count <= data.size() - offset


static func decode(data: PackedByteArray) -> Resource:
	if data.size() < 48:
		return null
	var wall_count := _u16(data, 0)
	var wall_offset := _u32(data, 2)
	var placement_count := _u16(data, 6)
	var placement_offset := _u32(data, 8)
	var palette_offset := _u32(data, 16)
	if not _span(data, wall_offset, wall_count * 20) or not _span(data, placement_offset, placement_count * 10) or not _span(data, palette_offset, 64):
		return null
	# Refuse tables that overlap. Do not guess a different edition's layout.
	if wall_offset + wall_count * 20 > placement_offset or placement_offset + placement_count * 10 > palette_offset:
		return null
	var result := Level.new()
	result.dynamic_start = _u16(data, 12)
	result.countdown_seconds = _u16(data, 20)
	var group_count := _u16(data, 14)
	if group_count > 256:
		return null
	for index: int in range(group_count):
		result.moving_groups.append({"kind": 0, "first": -1, "last": -1})
	for i: int in range(32):
		var color := _u16(data, palette_offset + i * 2)
		# Three significant channel bits. Analog intensity is not calibrated yet.
		result.palette.append(Color(float(color & 14) / 14.0, float((color >> 4) & 14) / 14.0, float((color >> 8) & 14) / 14.0, 1.0))
	for i: int in range(wall_count):
		var at := wall_offset + i * 20
		var pointer := _u32(data, at)
		var width := _u16(data, at + 4)
		var texture_offset := pointer & 0x7fffffff
		if width < 2 or width > 512 or width % 2 != 0 or not _span(data, texture_offset, width * 32):
			return null
		result.walls.append({
			"texture_offset": texture_offset, "texture_width": width, "mirror": (pointer & 0x80000000) != 0,
			"start": Vector2i(_s16(data, at + 6), _s16(data, at + 8)),
			"finish": Vector2i(_s16(data, at + 10), _s16(data, at + 12)),
			"motion_kind": data[at + 14], "motion_group": data[at + 15],
			"motion_delta": Vector2i(_s16(data, at + 16), _s16(data, at + 18))})
		if data[at + 14] != 0:
			var group := int(data[at + 15])
			if group >= group_count:
				return null
			if int(result.moving_groups[group].first) < 0:
				result.moving_groups[group].kind = int(data[at + 14])
				result.moving_groups[group].first = i
			result.moving_groups[group].last = i
	var found_spawn := false
	for i: int in range(placement_count):
		var at := placement_offset + i * 10
		var placement := {"template_offset": _u32(data, at), "angle": _s16(data, at + 4), "position": Vector2i(_s16(data, at + 6), _s16(data, at + 8))}
		result.placements.append(placement)
		if placement.template_offset == 0:
			result.spawn = placement.position
			result.spawn_angle = placement.angle
			found_spawn = true
	if not found_spawn:
		return null
	result.source_bytes = data.duplicate()
	return result


static func decode_wall_image(data: PackedByteArray, offset: int, width: int, palette: PackedColorArray, mirror: bool = false) -> Image:
	if width < 2 or width > 512 or width % 2 != 0 or palette.size() < 32 or not _span(data, offset, width * 32):
		return null
	var image := Image.create_empty(width, 128, false, Image.FORMAT_RGBA8)
	for x: int in range(width):
		var source_x := width - 1 - x if mirror else x
		for y: int in range(64):
			# One byte holds adjacent X pixels. Column pairs have 64 rows.
			var packed: int = data[offset + (source_x >> 1) * 64 + y]
			var index: int = (packed >> 4) if source_x % 2 == 0 else (packed & 15)
			# Original texture rows run from the horizon towards the outer edge.
			# Reverse within each half; retain the upper/lower palette assignment.
			image.set_pixel(x, 63 - y, palette[index])
			# Bake the original reflected lower half into this texture. The native
			# world and camera render once; no screen reflection or palette pass.
			image.set_pixel(x, 64 + y, palette[16 + index])
	return image
