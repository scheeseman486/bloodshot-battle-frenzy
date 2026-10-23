extends RefCounted
## CD $333BC/$333DC load placement templates 0/6; $36D50 selects by seat.
## Extra seats use a bounded native search connected to the original second start.


static func select(world: RefCounted, seat: int, excluding: int = -1) -> Dictionary:
	if world.level.has_meta("native_spawns"):
		var row: Dictionary = world.level.get_meta("native_spawns")[seat]
		return {"x": row.position.x, "y": row.position.y, "angle": (int(row.angle) & 255) << 6}
	var start := {
		"x": world.level.spawn.x,
		"y": world.level.spawn.y,
		"angle": (int(world.level.spawn_angle) & 255) << 6
	}
	if seat == 0:
		return start
	for placement: Dictionary in world.level.placements:
		if int(placement.template_offset) == 6:
			start = {
				"x": placement.position.x,
				"y": placement.position.y,
				"angle": (int(placement.angle) & 255) << 6
			}
	if seat == 1:
		return start
	var collision := preload("res://scripts/simulation/cd_collision_world.gd").new()
	collision.level = world.level
	collision.fractions = world.groups.map(func(group): return int(group.fraction))
	var origin := Vector2i(start.x, start.y)
	for ring: int in range(1, 9):
		for y: int in range(-ring, ring + 1):
			for x: int in range(-ring, ring + 1):
				if maxi(absi(x), absi(y)) != ring:
					continue
				var point := origin + Vector2i(x, y) * 128
				if collision.query(point).blocked or not _connected(world, origin, point):
					continue
				var occupied := false
				for slot: int in range(world.actor_system.actors.size()):
					# A preflighted native replacement will retire this proxy.
					if excluding >= 0 and slot == int(world.actor_system.player_proxies.get(excluding, -1)):
						continue
					var actor: Dictionary = world.actor_system.actors[slot]
					if (
						int(actor.kind) >= 1
						and int(actor.kind) <= 22
						and absi(int(actor.x) - point.x) < 210
						and absi(int(actor.y) - point.y) < 210
					):
						occupied = true
				if not occupied:
					return {"x": point.x, "y": point.y, "angle": start.angle}
	return {}  # No unchecked teleport through geometry or overlapping fallback.


static func _connected(world: RefCounted, origin: Vector2i, point: Vector2i) -> bool:
	for wall: Dictionary in world.level.walls:
		var offset := Vector2i.ZERO
		if int(wall.motion_kind) != 0 and int(wall.motion_group) < world.groups.size():
			var fraction := int(world.groups[int(wall.motion_group)].fraction)
			offset = Vector2i(
				(int(wall.motion_delta.x) * fraction) >> 12,
				(int(wall.motion_delta.y) * fraction) >> 12
			)
		if (
			Geometry2D.segment_intersects_segment(
				Vector2(origin),
				Vector2(point),
				Vector2(wall.start + offset),
				Vector2(wall.finish + offset)
			)
			!= null
		):
			return false
	return true
