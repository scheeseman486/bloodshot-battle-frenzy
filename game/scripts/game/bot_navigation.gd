extends RefCounted
## One rebuildable navigation model per authority. No actors/hidden doors in A*.
static var _prepared: Dictionary = {}
static var preparation_builds := 0

var grid: AStarGrid2D
var geometry := preload("res://scripts/game/native_drop_geometry.gd").new()
var origin := Vector2.ZERO
var identity := ""
var walkable: Array[Vector2i] = []


func configure(level: Resource) -> void:
	if identity == level.source_sha256 and grid != null:
		return
	identity = level.source_sha256
	geometry.configure(level)
	if _prepared.has(identity):
		var model: Dictionary = _prepared[identity]
		grid = model.grid
		origin = model.origin
		walkable = model.walkable.duplicate()
		return
	var bounds: Rect2 = geometry.bounds
	origin = (bounds.position / 128.0).floor() * 128.0
	grid = AStarGrid2D.new()
	grid.region = Rect2i(Vector2i.ZERO, Vector2i((bounds.end - origin) / 128.0) + Vector2i.ONE)
	grid.cell_size = Vector2(128, 128)
	grid.offset = origin
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()
	walkable.clear()
	var collision := preload("res://scripts/simulation/cd_collision_world.gd").new()
	collision.level = level
	collision.fractions = level.moving_groups.map(func(_group): return 4096)
	for y: int in range(grid.region.size.y):
		for x: int in range(grid.region.size.x):
			var point := Vector2i(origin + Vector2(x, y) * 128.0)
			var solid: bool = not bounds.has_point(Vector2(point)) or collision.query(point).blocked
			grid.set_point_solid(Vector2i(x, y), solid)
			if not solid:
				walkable.append(point)
	_prepared[identity] = {"grid":grid, "origin":origin, "walkable":walkable.duplicate()}
	preparation_builds += 1


func cell(point: Vector2i) -> Vector2i:
	var center := Vector2i(((Vector2(point) - origin) / 128.0).round())
	for radius: int in range(6):
		for y: int in range(-radius, radius + 1):
			for x: int in range(-radius, radius + 1):
				var candidate := center + Vector2i(x, y)
				if grid.is_in_boundsv(candidate) and not grid.is_point_solid(candidate):
					return candidate
	return Vector2i(-1, -1)


func path(start: Vector2i, end: Vector2i) -> Array:
	var a := cell(start)
	var b := cell(end)
	if a.x < 0 or b.x < 0:
		return []
	var result := []
	for point: Vector2 in grid.get_point_path(a, b):
		if result.size() >= 2048:
			break
		result.append(Vector2i(point))
	return result
