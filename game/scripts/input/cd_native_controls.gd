class_name CdNativeControls
extends RefCounted
## Event state belongs to the human campaign only. The caller drains elapsed
## simulation before ingesting each event, so new inputs cannot rewrite old ticks.
const Settings = preload("res://scripts/input/cd_input_settings.gd")
const Selection = preload("res://scripts/input/native_weapon_selection.gd")
var device := -1
var _values: Dictionary = Settings.defaults()
var _keys := {}
var _mouse := {}
var _buttons := {}
var _axes := {}
var _axis_held := {}
var _weapon_serial := 0
var _weapon_token := 0


func configure(values: Dictionary) -> void:
	_values = values.duplicate(true)
	clear()


func devices_changed(devices: Array) -> void:
	if devices.has(device):
		return
	var ordered := devices.duplicate()
	ordered.sort()
	device = -1 if ordered.is_empty() else int(ordered[0])
	_buttons.clear()
	_axes.clear()
	_axis_held.clear()


## Returns only a rising pause edge. Held keys, OS echoes and axis jitter never
## retrigger it. Other actions remain held for the source input-clock sampler.
func ingest(event: InputEvent, allow_mouse: bool = true, allow_selection: bool = true) -> bool:
	var was_paused := strength("pause", true, true) > 0.0
	var before := _weapon_strengths(allow_mouse)
	if event is InputEventKey:
		if event.echo:
			return false
		_keys[event.physical_keycode] = event.pressed
	elif event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			# Wheels commonly have no release event. Each pressed notch is a new
			# ordered request, even when several arrive before a simulation tick.
			if event.pressed and allow_mouse and allow_selection:
				for action: String in ["next_weapon", "previous_weapon"]:
					if _values.bindings[action].has({"kind": "mouse", "code": event.button_index}):
						_request_weapon(
							Selection.NEXT if action == "next_weapon" else Selection.PREVIOUS
						)
			return false
		_mouse[event.button_index] = event.pressed
	elif event is InputEventJoypadButton and event.device == device and device >= 0:
		_buttons[event.button_index] = event.pressed
	elif event is InputEventJoypadMotion and event.device == device and device >= 0:
		_axes[event.axis] = event.axis_value if is_finite(event.axis_value) else 0.0
		for direction: int in [-1, 1]:
			var id := int(event.axis) * 2 + (1 if direction > 0 else 0)
			var threshold := (
				float(_values.deadzone) + (0.0 if bool(_axis_held.get(id, false)) else 0.05)
			)
			_axis_held[id] = float(_axes[event.axis]) * direction > threshold
	var after := _weapon_strengths(allow_mouse)
	for action: String in after:
		if allow_selection and after[action] and not before[action]:
			_request_weapon(_weapon_action(action))
	return not was_paused and strength("pause", true, true) > 0.0


func clear() -> void:
	_keys.clear()
	_mouse.clear()
	_buttons.clear()
	_axes.clear()
	_axis_held.clear()
	_weapon_token = 0


func strength(action: String, allow_mouse: bool = true, digital: bool = false) -> float:
	var result := 0.0
	for binding: Dictionary in _values.bindings[action]:
		var amount := 0.0
		var code := int(binding.code)
		match binding.kind:
			"key":
				amount = float(bool(_keys.get(code, false)))
			"mouse":
				amount = float(allow_mouse and bool(_mouse.get(code, false)))
			"joy_button":
				amount = float(bool(_buttons.get(code, false)))
			"joy_axis":
				var raw := float(_axes.get(code, 0.0)) * int(binding.sign)
				var deadzone := float(_values.deadzone)
				amount = clampf((raw - deadzone) / (1.0 - deadzone), 0.0, 1.0)
				if digital:
					var id := code * 2 + (1 if int(binding.sign) > 0 else 0)
					amount = float(bool(_axis_held.get(id, false)))
		result = maxf(result, amount)
	return result


func packet(allow_mouse: bool = true) -> Dictionary:
	var held := 0xffffffff
	for entry: Array in [
		["forward", 1],
		["backward", 2],
		["turn_left", 4],
		["turn_right", 8],
		["fire", 16],
		["use", 64]
	]:
		if strength(entry[0], allow_mouse, true) > 0.0:
			held &= ~int(entry[1])
	var strafe := (
		int(strength("strafe_right", allow_mouse, true) > 0.0)
		- int(strength("strafe_left", allow_mouse, true) > 0.0)
	)
	held = (held & 255) | ((~_weapon_token & 0xffffff) << 8)
	return {"held": held, "strafe": strafe}


func _weapon_strengths(allow_mouse: bool) -> Dictionary:
	var result := {}
	for action: String in _values.bindings:
		if action in ["next_weapon", "previous_weapon"] or action.begins_with("weapon_slot_"):
			result[action] = strength(action, allow_mouse, true) > 0.0
	return result


func _weapon_action(action: String) -> int:
	return (
		Selection.NEXT
		if action == "next_weapon"
		else (
			Selection.PREVIOUS
			if action == "previous_weapon"
			else int(action.trim_prefix("weapon_slot_"))
		)
	)


func _request_weapon(action: int) -> void:
	_weapon_serial = _weapon_serial % Selection.SERIAL_MAX + 1
	_weapon_token = (_weapon_serial << 4) | action


func aim_units_per_second(allow_mouse: bool = true) -> float:
	return (
		(strength("look_right", allow_mouse) - strength("look_left", allow_mouse))
		* float(_values.gamepad_degrees_per_second)
		* 16384.0
		/ 360.0
	)
