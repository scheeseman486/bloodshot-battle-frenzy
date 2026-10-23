extends RefCounted
## Rebuildable native pickup collision index. Never touches CD collision scratch.
const RADIUS := 100.0
const CELL := 256.0
static var _prepared: Dictionary = {}

var bounds := Rect2()
var cells: Dictionary = {}
var moving: Array = []
var _groups: Array = [null]
var _dynamic_cells: Dictionary = {}
var _spawn := Vector2.ZERO


func configure(level: Resource) -> void:
	cells = {}
	_spawn = Vector2(level.spawn)
	moving = []
	_groups = [null]
	_dynamic_cells.clear()
	if not level.source_sha256.is_empty() and _prepared.has(level.source_sha256):
		var model: Dictionary = _prepared[level.source_sha256]
		bounds = model.bounds
		cells = model.cells
		moving = model.moving
		return
	var first := true
	for wall: Dictionary in level.walls:
		var a := Vector2(wall.start)
		var b := Vector2(wall.finish)
		if first:
			bounds = Rect2(a, Vector2.ZERO)
			first = false
		bounds = bounds.expand(a).expand(b)
		if int(wall.motion_kind) != 0:
			moving.append(wall)
			continue
		var area := Rect2(a, Vector2.ZERO).expand(b).grow(RADIUS + 1)
		for y: int in range(floori(area.position.y / CELL), floori(area.end.y / CELL) + 1):
			for x: int in range(floori(area.position.x / CELL), floori(area.end.x / CELL) + 1):
				var key := Vector2i(x, y)
				if not cells.has(key):
					cells[key] = []
				cells[key].append([a, b])
	for segments_in_cell: Array in cells.values():
		for segment: Array in segments_in_cell: segment.make_read_only()
		segments_in_cell.make_read_only()
	cells.make_read_only()
	moving.make_read_only()
	if not level.source_sha256.is_empty():
		_prepared[level.source_sha256] = {"bounds":bounds, "cells":cells, "moving":moving}


func sync(groups: Array) -> void:
	if groups == _groups:
		return
	_groups = groups.duplicate(true)
	_dynamic_cells.clear()
	for wall: Dictionary in moving:
		var group := int(wall.motion_group)
		var fraction := int(groups[group].fraction) if group < groups.size() else 0
		var offset := Vector2((int(wall.motion_delta.x) * fraction) >> 12,
			(int(wall.motion_delta.y) * fraction) >> 12)
		var a := Vector2(wall.start) + offset
		var b := Vector2(wall.finish) + offset
		var area := Rect2(a, Vector2.ZERO).expand(b).grow(RADIUS + 1)
		for y: int in range(floori(area.position.y / CELL), floori(area.end.y / CELL) + 1):
			for x: int in range(floori(area.position.x / CELL), floori(area.end.x / CELL) + 1):
				var key := Vector2i(x, y)
				if not _dynamic_cells.has(key):
					_dynamic_cells[key] = []
				_dynamic_cells[key].append([a, b])


func segments(point: Vector2, groups: Array, doors: bool = true) -> Array:
	sync(groups)
	var key := Vector2i(floori(point.x / CELL), floori(point.y / CELL))
	var result: Array = cells.get(key, []).duplicate()
	if doors:
		result.append_array(_dynamic_cells.get(key, []))
	return result


func obstacle(point: Vector2, groups: Array) -> Dictionary:
	if not bounds.grow(-RADIUS).has_point(point):
		return {"normal": (bounds.get_center() - point).normalized()}
	for segment: Array in segments(point, groups):
		var nearest := Geometry2D.get_closest_point_to_segment(point, segment[0], segment[1])
		var delta := point - nearest
		if delta.length_squared() < RADIUS * RADIUS:
			var normal := delta.normalized()
			if normal == Vector2.ZERO:
				normal = (Vector2(segment[1]) - Vector2(segment[0])).orthogonal().normalized()
			return {"normal": normal}
	return {}


func line_clear(a: Vector2, b: Vector2, groups: Array, doors: bool = true) -> bool:
	# Subdivision also finds intervening indexed cells on longer recovery paths.
	var steps := maxi(1, ceili(a.distance_to(b) / 64.0))
	for index: int in range(steps + 1):
		for segment: Array in segments(a.lerp(b, float(index) / steps), groups, doors):
			if Geometry2D.segment_intersects_segment(a, b, segment[0], segment[1]) != null:
				return false
	return true


func recover(point: Vector2, anchor: Vector2, groups: Array) -> Vector2:
	if obstacle(point, groups).is_empty():
		return point
	# Prefer the recorded reachable side when a closing door engulfs an item.
	if obstacle(anchor, groups).is_empty():
		return anchor
	# A closing door can engulf an item. Search its original static-wall region,
	# never send it through a solid wall to an otherwise nearby free point.
	for radius: int in range(16, 513, 16):
		for direction: int in range(16):
			var candidate := point + Vector2.from_angle(direction * TAU / 16) * radius
			if obstacle(candidate, groups).is_empty() and line_clear(point, candidate, groups, false):
				return candidate
	if obstacle(anchor, groups).is_empty():
		return anchor
	# Last-resort sanity recovery uses the map's known playable spawn, rather
	# than leaving a required key permanently inside closed geometry.
	if obstacle(_spawn, groups).is_empty():
		return _spawn
	for radius: int in range(16, 513, 16):
		for direction: int in range(16):
			var candidate := _spawn + Vector2.from_angle(direction * TAU / 16) * radius
			if obstacle(candidate, groups).is_empty() and line_clear(_spawn, candidate, groups, false):
				return candidate
	return point  # Kept for a later retry; callers never delete inaccessible keys.
