class_name CdKeyboardControls
extends RefCounted
## Native keyboard adapter. Original controller input rules remain a separate
## reference path; keyboard strafing and activation are independent actions.
const OriginalInputs = preload("res://scripts/simulation/cd_input_rules.gd")


static func read(key_down: Callable, fire: bool) -> Dictionary:
	var held := 0xffffffff
	for binding: Array in [[KEY_W, KEY_UP, 1], [KEY_S, KEY_DOWN, 2]]:
		if key_down.call(binding[0]) or key_down.call(binding[1]):
			held &= ~int(binding[2])
	for binding: Array in [[KEY_LEFT, 4], [KEY_RIGHT, 8], [KEY_Q, 32], [KEY_E, 64]]:
		if key_down.call(binding[0]):
			held &= ~int(binding[1])
	if fire or key_down.call(KEY_SPACE):
		held &= ~16
	var strafe := int(bool(key_down.call(KEY_D))) - int(bool(key_down.call(KEY_A)))
	return {"held": held, "strafe": strafe}


static func sample(state: Dictionary, strafe: int, control_scheme: int = 1) -> Dictionary:
	# Reuse measured acceleration, limits, decay and the diagonal forward cap.
	# The CD exposes only turn OR strafe; sample the two native channels
	# separately so arrow turning, A/D and E can all coexist.
	var result := OriginalInputs.sample(_motor_input(state), control_scheme)
	strafe = clampi(strafe, -1, 1)
	if strafe != 0:
		var lateral := _motor_input(state)
		lateral.held = (int(state.held) | 4 | 8) & ~64
		lateral.held = int(lateral.held) & ~(4 if strafe < 0 else 8)
		lateral.strafe_mode = -1
		var strafing := OriginalInputs.sample(lateral, control_scheme)
		for field: String in ["forward", "forward_active", "strafe", "strafe_active"]:
			result[field] = strafing[field]
	result.held = state.held
	result.edge = state.edge
	result.strafe_mode = -1 if strafe != 0 else 0
	result.use_latch = state.use_latch
	result.use_duration = state.use_duration
	# Independent native E activates on press. Holding/releasing never rearms
	# a consumed request; original controller release rules stay in its oracle.
	if (int(state.edge) & 64) == 0:
		result.use_latch = -1
		result.use_duration = 0
	if (int(state.held) & 64) == 0:
		result.use_duration = OriginalInputs._word(int(result.use_duration) + 1)
	else:
		result.use_duration = 0
	return result


static func _motor_input(state: Dictionary) -> Dictionary:
	var result := state.duplicate()
	result.held = int(state.held) | 64
	result.edge = int(state.edge) | 64
	result.use_latch = 0
	result.use_duration = 0
	result.strafe_mode = 0
	return result
