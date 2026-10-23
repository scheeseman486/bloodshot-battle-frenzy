class_name CdCurrentStatePresentation
extends RefCounted
## Read current simulation state on every draw, including input-clock changes.
## No previous-world buffer, extrapolation or gameplay work belongs in this view.


func sample(
	motion: Dictionary, actors: Array, groups: Array, launches: Dictionary = {}
) -> Dictionary:
	var result := {
		"motion": motion.duplicate(true),
		"actors": actors.duplicate(true),
		"groups": groups.duplicate(true)
	}
	for index: int in range(result.actors.size()):
		var actor: Dictionary = result.actors[index]
		var launch: Dictionary = launches.get(index, {})
		if (
			int(actor.kind) in [24, 25, 26, 27, 28]
			and int(actor.kind) == int(launch.get("kind", -1))
			and not bool(launch.get("flight_started", true))
		):
			# Lower-slot allocation can precede the first ordered flight call.
			# Retain that source timing without drawing a frozen bullet birth.
			actor.kind = 0
	return result
