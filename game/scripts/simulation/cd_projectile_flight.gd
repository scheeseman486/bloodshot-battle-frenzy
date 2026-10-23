class_name CdProjectileFlight
extends RefCounted
## Projectile update $039EDE..$03A3DC. Explicit source geometry/ordered targets
## and callbacks keep flight independent of scene physics and rendering.
const ActorAnimation = preload("res://scripts/simulation/cd_actor_animation.gd")


static func advance(
	state: Dictionary,
	elapsed: int,
	level: Resource,
	fractions: Array,
	players: Array,
	active: Array,
	hit: Callable,
	catalog: Resource,
	scratch5: int = 0
) -> Dictionary:
	var result := state.duplicate(true)
	var response := {"state": result, "wall": -1}
	var duration := mini(elapsed, 6)
	var displacement := Vector2i(_word(int(result.vx) * duration), _word(int(result.vy) * duration))
	if int(result.kind) == 27:
		result.height = clampi(
			_word(int(result.height) + _word(int(result.gravity) * duration)), -128, 128
		)
		result.gravity = _word(int(result.gravity) + ((3 * duration) >> 2))
		if int(result.height) == 128:
			response.state = _explode(result, catalog)
			return response
	if int(result.kind) == 26:
		result.age = _word(int(result.age) + 1)
		if int(result.age) == 50:
			response.state = clear(result)
			return response
	else:
		var wall := _wall_query(result, displacement, level, fractions, scratch5)
		result.wall_cursor = int(wall.cursor)
		response.wall = int(wall.index)
		if int(wall.index) >= 0:
			if int(result.kind) == 27 or int(result.kind) == 28:
				response.state = _explode(result, catalog)
				return response
			if int(result.kind) != 25:
				response.state = clear(result)
				return response
			result.age = _word(int(result.age) + 1)
			if int(result.age) == 4:
				response.state = clear(result)
				return response
			var segment: Dictionary = level.walls[int(wall.index)]
			if (
				absi(_word(int(segment.start.y) - int(segment.finish.y)))
				>= absi(_word(int(segment.start.x) - int(segment.finish.x)))
			):
				result.vx = _word(-int(result.vx))
				displacement.x = _word(-displacement.x)
			else:
				result.vy = _word(-int(result.vy))
				displacement.y = _word(-displacement.y)
	result.x = _word(int(result.x) + displacement.x)
	result.y = _word(int(result.y) + displacement.y)
	var point := Vector2i(int(result.x), int(result.y))
	var ahead := Vector2i(
		_word(point.x + (displacement.x >> 1)), _word(point.y + (displacement.y >> 1))
	)
	for player: Dictionary in players:
		if int(player.state) == 0 or int(result.owner) == int(player.id):
			continue
		if _near(point, player, 64) or _near(ahead, player, 64):
			if int(result.kind) == 27 or int(result.kind) == 28:
				response.state = _explode(result, catalog)
				return response
			hit.call(int(player.id))
			if int(result.kind) == 26:
				return response
			response.state = clear(result)
			return response
	# Source tests the owner's address range, including vacant/dead actor slots.
	if int(result.owner) >= 0 and int(result.owner) <= 180:
		return response
	var index := 0
	while index < active.size():
		var target: Dictionary = active[index]
		if _near(point, target, int(target.radius)) or _near(ahead, target, int(target.radius)):
			if int(result.kind) == 27 or int(result.kind) == 28:
				response.state = _explode(result, catalog)
				return response
			var impact: Variant = hit.call(int(target.id))
			var rejected := (
				bool(impact.get("rejected", false)) if impact is Dictionary else bool(impact)
			)
			if impact is Dictionary and impact.has("ahead"):
				ahead = impact.ahead
			if not rejected and int(result.kind) != 26:
				response.state = clear(result)
				return response
		# Active-list removal compacts at the existing cursor in the original;
		# the next source pointer still advances, even after a target dies.
		index += 1
	return response


static func _wall_query(
	state: Dictionary, displacement: Vector2i, level: Resource, fractions: Array, scratch5: int
) -> Dictionary:
	var walls: Array = level.walls
	var cursor := clampi(int(state.wall_cursor), 0, walls.size() - 1)
	var lower := _word(int(state.y) - 256)
	while cursor > 0:
		cursor -= 1
		if lower > int(walls[cursor].start.y):
			cursor += 1
			break
	while cursor < walls.size() - 1 and lower > int(walls[cursor].start.y):
		cursor += 1
	var upper := _word(int(state.y) + 256)
	var origin := Vector2i(int(state.x), int(state.y))
	var midpoint := Vector2i(
		_word(origin.x + (displacement.x >> 1)), _word(origin.y + (displacement.y >> 1))
	)
	var index := cursor
	while index < walls.size():
		var wall: Dictionary = walls[index]
		var a: Vector2i = wall.start
		var b: Vector2i = wall.finish
		if int(wall.motion_kind) != 0 and int(fractions[int(wall.motion_group)]) != 0:
			var fraction := int(fractions[int(wall.motion_group)])
			var delta: Vector2i = wall.motion_delta
			# $03A044/$03A056 have the same zero-MULS word-retention quirk
			# as actor collision. The caller supplies the ordered arithmetic
			# remainder from interaction, movement and preceding actor reactions.
			var scratch := delta.x * fraction if delta.x != 0 else _signed32(scratch5 & 0xffff0000)
			scratch >>= 12
			var offset := Vector2i(_word(scratch), 0)
			scratch = delta.y * fraction if delta.y != 0 else (scratch & ~65535)
			offset.y = _word(scratch >> 12)
			a = Vector2i(_word(a.x + offset.x), _word(a.y + offset.y))
			b = Vector2i(_word(b.x + offset.x), _word(b.y + offset.y))
		if _crosses(origin, midpoint, displacement, a, b):
			return {"cursor": cursor, "index": index}
		index += 1
		if index < walls.size() and int(walls[index].start.y) > upper:
			break
	return {"cursor": cursor, "index": -1}


static func _crosses(
	origin: Vector2i, midpoint: Vector2i, displacement: Vector2i, a: Vector2i, b: Vector2i
) -> bool:
	# This is the source's midpoint/crossing test, including endpoint equality
	# and its rectangular handling of diagonal segments, not a Godot ray cast.
	if mini(a.x, b.x) <= midpoint.x and midpoint.x <= maxi(a.x, b.x):
		if _passed(_word(a.y - origin.y), displacement.y):
			return true
		if a.y != b.y and _passed(_word(b.y - origin.y), displacement.y):
			return true
	if a.y <= midpoint.y and midpoint.y <= b.y:
		if _passed(_word(a.x - origin.x), displacement.x):
			return true
		if a.x != b.x and _passed(_word(b.x - origin.x), displacement.x):
			return true
	return false


static func _passed(distance: int, movement: int) -> bool:
	return movement < distance if distance < 0 else movement >= distance


static func _near(point: Vector2i, target: Dictionary, radius: int) -> bool:
	return (
		absi(_word(int(target.x) - point.x)) <= radius
		and absi(_word(int(target.y) - point.y)) <= radius
	)


static func _explode(state: Dictionary, catalog: Resource) -> Dictionary:
	state.kind = 48
	state.height = 128
	return ActorAnimation.select(state, 0x3044e, catalog).state


static func clear(state: Dictionary) -> Dictionary:
	var result := state.duplicate(true)
	for key: String in result:
		result[key] = -1 if key == "owner" or key == "wall_cursor" else 0
	return result


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768


static func _signed32(value: int) -> int:
	return value - 0x100000000 if value >= 0x80000000 else value
