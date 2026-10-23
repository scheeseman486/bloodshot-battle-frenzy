extends RefCounted
## Source-backed gameplay visibility, independent of native polygon rendering.
## Only explicit world-boundary capture advances the source traversal cache.
const Query = preload("res://scripts/simulation/cd_visibility_query.gd")
var session: WeakRef
var _previous: Dictionary = {}
var _cached_key: PackedByteArray
var _cached_view: Dictionary = {}


func reset(previous: Dictionary = {}) -> void:
	_previous = previous.duplicate(true)
	_cached_key.clear()
	_cached_view.clear()


func world_query() -> Dictionary:
	var state: RefCounted = session.get_ref()
	var player := {
		"x": state.motion.x,
		"y": state.motion.y,
		"view_angle": ((int(state.motion.angle) >> 6) + 64) & 255
	}
	var key := var_to_bytes(
		[
			player,
			state.groups.map(func(group: Dictionary) -> int: return int(group.fraction)),
			_previous
		]
	)
	if key != _cached_key:
		_cached_key = key
		_cached_view = Query.world(state.level, player, state.tables, state.groups, _previous)
	return _cached_view


func door_range() -> Array:
	if _previous.is_empty():
		return world_query().range
	return _previous.range


func sightings(commit: bool = false) -> Array:
	var state: RefCounted = session.get_ref()
	var result: Array = []
	if state.actor_system == null:
		return result
	var view := world_query()
	var player := {
		"x": state.motion.x,
		"y": state.motion.y,
		"view_angle": ((int(state.motion.angle) >> 6) + 64) & 255
	}
	for index: int in range(state.actor_system.actors.size()):
		var actor: Dictionary = state.actor_system.actors[index]
		if int(actor.kind) < 1 or int(actor.kind) > 19:
			continue
		if Query.actor(actor, player, state.tables, state.actor_system.catalog, view).visible:
			result.append(index)
	if commit:
		_previous = {"bounds": view.bounds.duplicate(), "range": view.range.duplicate()}
	return result
