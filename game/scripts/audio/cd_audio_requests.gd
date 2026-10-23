class_name CdAudioRequests
extends RefCounted
## Original sample requests at collision/health boundaries. This translates
## source events to native audio commands; it never changes simulation state.


static func impact(
	before: Dictionary,
	projectile: Dictionary,
	result: Dictionary,
	gate: int,
	catalog: Resource,
	area: bool = false
) -> Array:
	var kind := int(before.kind)
	var after: Dictionary = result.state
	var sounds: Array = []
	if area and before == after:
		return sounds
	if not area:
		if kind == 4 and gate != 0:
			return [0x10122]  # Core shield.
		if (
			kind in [5, 6]
			and int(before.cursor) >= 0x303a2
			and int(before.cursor) < 0x303c6
			and int(projectile.kind) != 26
		):
			return [0x14420]  # Deflection.
	if kind == 15 or (kind == 19 and not area):
		return [0x10d18] if not result.created.is_empty() else []
	var parameters: Dictionary = catalog.parameters[int(before.parameter)]
	_append(sounds, int(parameters.audio_hurt))
	if int(after.health) == 0 and int(before.health) > 0:
		_append(sounds, int(parameters.audio_death))
	return sounds


static func player(before: Dictionary, after: Dictionary) -> Array:
	if int(before.health) == int(after.health):
		return []
	var result: Array = []
	if int(before.state) != 2 and int(after.state) == 2:
		result.append(0x1cc3a)
		result.append(0x2547e)  # The original life-counter helper's cue.
	result.append(0x1c5d6)
	return result


static func _append(result: Array, source_id: int) -> void:
	if source_id >= 0:
		result.append(source_id)


## Source coordinates are captured before removal, transformation or slot reuse.
## Emitter references identify player feedback; audio never resolves mutable slots.
static func sample(source_id: int, origin: Dictionary, emitter: Dictionary = {}) -> Dictionary:
	var request := {"kind": "sample", "source_id": source_id}
	# Pure source-boundary regressions can supply partial player dictionaries.
	# Preserve their sample ordering without inventing a world origin.
	if origin.has_all(["x", "y"]):
		request.position = {"x": float(origin.x), "y": float(origin.y)}
	if not emitter.is_empty():
		request.emitter = emitter.duplicate()
	return request


## A group can contain several moving segments. Use their shared bounds center
## for both opening and closing, independent of which participant used the door.
static func door(source_id: int, level: Resource, group: int) -> Dictionary:
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	for wall: Dictionary in level.walls:
		if int(wall.motion_group) != group or int(wall.motion_kind) < 1:
			continue
		for point: Vector2i in [wall.start, wall.finish]:
			minimum = minimum.min(Vector2(point))
			maximum = maximum.max(Vector2(point))
	if not minimum.is_finite():
		return {"kind": "sample", "source_id": source_id}
	var center := (minimum + maximum) * 0.5
	return sample(source_id, {"x": center.x, "y": center.y})


static func valid_position(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 2 or not value.has_all(["x", "y"]):
		return false
	for axis: String in ["x", "y"]:
		if not (value[axis] is int or value[axis] is float) or not is_finite(float(value[axis])):
			return false
	return true
