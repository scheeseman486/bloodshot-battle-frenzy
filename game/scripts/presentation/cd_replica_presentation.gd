extends "res://scripts/presentation/cd_current_state_presentation.gd"
## Sample authority-supplied paths. This client never chooses AI endpoints.
const ProjectilePath = preload("res://scripts/presentation/cd_projectile_motion_path.gd")
var _segments: Dictionary = {}
var _groups: Array = []


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
