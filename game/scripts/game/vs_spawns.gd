extends RefCounted
## Approved native spawn additions. No original geometry/AI RNG is changed.
const Collision = preload("res://scripts/simulation/cd_collision_world.gd")


static func pool(level: Resource) -> Array:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://resources/gameplay/vs_arena_spawns.json"))
	if not data.arenas.has(level.source_sha256):
		return []
	var result := []
	for placement: Dictionary in level.placements:
		if int(placement.template_offset) in [0, 6]:
			result.append({"x": int(placement.position.x), "y": int(placement.position.y),
				"angle": (int(placement.angle) & 255) << 6})
	for point: Dictionary in data.arenas[level.source_sha256]:
		result.append({"x": int(point.x), "y": int(point.y), "angle": int(point.angle)})
	return result


static func candidates(world: RefCounted, excluding: int = -1, reserved: Array = []) -> Array:
	var collision := Collision.new()
	collision.level = world.level
	collision.fractions = world.groups.map(func(group): return int(group.fraction))
	var result := []
	for spawn: Dictionary in pool(world.level):
		var point := Vector2i(spawn.x, spawn.y)
		if collision.query(point).blocked:
			continue
		var occupied := false
		var nearest := 0x7fffffff
		for actor: Dictionary in world.actor_system.actors:
			if int(actor.kind) in range(1, 23) and int(actor.kind) != 20:
				if (Vector2i(actor.x, actor.y) - point).length_squared() < 105 * 105:
					occupied = true
		for player: RefCounted in world.players:
			if player.handle == excluding or int(player.fighter.state) != 1:
				continue
			var delta := Vector2i(player.motion.x, player.motion.y) - point
			if delta.length_squared() < 210 * 210:
				occupied = true
			nearest = mini(nearest, int(delta.length_squared()))
		for planned: Dictionary in reserved:
			var distance := (Vector2i(planned.x, planned.y) - point).length_squared()
			if distance < 210 * 210:
				occupied = true
			nearest = mini(nearest, int(distance))
		if not occupied:
			var weight := 1 if nearest == 0x7fffffff else 1 + mini(nearest / 65536, 64)
			result.append({"spawn": spawn, "weight": weight})
	return result


static func select(world: RefCounted, excluding: int = -1) -> Dictionary:
	return _select(candidates(world, excluding), world.vs_state)


## Preflight a complete live addition without publishing players or drawing from
## the live RNG. Reserved starts affect occupancy and distance just like players.
static func batch(world: RefCounted, count: int) -> Dictionary:
	if count < 1 or count > 3: return {}
	var state := {"rng": world.vs_state.rng}
	var spawns := []
	for index: int in range(count):
		var spawn := _select(candidates(world, -1, spawns), state)
		if spawn.is_empty(): return {}
		spawns.append(spawn)
	return {"spawns": spawns, "rng": state.rng}


static func _select(choices: Array, state: Dictionary) -> Dictionary:
	if choices.is_empty(): return {}
	var total := 0
	for choice: Dictionary in choices: total += int(choice.weight)
	# Rejection sampling avoids modulo bias. This stream is native match state,
	# never one of the source movement/attack RNG streams.
	var bound := (0x100000000 / total) * total
	var draw := 0
	while true:
		state.rng = (int(state.rng) * 1664525 + 1013904223) & 0xffffffff
		draw = int(state.rng)
		if draw < bound: break
	draw %= total
	for choice: Dictionary in choices:
		draw -= int(choice.weight)
		if draw < 0: return choice.spawn.duplicate()
	return {}
