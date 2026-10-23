class_name CdForwardMotionPresentation
extends "res://scripts/presentation/cd_current_state_presentation.gd"
## Native forward segments, never a previous-tick buffer. Only movement already
## chosen by the simulation is forecast. AI decisions, damage and RNG stay live
## exclusively on the original world clock. Cache at that clock, sample at render Hz.
const Chase = preload("res://scripts/simulation/cd_enemy_chase.gd")
const Impulse = preload("res://scripts/simulation/cd_enemy_impulse.gd")
const Orbit = preload("res://scripts/simulation/cd_boss_orbit.gd")
const ProjectilePath = preload("res://scripts/presentation/cd_projectile_motion_path.gd")
const Collision = preload("res://scripts/simulation/cd_collision_world.gd")
const Doors = preload("res://scripts/simulation/cd_door_rules.gd")
const ActorAnimation = preload("res://scripts/simulation/cd_actor_animation.gd")
const Awareness = preload("res://scripts/simulation/cd_enemy_awareness.gd")
var _segments: Dictionary = {}
var _groups: Array = []
var _query_world := Collision.new()
var _cursor := 0
var _radius := 100
var _tables: Resource


func prepare(session: RefCounted, elapsed: int) -> void:
	var system: RefCounted = session.actor_system
	var groups: Array = session.groups
	_segments.clear()
	_groups = groups.duplicate(true)
	_query_world.level = session.level
	_tables = session.tables
	_query_world.fractions = groups.map(func(group: Dictionary) -> int: return int(group.fraction))
	for index: int in range(int(session.level.dynamic_start), system.actors.size()):
		var actor: Dictionary = system.actors[index]
		if int(actor.kind) in [24, 25, 26, 27, 28]:
			var path := ProjectilePath.build(
				actor, elapsed, session.level, _query_world.fractions, system.catalog
			)
			if not path.is_empty():
				_segments[index] = {
					"source": actor.duplicate(true),
					"path": path,
					"launch": system.projectile_launches.get(index, {}).duplicate(true)
				}
			continue
		var endpoint := _endpoint(system, actor, index, elapsed)
		if endpoint.is_empty():
			continue
		# Source endpoints are signed words. Do not interpolate across their wrap
		# as a map-spanning line. Normal chase/flight/orbit segments are small.
		if (
			absf(float(endpoint.x) - float(actor.x)) > 32768.0
			or absf(float(endpoint.y) - float(actor.y)) > 32768.0
		):
			continue
		if int(actor.kind) >= 1 and int(actor.kind) <= 19 and int(actor.kind) != 17:
			if not _clear_segment(actor, endpoint):
				continue
		if _near_moving_door(actor, endpoint, groups):
			continue
		_segments[index] = {
			"source": actor.duplicate(true),
			"end": endpoint,
			"launch": system.projectile_launches.get(index, {}).duplicate(true)
		}


func sample(
	motion: Dictionary, actors: Array, groups: Array, launches: Dictionary = {}, phase: float = 0.0
) -> Dictionary:
	var result := super.sample(motion, actors, groups, launches)
	# An input-clock restoration or external state change cancels, rather than
	# blending stale predictions through the new event. Door motors draw separately.
	if groups != _groups:
		return result
	var fraction := clampf(phase, 0.0, 1.0)
	if fraction == 0.0:
		return result
	for index: int in _segments:
		if index >= actors.size():
			continue
		var segment: Dictionary = _segments[index]
		if actors[index] != segment.source or launches.get(index, {}) != segment.launch:
			continue
		var shown: Dictionary = result.actors[index]
		if int(shown.kind) == 0:
			continue  # Ordered lower-slot births still wait for the real first dispatch.
		if segment.has("path"):
			ProjectilePath.sample(shown, segment.path, fraction)
			continue
		for field: String in ["x", "y", "height"]:
			if segment.end.has(field):
				shown[field] = lerpf(
					float(segment.source[field]), float(segment.end[field]), fraction
				)
	return result


func _endpoint(system: RefCounted, actor: Dictionary, index: int, elapsed: int) -> Dictionary:
	var kind := int(actor.kind)
	if int(actor.timer) != 0 and _word(int(actor.timer) - elapsed) <= 0:
		var animation := ActorAnimation.select(actor, int(actor.cursor) + 4, system.catalog)
		if animation.deleted:
			return {}
	if kind < 1 or kind > 19 or kind in [4, 15, 19] or int(actor.target) < 0:
		return {}
	var target: Dictionary = system.player_contexts.get(int(actor.target), {})
	if target.is_empty():
		return {}
	var grace := {}
	for handle: int in system.player_contexts:
		grace[handle] = int(system.player_contexts[handle].get("grace", 0))
	var awareness := Awareness.advance(actor, index, system.active, grace, elapsed)
	if not awareness.proceed:
		return {}
	if kind == 17:
		if system.remaining_bosses != 0:
			return {}
		# Actor dispatch uses the oscillator BEFORE its end-of-world advance.
		# The live oscillator is therefore already the next committed orbit sample.
		return Orbit.position(
			int(actor.phase),
			int(system.boss_clock.clock),
			int(system.boss_clock.radius),
			system.boss_centre,
			_tables
		)
	var params: Dictionary = system.catalog.parameters[int(actor.parameter)]
	_cursor = int(actor.wall_cursor)
	_radius = int(params.radius)
	if int(actor.impulse_x) != 0 or int(actor.impulse_y) != 0:
		return Impulse.advance(actor, elapsed, _query)
	# A new aim point may consume RNG or depend on future player input. Wait for
	# the actual decision; once it exists, reuse the exact integer movement rule.
	if int(actor.charge) == 0 or int(actor.cooldown) != 0:
		return {}
	var distance := _word(
		absi(_word(int(target.x) - int(actor.x))) + absi(_word(int(target.y) - int(actor.y)))
	)
	var chase := Chase.advance(
		actor, params, target, distance, elapsed, int(system.movement_seed), system.catalog, _query
	)
	return chase.state


func _query(target: Vector2i) -> Dictionary:
	var contact := _query_world.query(target, _cursor, _radius)
	_cursor = int(contact.cursor)
	return contact


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768


func _clear_segment(actor: Dictionary, endpoint: Dictionary) -> bool:
	var start := Vector2(float(actor.x), float(actor.y))
	var finish := Vector2(float(endpoint.x), float(endpoint.y))
	for phase: float in [0.25, 0.5, 0.75, 1.0]:
		var point := Vector2i(start.lerp(finish, phase))
		var contact := _query_world.query(point, int(actor.wall_cursor), _radius)
		if contact.blocked:
			return false
	return true


func _near_moving_door(actor: Dictionary, endpoint: Dictionary, groups: Array) -> bool:
	# Next closing-door obstruction depends on future player/actor positions.
	# Use current state near moving geometry instead of guessing through it.
	for wall: Dictionary in _query_world.level.walls:
		if int(wall.motion_kind) == 0:
			continue
		var group: Dictionary = groups[int(wall.motion_group)]
		if int(group.state) not in [Doors.State.OPENING, Doors.State.CLOSING]:
			continue
		var offset: Vector2i = wall.motion_delta * int(group.fraction) / 4096
		var a: Vector2i = wall.start + offset
		var b: Vector2i = wall.finish + offset
		var minimum := Vector2i(mini(a.x, b.x) - 356, mini(a.y, b.y) - 356)
		var maximum := Vector2i(maxi(a.x, b.x) + 356, maxi(a.y, b.y) + 356)
		for point: Dictionary in [actor, endpoint]:
			if (
				int(point.x) >= minimum.x
				and int(point.x) <= maximum.x
				and int(point.y) >= minimum.y
				and int(point.y) <= maximum.y
			):
				return true
	return false
