class_name CdVisibilityQuery
extends RefCounted
## Behaviour-only projection/occlusion: original $386A8..$38D00 and $324AC.
## These spatial query results feed awareness, targeting and door eligibility.
## Godot's geometry renderer never consumes this workspace or draws its samples.
const HALF := 112
const INVERSE_SCALE := 51200


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768


static func _long(value: int) -> int:
	value &= 0xffffffff
	return value - 0x100000000 if value >= 0x80000000 else value


static func _divide(a: int, b: int) -> int:
	@warning_ignore("integer_division")
	return a / b


static func transform(point: Vector2i, player: Dictionary, tables: Resource) -> Vector2i:
	var dx := _word(point.x - int(player.x))
	var dy := _word(point.y - int(player.y))
	var angle := int(player.view_angle) & 255
	var sine := int(tables.sine[angle])
	var cosine := int(tables.cosine[angle])
	return Vector2i(
		_word(_long((dx * sine + dy * cosine) << 2) >> 16),
		_word(_long((dy * sine - dx * cosine) << 1) >> 16)
	)


static func _project(point: Vector2i) -> int:
	if point.y > 0:
		var x := _divide(point.x * 80, point.y)
		if x >= -32768 and x <= 32767:
			return x
	return -116 if point.x < 0 else 116


static func _clipped_inverse(origin: Vector2i, delta: Vector2i, side: int) -> int:
	var numerator := _long((delta.y * side * 160 - delta.x * 12800) << 2)
	var denominator := _long(origin.x * delta.y - origin.y * delta.x)
	if denominator < 0:
		denominator = _long(-denominator)
		numerator = _long(-numerator)
	while denominator >= 65536:
		denominator >>= 4
		numerator >>= 4
	if denominator == 0:
		return -1
	var inverse := _divide(numerator & 0xffffffff, denominator)
	return (
		((numerator & 0xffffffff) % denominator) * 65536 + inverse
		if inverse >= 0 and inverse < 32768
		else -1
	)


static func wall_span(
	wall: Dictionary, player: Dictionary, tables: Resource, groups: Array
) -> Dictionary:
	var displacement := Vector2i.ZERO
	if int(wall.motion_kind) != 0:
		var door_fraction := int(groups[int(wall.motion_group)].fraction)
		if door_fraction != 0:
			var x: int = (wall.motion_delta.x * door_fraction) >> 12
			var y: int = (wall.motion_delta.y * door_fraction) >> 12
			# $386FE..$38710 replaces only D5's low word before a zero-Y
			# branch. A negative X displacement retains FFFF in its high word.
			if wall.motion_delta.y == 0 and x < 0:
				y = -16
			displacement = Vector2i(x, y)
	var a := transform(wall.start + displacement, player, tables)
	var b := transform(wall.finish + displacement, player, tables)
	if a.y <= 0 and b.y <= 0:
		return {}
	var left := _project(a)
	var right := _project(b)
	if right <= left:
		var swap := a
		a = b
		b = swap
		var x := left
		left = right
		right = x
	if right < -HALF or left > HALF:
		return {}
	var delta := Vector2i(_word(b.x - a.x), _word(b.y - a.y))
	var inverse_left: int
	var inverse_right: int
	if left < -HALF:
		left = -HALF
		inverse_left = _clipped_inverse(a, delta, -HALF)
	else:
		inverse_left = _divide(INVERSE_SCALE, a.y)
	if right > HALF:
		right = HALF
		inverse_right = _clipped_inverse(a, delta, HALF)
	else:
		inverse_right = _divide(INVERSE_SCALE, b.y)
	var fraction := (inverse_left >> 16) & 65535
	var right_fraction := (inverse_right >> 16) & 65535
	if inverse_left >= 0:
		inverse_left &= 65535
	if inverse_right >= 0:
		inverse_right &= 65535
	var count := right - left
	if (
		count <= 0
		or inverse_left < 0
		or inverse_left >= 32768
		or inverse_right < 0
		or inverse_right >= 32768
	):
		return {}
	return {
		"first": left + HALF,
		"count": count,
		"inverse": inverse_left,
		"fraction": fraction,
		"step":
		_divide(
			_long(((_word(inverse_right - inverse_left) & 65535) << 16) | right_fraction), count
		)
	}


static func world(
	level: Resource, player: Dictionary, tables: Resource, groups: Array, previous: Dictionary = {}
) -> Dictionary:
	var inverse: Array = []
	var owners: Array = []
	inverse.resize(224)
	inverse.fill(0)
	owners.resize(224)
	owners.fill(-1)
	var visited: Dictionary = {}
	var anchor := int(previous.get("range", [-1, -1])[0])
	if anchor >= 0 and anchor < level.walls.size():
		var previous_bounds: Array = previous.bounds
		for expansion: int in [512, 1280, 3328, 5376]:
			var low_y := _word(int(previous_bounds[2]) - expansion)
			var high_y := _word(int(previous_bounds[3]) + expansion)
			var low_x := _word(int(previous_bounds[0]) - expansion)
			var high_x := _word(int(previous_bounds[1]) + expansion)
			var index := anchor
			while index >= 0 and level.walls[index].start.y >= low_y:
				if level.walls[index].start.x >= low_x and level.walls[index].start.x <= high_x:
					_draw_wall(index, level, player, tables, groups, visited, inverse, owners)
				index -= 1
			index = anchor + 1
			while index < level.walls.size() and level.walls[index].start.y <= high_y:
				if level.walls[index].start.x >= low_x and level.walls[index].start.x <= high_x:
					_draw_wall(index, level, player, tables, groups, visited, inverse, owners)
				index += 1
			if not inverse.has(0):
				break
	if inverse.has(0):
		for index: int in range(level.walls.size()):
			_draw_wall(index, level, player, tables, groups, visited, inverse, owners)
	var bounds: Array = []
	var first: int = level.walls.size()
	var last := -1
	for index: int in owners.slice(0, 223):
		if index < 0:
			continue
		first = mini(first, index)
		last = maxi(last, index)
		var wall: Dictionary = level.walls[index]
		if bounds.is_empty():
			bounds = [wall.start.x, wall.start.x, wall.start.y, wall.start.y]
		for point: Vector2i in [wall.start, wall.finish]:
			bounds[0] = mini(bounds[0], point.x)
			bounds[1] = maxi(bounds[1], point.x)
			bounds[2] = mini(bounds[2], point.y)
			bounds[3] = maxi(bounds[3], point.y)
	return {"inverse": inverse, "owners": owners, "bounds": bounds, "range": [first, last]}


static func _draw_wall(
	index: int,
	level: Resource,
	player: Dictionary,
	tables: Resource,
	groups: Array,
	visited: Dictionary,
	inverse: Array,
	owners: Array
) -> void:
	if visited.has(index):
		return
	visited[index] = true
	var span := wall_span(level.walls[index], player, tables, groups)
	if span.is_empty():
		return
	var depth := (int(span.inverse) << 16) | int(span.fraction)
	for column: int in range(int(span.first), int(span.first) + int(span.count)):
		var value := _word(depth >> 16)
		if int(inverse[column]) == 0 or value > int(inverse[column]):
			inverse[column] = value
			owners[column] = index
		depth = _long(depth + int(span.step))


static func actor(
	state: Dictionary, player: Dictionary, tables: Resource, catalog: Resource, view: Dictionary
) -> Dictionary:
	var result := {"visible": false, "candidate": false, "offset": 32767}
	var bounds: Array = view.bounds
	if not bounds.is_empty():
		if (
			int(state.x) < mini(int(bounds[0]), int(player.x))
			or int(state.x) > maxi(int(bounds[1]), int(player.x))
			or int(state.y) < mini(int(bounds[2]), int(player.y))
			or int(state.y) > maxi(int(bounds[3]), int(player.y))
		):
			return result
	var point := transform(Vector2i(int(state.x), int(state.y)), player, tables)
	if point.y <= 0:
		return result
	var offset := _divide(point.x * 80, point.y)
	if offset < -224 or offset > 224:
		return result
	var frame: Dictionary = catalog.frames[int(state.frame)]
	var width := _divide(int(frame.width) * 200, point.y)
	var height := _divide(int(frame.height) * 200, point.y)
	if width < 3 or height < 2:
		return result
	var x := offset - _divide(frame.anchor.x * 160, point.y)
	var y := _divide(int(state.height) * 100, point.y) - _divide(frame.anchor.y * 200, point.y)
	var first := maxi(x, -HALF)
	var end := mini(x + width, HALF)
	if end <= first or y + height <= -80 or y >= 80:
		return result
	var inverse := _divide(INVERSE_SCALE, point.y)
	for column: int in range(first + HALF, end + HALF):
		if inverse > int(view.inverse[column]):
			result.visible = true
			break
	result.offset = offset
	var targeted := bool(state.get("targeted", int(state.get("target", -1)) >= 0))
	result.candidate = (
		result.visible and int(state.kind) >= 1 and int(state.kind) <= 19 and targeted
	)
	return result
