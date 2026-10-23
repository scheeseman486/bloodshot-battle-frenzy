class_name CdStateInterpolation
extends RefCounted
## Historical delayed policy retained for before/after audits. The campaign
## uses CdCurrentStatePresentation. Visual snapshots only. Every interpolated value is a copy; collision, damage,
## AI, inventory, animation decisions and RNG always use integer simulation state.
var _previous: Dictionary = {}
var _current: Dictionary = {}


func reset(motion: Dictionary, actors: Array, groups: Array, launches: Dictionary = {}) -> void:
	_current = _capture(motion, actors, groups, launches)
	_previous = _current.duplicate(true)


func push(motion: Dictionary, actors: Array, groups: Array, launches: Dictionary = {}) -> void:
	if _current.is_empty():
		reset(motion, actors, groups, launches)
		return
	_previous = _current
	_current = _capture(motion, actors, groups, launches)


func sample(fraction: float) -> Dictionary:
	if _current.is_empty():
		return {}
	var weight := clampf(fraction, 0.0, 1.0)
	var result := _current.duplicate(true)
	_blend_position(result.motion, _previous.motion, weight)
	var angle_delta := wrapf(float(_current.motion.angle) - float(_previous.motion.angle), -8192.0, 8192.0)
	result.motion.angle = wrapf(float(_previous.motion.angle) + angle_delta * weight, 0.0, 16384.0)
	for index: int in range(result.actors.size()):
		if _flight_pending(index, result.actors[index]):
			# Allocation can occur after this source pool slot was visited. Keep
			# its frozen birth out of the view until a real flight segment exists.
			# The raw snapshots retain the projectile and its actual origin.
			result.actors[index].kind = 0
			continue
		var origin := _actor_origin(index, result.actors[index])
		if not origin.is_empty():
			_blend_position(result.actors[index], origin, weight)
			result.actors[index].height = lerpf(float(origin.height), float(result.actors[index].height), weight)
			# Enemy frames are discrete samples on the same past timeline as
			# their interpolated body. Do not show a future pose on a past body.
			var kind := int(result.actors[index].kind)
			if kind >= 1 and kind <= 19 and weight < 1.0 and origin.has("frame"):
				result.actors[index].frame = origin.frame
	for index: int in range(result.groups.size()):
		result.groups[index].fraction = lerpf(float(_previous.groups[index].fraction), float(result.groups[index].fraction), weight)
	return result


func _flight_pending(index: int, actor: Dictionary) -> bool:
	var launch: Dictionary = _current.get("launches", {}).get(index, {})
	return (
		int(actor.kind) in [24, 25, 26, 27, 28]
		and int(actor.kind) == int(launch.get("kind", -1))
		and not bool(launch.get("flight_started", true))
	)


func _actor_origin(index: int, actor: Dictionary) -> Dictionary:
	var launch: Dictionary = _current.get("launches", {}).get(index, {})
	var previous_launch: Dictionary = _previous.get("launches", {}).get(index, {})
	if not launch.is_empty() and int(launch.generation) != int(previous_launch.get("generation", -1)):
		# Source flight already advanced before this snapshot. Draw its first
		# interval from the recorded firing position, rather than holding it at
		# that first endpoint. Generation also distinguishes same-kind pool reuse.
		if int(actor.kind) in [24, 25, 26, 27, 28] and int(actor.kind) == int(launch.kind):
			return launch
		return {} # A shot that already hit/exploded must not regain a flight path.
	if index < _previous.actors.size() and int(actor.kind) == int(_previous.actors[index].kind):
		return _previous.actors[index]
	return {}


static func _capture(motion: Dictionary, actors: Array, groups: Array, launches: Dictionary) -> Dictionary:
	return {
		"motion": motion.duplicate(true), "actors": actors.duplicate(true),
		"groups": groups.duplicate(true), "launches": launches.duplicate(true)
	}


static func _blend_position(current: Dictionary, previous: Dictionary, weight: float) -> void:
	current.x = lerpf(float(previous.x), float(current.x), weight)
	current.y = lerpf(float(previous.y), float(current.y), weight)
