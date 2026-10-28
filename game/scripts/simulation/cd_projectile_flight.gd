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
	scratch5: int = 0,
	swept: bool = false
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
	var origin := Vector2i(int(result.x), int(result.y))
	var wall := {"cursor": int(result.wall_cursor), "index": -1, "fraction": 1.0}
	if int(result.kind) != 26:
		wall = _wall_query(result, displacement, level, fractions, scratch5, swept)
	var processed := {}
	if swept:
		var impact := _sweep_hits(
			result, origin, displacement, players, active, hit, catalog, processed,
			float(wall.get("fraction", 1.0)), int(wall.index) >= 0
		)
		if impact.stop:
			response.state = impact.state
			return response
	if int(result.kind) != 26:
		result.wall_cursor = int(wall.cursor)
		response.wall = int(wall.index)
		if int(wall.index) >= 0:
			if int(result.kind) == 27 or int(result.kind) == 28:
				if swept:
					result.x = roundi(origin.x + displacement.x * float(wall.fraction))
					result.y = roundi(origin.y + displacement.y * float(wall.fraction))
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
	if swept:
		# The original bounce reverses this interval's displacement. Sweep that
		# reflected travel as well, without applying any target twice.
		if int(wall.index) >= 0 and int(result.kind) == 25:
			response.state = _sweep_hits(result, origin, displacement, players, active, hit, catalog, processed).state
		return response
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
	state: Dictionary, displacement: Vector2i, level: Resource, fractions: Array, scratch5: int, swept: bool = false
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
	var end := origin + displacement
	var minimum := Vector2i(mini(origin.x,end.x),mini(origin.y,end.y))
	var maximum := Vector2i(maxi(origin.x,end.x),maxi(origin.y,end.y))
	var candidates: Array = _native_wall_candidates(level, origin, end, fractions) if swept else []
	var candidate := 0
	var index := int(candidates[0]) if swept and not candidates.is_empty() else (walls.size() if swept else cursor)
	var closest := {"cursor": cursor, "index": -1, "fraction": 1.0}
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
		if swept:
			# Cheap broad phase keeps distant walls out of the intersection solver.
			if maximum.x < mini(a.x,b.x) or minimum.x > maxi(a.x,b.x) or maximum.y < mini(a.y,b.y) or minimum.y > maxi(a.y,b.y):
				candidate += 1
				index = int(candidates[candidate]) if candidate < candidates.size() else walls.size()
				continue
			var fraction := _wall_entry(origin, displacement, a, b)
			if fraction >= 0.0 and (int(closest.index) < 0 or fraction < float(closest.fraction)):
				closest = {"cursor": cursor, "index": index, "fraction": fraction}
		elif _crosses(origin, midpoint, displacement, a, b):
			return {"cursor": cursor, "index": index}
		if swept:
			candidate += 1
			index = int(candidates[candidate]) if candidate < candidates.size() else walls.size()
		else:
			index += 1
		if not swept and index < walls.size() and int(walls[index].start.y) > upper:
			break
	return closest if swept else {"cursor": cursor, "index": -1}


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


## Native 0.2 policy: analytic segment/AABB contacts in travel order. The source
## advance() path remains the default oracle; no sampled substeps are introduced.
static func _sweep_hits(
	state: Dictionary, origin: Vector2i, delta: Vector2i, players: Array,
	active: Array, hit: Callable, catalog: Resource, processed: Dictionary,
	limit: float = 1.0, wall: bool = false
) -> Dictionary:
	var response := {"state": state, "stop": false}
	# A source word wrap is not a physical path across the entire native map.
	var end := origin + delta
	if end.x < -32768 or end.x > 32767 or end.y < -32768 or end.y > 32767:
		return response
	var contacts: Array = []
	for player: Dictionary in players:
		if int(player.state) != 1 or int(player.id) == int(state.owner): continue
		var t := _box_entry(origin, delta, player, 64)
		if t >= 0.0 and (t < limit if wall else t <= limit):
			contacts.append({"id": int(player.id), "t": t, "order": contacts.size(), "player": true})
	if int(state.owner) < 0 or int(state.owner) > 180:
		for target: Dictionary in active:
			if int(target.get("kind", 0)) == 20: continue # Participants use player refs above.
			var t := _box_entry(origin, delta, target, int(target.radius))
			if t >= 0.0 and (t < limit if wall else t <= limit):
				contacts.append({"id": int(target.id), "t": t, "order": contacts.size(), "player": false})
	contacts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.t < b.t if a.t != b.t else a.order < b.order)
	for contact: Dictionary in contacts:
		if processed.has(contact.id): continue
		if not contact.player and not active.any(func(target: Dictionary) -> bool: return int(target.id) == int(contact.id)): continue
		processed[contact.id] = true
		if int(state.kind) in [27, 28]:
			var point := Vector2(origin) + Vector2(delta) * float(contact.t)
			state.x = roundi(point.x)
			state.y = roundi(point.y)
			return {"state": _explode(state, catalog), "stop": true}
		var outcome: Variant = hit.call(int(contact.id))
		var rejected := bool(outcome.get("rejected", false)) if outcome is Dictionary else bool(outcome)
		if not rejected and int(state.kind) != 26:
			return {"state": clear(state), "stop": true}
		if contact.player and int(state.kind) == 26:
			state.x = _word(end.x)
			state.y = _word(end.y)
			return {"state": state, "stop": true} # Source piercing rule: one player per interval.
	return response


static func _box_entry(origin: Vector2i, delta: Vector2i, target: Dictionary, radius: int) -> float:
	var low := 0.0
	var high := 1.0
	for axis: int in range(2):
		var offset := (int(target.x) if axis == 0 else int(target.y)) - origin[axis]
		if delta[axis] == 0:
			if absi(offset) > radius: return -1.0
		else:
			var a := float(offset - radius) / delta[axis]
			var b := float(offset + radius) / delta[axis]
			low = maxf(low, minf(a, b))
			high = minf(high, maxf(a, b))
			if low > high: return -1.0
	return low


static func _wall_entry(origin: Vector2i, delta: Vector2i, a: Vector2i, b: Vector2i) -> float:
	var end := origin + delta
	if maxi(origin.x, end.x) < mini(a.x, b.x) or mini(origin.x, end.x) > maxi(a.x, b.x) or maxi(origin.y, end.y) < mini(a.y, b.y) or mini(origin.y, end.y) > maxi(a.y, b.y): return -1.0
	var edge := b - a
	var relative := a - origin
	var denominator := _cross(delta, edge)
	if denominator != 0:
		var t := float(_cross(relative, edge)) / denominator
		var u := float(_cross(relative, delta)) / denominator
		return t if t >= 0.0 and t <= 1.0 and u >= 0.0 and u <= 1.0 else -1.0
	if _cross(relative, delta) != 0: return -1.0
	var axis := 0 if absi(delta.x) >= absi(delta.y) else 1
	if delta[axis] == 0: return 0.0 if origin == a or origin == b else -1.0
	var first := float(a[axis] - origin[axis]) / delta[axis]
	var last := float(b[axis] - origin[axis]) / delta[axis]
	var entry := maxf(0.0, minf(first, last))
	return entry if entry <= minf(1.0, maxf(first, last)) else -1.0


static func _cross(a: Vector2i, b: Vector2i) -> int:
	return a.x * b.y - a.y * b.x


## Original decoded walls are immutable for the lifetime of a level resource.
## Index resting segments by position; displaced groups remain explicit candidates so
## door fractions and retained arithmetic can never leave stale cached geometry.
static func prepare_native_geometry(level: Resource) -> void:
	if level.has_meta("native_projectile_wall_cells"): return
	var cells := {}
	var moving := {}
	for index: int in range(level.walls.size()):
		var wall: Dictionary = level.walls[index]
		if int(wall.motion_kind) != 0:
			var group := int(wall.get("motion_group",0))
			if not moving.has(group): moving[group] = []
			moving[group].append(index)
		for row: int in range(mini(wall.start.y,wall.finish.y) >> 8, (maxi(wall.start.y,wall.finish.y) >> 8) + 1):
			for column: int in range(mini(wall.start.x,wall.finish.x) >> 8, (maxi(wall.start.x,wall.finish.x) >> 8) + 1):
				var cell := Vector2i(column,row)
				if not cells.has(cell): cells[cell] = []
				cells[cell].append(index)
	level.set_meta("native_projectile_wall_cells", {"cells": cells, "moving": moving})


static func _native_wall_candidates(level: Resource, origin: Vector2i, end: Vector2i, fractions: Array = []) -> Array:
	prepare_native_geometry(level)
	var cache: Dictionary = level.get_meta("native_projectile_wall_cells")
	var seen := {}
	for group: int in cache.moving:
		if group >= fractions.size() or int(fractions[group]) != 0:
			for index: int in cache.moving[group]: seen[index] = true
	for row: int in range(mini(origin.y,end.y) >> 8, (maxi(origin.y,end.y) >> 8) + 1):
		for column: int in range(mini(origin.x,end.x) >> 8, (maxi(origin.x,end.x) >> 8) + 1):
			for index: int in cache.cells.get(Vector2i(column,row), []): seen[index] = true
	var result := seen.keys()
	result.sort() # Source wall order resolves equal-distance corner contacts.
	return result
