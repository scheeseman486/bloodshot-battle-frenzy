class_name CdEnemyAwareness
extends RefCounted
## Campaign awareness prefix, sub-CPU $02F0C4..$02F14E (or early return).
## Normal acquisition and recorded-demo activation share the source timer rules.


static func advance(
	state: Dictionary, actor: int, active: Array, grace: Variant, elapsed: int, demo: bool = false
) -> Dictionary:
	var result: Dictionary = state.duplicate(true)
	var ordered: Array = active.duplicate()
	var events: Array[Dictionary] = []
	var response := {"state": result, "active": ordered, "events": events, "proceed": false}
	var target := int(result.target)
	if target < 0:
		if demo:
			return response
		target = int(result.seen)
		if target < 0:
			return response
		result.seen = -1
		if int(grace[target]) != 0:
			return response
		result.target = target
		result.lost = 200
		ordered.append(actor)
		events.append({"kind": "enemy_activated", "actor": actor})
	var deactivate := false
	if int(result.seen) >= 0:
		# An active enemy checks its current target's grace, even if the
		# latest sighting names a different player. It does not retarget here.
		if int(grace[target]) != 0:
			deactivate = true
		else:
			result.seen = -1
			result.lost = maxi(200, int(result.lost))
	else:
		var previous := int(result.lost)
		result.lost = _word(previous - elapsed)
		# BGT after SUB.W uses the signed operands/overflow flag. The stored
		# timer can wrap positive while the original still takes the timeout.
		deactivate = previous <= elapsed
	if deactivate and not demo:
		var index := ordered.find(actor)
		assert(index >= 0, "Targeted enemies must belong to the active list")
		ordered.remove_at(index)
		result.target = -1
		events.append({"kind": "enemy_deactivated", "actor": actor})
	else:
		response.proceed = true
	return response


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
