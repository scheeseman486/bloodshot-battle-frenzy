class_name CdInputRules
extends RefCounted
## Controller sampling in the CD interrupt path, sub-CPU $0360C6..$0362E6.

static func sample(state: Dictionary, control_scheme: int, demo: bool = false) -> Dictionary:
	var result := state.duplicate()
	result.forward_active = 0
	result.turn_active = 0
	result.strafe_active = 0
	var controls := int(state.held)
	# Active-low controller bits. A is both the interaction button and a strafe
	# modifier. Preserve the CD's short-tap latch and release-time behaviour.
	if (int(state.edge) & 64) == 0:
		result.strafe_mode = -1
		result.use_latch = -1
		result.use_duration = 0
	if (controls & 64) == 0:
		result.use_duration = _word(int(result.use_duration) + 1)
	else:
		result.strafe_mode = 0
		if int(result.use_duration) != 0:
			# $036110 writes the duration into D0.w before later direction tests.
			# This surprising release side effect is present in the CD traces.
			controls = (controls & 0xffff0000) | (int(result.use_duration) & 65535)
			result.use_duration = 0
			if _word(controls) <= 30:
				result.use_latch = -1
	var lateral := false
	if (controls & 4) == 0:
		lateral = true
		if int(result.strafe_mode) == 0:
			result.turn_active = -1
			result.turn = maxi(_word(int(result.turn) - 5), -88)
		else:
			result.use_latch = 0
			result.strafe_active = -1
			result.strafe = maxi(_word(int(result.strafe) - 16), -56)
	elif (controls & 8) == 0:
		lateral = true
		if int(result.strafe_mode) == 0:
			result.turn_active = -1
			result.turn = mini(_word(int(result.turn) + 5), 88)
		else:
			result.use_latch = 0
			result.strafe_active = -1
			result.strafe = mini(_word(int(result.strafe) + 16), 56)
	if not (lateral and not demo and control_scheme == 2):
		var acceleration := 3 if lateral else 10
		var speed_limit := 28 if lateral else 56
		if (controls & 1) == 0:
			result.forward_active = -1
			result.forward = mini(_word(int(result.forward) + acceleration), speed_limit)
		elif (controls & 2) == 0:
			result.forward_active = -1
			result.forward = maxi(_word(int(result.forward) - acceleration), -speed_limit)
	for entry: Array in [["forward", "forward_active", 16], ["turn", "turn_active", 8], ["strafe", "strafe_active", 60]]:
		if int(result[entry[1]]) == 0:
			var value := int(result[entry[0]])
			result[entry[0]] = maxi(value - int(entry[2]), 0) if value > 0 else mini(value + int(entry[2]), 0)
	return result


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
