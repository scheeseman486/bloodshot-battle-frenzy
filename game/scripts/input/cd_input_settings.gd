class_name CdInputSettings
extends RefCounted
## Versioned native gameplay preferences. No InputMap or editor settings mutate.
## Apply validates the entire patch and writes atomically before publishing it.
const VERSION := 2
const MAX_BYTES := 65536
var values: Dictionary
var last_error := ""
var path: String


func _init(save_path: String = "user://controls.json", legacy_diagonals: int = 1) -> void:
	path = save_path
	values = defaults()
	# Old frontend.cfg remains the fallback until a native controls file stores it.
	values.diagonals = legacy_diagonals if legacy_diagonals in [1, 2] else 1
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_BYTES:
		last_error = "Cannot read controls or file exceeds 64 KiB. Defaults retained."
		return
	var decoder := JSON.new()
	if decoder.parse(file.get_as_text()) != OK:
		last_error = "Malformed controls JSON. Defaults retained."
		return
	var parsed: Variant = decoder.data
	if (
		not parsed is Dictionary
		or not _number(parsed.get("version"))
		or float(parsed.version) not in [1.0, float(VERSION)]
	):
		last_error = "Unsupported or corrupt controls file. Defaults retained."
		return
	if parsed.version == 1:
		parsed = _migrate(parsed)
	parsed.erase("version")
	apply(parsed, false)


static func defaults() -> Dictionary:
	var result := {
		"mouse_degrees_per_pixel": 0.12,
		"diagonals": 1,
		"gamepad_degrees_per_second": 180.0,
		"deadzone": 0.2,
		"bindings":
		{
			"forward":
			[_key(KEY_W), _key(KEY_UP), _axis(JOY_AXIS_LEFT_Y, -1), _joy(JOY_BUTTON_DPAD_UP)],
			"backward":
			[_key(KEY_S), _key(KEY_DOWN), _axis(JOY_AXIS_LEFT_Y, 1), _joy(JOY_BUTTON_DPAD_DOWN)],
			"strafe_left": [_key(KEY_A), _axis(JOY_AXIS_LEFT_X, -1)],
			"strafe_right": [_key(KEY_D), _axis(JOY_AXIS_LEFT_X, 1)],
			"turn_left": [_key(KEY_LEFT), _joy(JOY_BUTTON_DPAD_LEFT)],
			"turn_right": [_key(KEY_RIGHT), _joy(JOY_BUTTON_DPAD_RIGHT)],
			"fire":
			[
				_key(KEY_SPACE),
				{"kind": "mouse", "code": MOUSE_BUTTON_LEFT},
				_axis(JOY_AXIS_TRIGGER_RIGHT, 1)
			],
			"next_weapon":
			[_key(KEY_Q), _mouse(MOUSE_BUTTON_WHEEL_DOWN), _joy(JOY_BUTTON_RIGHT_SHOULDER)],
			"previous_weapon": [_mouse(MOUSE_BUTTON_WHEEL_UP), _joy(JOY_BUTTON_LEFT_SHOULDER)],
			"use": [_key(KEY_E), _joy(JOY_BUTTON_A)],
			"pause": [_key(KEY_ENTER), _joy(JOY_BUTTON_START)],
			"scores": [_key(KEY_TAB)],
			"look_left": [_axis(JOY_AXIS_RIGHT_X, -1)],
			"look_right": [_axis(JOY_AXIS_RIGHT_X, 1)]
		}
	}
	for slot: int in range(1, 10):
		result.bindings["weapon_slot_%d" % slot] = [_key(KEY_0 + slot)]
	return result


static func _migrate(old: Dictionary) -> Dictionary:
	var result := old.duplicate(true)
	if not result.get("bindings") is Dictionary:
		return result
	var bindings: Dictionary = result.bindings
	# JSON numbers are floats. Normalize validated integral binding codes before
	# comparing old defaults or checking conflicts with newly introduced inputs.
	for entries: Variant in bindings.values():
		if not entries is Array:
			continue
		for binding: Variant in entries:
			if _valid_binding(binding):
				binding.code = int(binding.code)
				if binding.kind == "joy_axis":
					binding.sign = int(binding.sign)
	var legacy: Array = [_key(KEY_Q), _joy(JOY_BUTTON_LEFT_SHOULDER), _joy(JOY_BUTTON_X)]
	if bindings.has("cycle_weapon"):
		var previous: Variant = bindings.cycle_weapon
		bindings.erase("cycle_weapon")
		bindings.next_weapon = defaults().bindings.next_weapon if previous == legacy else previous
	# Newly introduced bindings must not silently conflict with an old remap.
	var occupied: Array = []
	for entries: Variant in bindings.values():
		if entries is Array:
			occupied.append_array(entries)
	for action: String in defaults().bindings:
		if not bindings.has(action):
			bindings[action] = defaults().bindings[action].filter(
				func(binding): return binding not in occupied
			)
	return result


func apply(patch: Dictionary, persist: bool = true) -> Error:
	var candidate := values.duplicate(true)
	for field: Variant in patch:
		if not candidate.has(field):
			return _invalid("Unknown controls field: %s" % str(field))
		if field == "bindings":
			if not patch[field] is Dictionary:
				return _invalid("Bindings must be an action dictionary.")
			for action: Variant in patch[field]:
				var entries: Variant = patch[field][action]
				if (
					not candidate.bindings.has(action)
					or not entries is Array
					or entries.size() > 16
				):
					return _invalid("Unknown action or invalid binding list: %s" % str(action))
				for binding: Variant in entries:
					if not valid_action_binding(String(action), binding):
						return _invalid("Invalid binding for %s" % str(action))
				candidate.bindings[action] = entries.duplicate(true)
				for binding: Dictionary in candidate.bindings[action]:
					binding.code = int(binding.code)
					if binding.kind == "joy_axis":
						binding.sign = int(binding.sign)
		elif field == "diagonals":
			if not _number(patch[field]) or float(patch[field]) not in [1.0, 2.0]:
				return _invalid("Diagonals must use original scheme 1 or 2.")
			candidate.diagonals = int(patch[field])
		else:
			var limits: Array = {
				"mouse_degrees_per_pixel": [0.01, 1.0],
				"gamepad_degrees_per_second": [1.0, 720.0],
				"deadzone": [0.05, 0.9]
			}[field]
			if (
				not _number(patch[field])
				or float(patch[field]) < limits[0]
				or float(patch[field]) > limits[1]
			):
				return _invalid("Controls value outside allowed range: %s" % str(field))
			candidate[field] = float(patch[field])
	if persist:
		var saved := candidate.duplicate(true)
		saved.version = VERSION
		var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
		if file == null:
			last_error = "Cannot write controls: %s" % error_string(FileAccess.get_open_error())
			return FileAccess.get_open_error()
		file.store_string(JSON.stringify(saved, "\t") + "\n")
		file.flush()
		var result := file.get_error()
		file.close()
		if result == OK:
			result = DirAccess.rename_absolute(path + ".tmp", path)
		if result != OK:
			DirAccess.remove_absolute(path + ".tmp")
			last_error = "Cannot save controls: %s" % error_string(result)
			return result
	values = candidate
	last_error = ""
	return OK


func _invalid(message: String) -> Error:
	last_error = message
	return ERR_INVALID_DATA


static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _valid_binding(value: Variant) -> bool:
	if not value is Dictionary or not value.has_all(["kind", "code"]):
		return false
	if not _number(value.code) or float(value.code) != floor(float(value.code)):
		return false
	var code := int(value.code)
	if value.kind == "joy_axis":
		return (
			value.size() == 3
			and code >= 0
			and code < JOY_AXIS_MAX
			and _number(value.get("sign"))
			and absf(float(value.sign)) == 1.0
		)
	if value.size() != 2:
		return false
	match value.kind:
		"key":
			# These are existing native accessibility/display/development shortcuts.
			return (
				code > 0
				and code < KEY_UNKNOWN
				and code not in [KEY_ESCAPE, KEY_F10, KEY_F11, KEY_F12]
			)
		"mouse":
			# Action-specific checks restrict wheel pulses to weapon cycling.
			return (
				code
				in [
					MOUSE_BUTTON_LEFT,
					MOUSE_BUTTON_RIGHT,
					MOUSE_BUTTON_MIDDLE,
					MOUSE_BUTTON_WHEEL_UP,
					MOUSE_BUTTON_WHEEL_DOWN,
					MOUSE_BUTTON_XBUTTON1,
					MOUSE_BUTTON_XBUTTON2
				]
			)
		"joy_button":
			return code >= 0 and code < JOY_BUTTON_MAX
	return false


static func valid_action_binding(action: String, binding: Variant) -> bool:
	if not _valid_binding(binding):
		return false
	if action.begins_with("weapon_slot_"):
		return binding.kind == "key"
	if (
		binding.kind == "mouse"
		and int(binding.code) in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]
	):
		return action in ["next_weapon", "previous_weapon"]
	return true


static func _key(code: int) -> Dictionary:
	return {"kind": "key", "code": code}


static func _joy(code: int) -> Dictionary:
	return {"kind": "joy_button", "code": code}


static func _mouse(code: int) -> Dictionary:
	return {"kind": "mouse", "code": code}


static func _axis(code: int, sign_value: int) -> Dictionary:
	return {"kind": "joy_axis", "code": code, "sign": sign_value}
