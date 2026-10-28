class_name CdControlsMenuModel
extends RefCounted
## Native controls-menu draft. Saving uses the existing validated input store.
const InputSettings = preload("res://scripts/input/cd_input_settings.gd")
const ACTIONS := [
	"forward",
	"backward",
	"strafe_left",
	"strafe_right",
	"turn_left",
	"turn_right",
	"fire",
	"next_weapon",
	"previous_weapon",
	"weapon_slot_1",
	"weapon_slot_2",
	"weapon_slot_3",
	"weapon_slot_4",
	"weapon_slot_5",
	"weapon_slot_6",
	"weapon_slot_7",
	"weapon_slot_8",
	"weapon_slot_9",
	"use",
	"pause",
	"look_left",
	"look_right",
	"scores"
]
const LABELS := [
	"Forward",
	"Backward",
	"Strafe left",
	"Strafe right",
	"Turn left",
	"Turn right",
	"Fire",
	"Next weapon",
	"Previous weapon",
	"Weapon slot 1",
	"Weapon slot 2",
	"Weapon slot 3",
	"Weapon slot 4",
	"Weapon slot 5",
	"Weapon slot 6",
	"Weapon slot 7",
	"Weapon slot 8",
	"Weapon slot 9",
	"Activate / use",
	"Pause",
	"Aim left",
	"Aim right",
	"Scores"
]
var store: RefCounted
var draft: Dictionary
var status := ""
var capturing := false
var capture_action := ""
var capture_family := "keyboard"
var capture_index := -1
var capture_device := -1
var _neutral := {}
var _validator: RefCounted


func _init(settings: RefCounted = null) -> void:
	store = (
		settings
		if settings != null
		else InputSettings.new(
			"user://controls.json",
			preload("res://scripts/frontend/cd_frontend_settings.gd").values().diagonals
		)
	)
	draft = store.values.duplicate(true)
	_validator = InputSettings.new()


var _force_save := false


func dirty() -> bool:
	return _force_save or draft != store.values


func numeric(field: String, value: float) -> bool:
	if (
		field
		not in ["mouse_degrees_per_pixel", "gamepad_degrees_per_second", "deadzone", "diagonals"]
	):
		return false
	_validator.values = draft.duplicate(true)
	if _validator.apply({field: value}, false) != OK:
		status = "Value is outside the supported range."
		return false
	draft = _validator.values.duplicate(true)
	status = "Changes are saved only when you choose Save."
	return true


func reset_defaults() -> void:
	cancel_capture()
	draft = InputSettings.defaults()
	_force_save = true
	status = "Defaults restored in this draft. Choose Save to keep them."


func bindings(action: String, family: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index: int in range(draft.bindings[action].size()):
		var binding: Dictionary = draft.bindings[action][index]
		if _family(binding) == family:
			result.append(
				{"index": index, "binding": binding.duplicate(), "label": binding_label(binding)}
			)
	return result


func remove_binding(action: String, index: int) -> void:
	if index >= 0 and index < draft.bindings[action].size():
		draft.bindings[action].remove_at(index)
		status = "Binding removed from this draft."


func clear_family(action: String, family: String) -> void:
	draft.bindings[action] = draft.bindings[action].filter(
		func(binding: Dictionary): return _family(binding) != family
	)
	status = "Bindings cleared for this device group."


func begin_capture(
	action: String, family: String, index: int = -1, device: int = -1, axes: Dictionary = {}
) -> void:
	if action not in ACTIONS or family not in ["keyboard", "gamepad"]:
		return
	if action.begins_with("weapon_slot_") and family != "keyboard":
		status = "Weapon slot shortcuts use keyboard keys only."
		return
	if family == "gamepad" and device < 0:
		status = "Connect a gamepad to add a binding."
		return
	capture_action = action
	capture_family = family
	capture_index = index
	capture_device = device
	capturing = true
	_neutral.clear()
	for axis: int in range(JOY_AXIS_MAX):
		_neutral[axis] = absf(float(axes.get(axis, 0.0))) <= 0.25
	status = "Press a new input. Escape cancels capture."


func cancel_capture() -> void:
	capturing = false
	status = "Capture cancelled."


func capture_event(event: InputEvent) -> bool:
	if not capturing:
		return false
	if (
		event is InputEventKey
		and event.pressed
		and not event.echo
		and event.physical_keycode == KEY_ESCAPE
	):
		cancel_capture()
		return true
	var binding := {}
	if capture_family == "keyboard":
		if event is InputEventKey and event.pressed and not event.echo:
			binding = {"kind": "key", "code": event.physical_keycode}
		elif event is InputEventMouseButton and event.pressed:
			binding = {"kind": "mouse", "code": event.button_index}
	elif event is InputEventJoypadButton and event.device == capture_device and event.pressed:
		binding = {"kind": "joy_button", "code": event.button_index}
	elif event is InputEventJoypadMotion and event.device == capture_device:
		if not is_finite(event.axis_value):
			return true
		if not bool(_neutral.get(event.axis, true)):
			if absf(event.axis_value) <= 0.25:
				_neutral[event.axis] = true
			return true
		if absf(event.axis_value) >= 0.65:
			binding = {
				"kind": "joy_axis", "code": event.axis, "sign": -1 if event.axis_value < 0 else 1
			}
	if binding.is_empty():
		return true
	if not InputSettings.valid_action_binding(capture_action, binding):
		status = "Input unavailable for this action. Escape cancels."
		return true
	_accept(binding)
	return true


func _accept(binding: Dictionary) -> void:
	capturing = false
	var entries: Array = draft.bindings[capture_action]
	if entries.has(binding):
		status = "Already assigned to this action."
		return
	if capture_index >= 0 and capture_index < entries.size():
		entries[capture_index] = binding
	elif entries.size() < 16:
		entries.append(binding)
	else:
		status = "Limit reached. Remove a binding first."
		return
	var shared: Array[String] = []
	for index: int in range(ACTIONS.size()):
		if ACTIONS[index] != capture_action and draft.bindings[ACTIONS[index]].has(binding):
			shared.append(LABELS[index])
	if shared.is_empty():
		status = "Binding added to this draft."
	else:
		status = "Also assigned to " + shared[0]
		if shared.size() > 1:
			status += " (+%d more)" % (shared.size() - 1)
		status += "."


func device_changed() -> void:
	if capturing and capture_family == "gamepad":
		cancel_capture()
		status = "Controller changed. Start binding again."


func save(handler: Callable = Callable()) -> Error:
	var result: Error = (
		handler.call(draft.duplicate(true)) if handler.is_valid() else store.apply(draft)
	)
	if result != OK:
		status = "Could not save controls. Your changes are still here."
		return result
	draft = store.values.duplicate(true)
	_force_save = false
	status = "Controls saved."
	return OK


static func _family(binding: Dictionary) -> String:
	return "gamepad" if String(binding.kind).begins_with("joy_") else "keyboard"


static func binding_label(binding: Dictionary) -> String:
	var code := int(binding.code)
	match binding.kind:
		"key":
			var label := OS.get_keycode_string(code)
			var ascii := ""
			for index: int in range(label.length()):
				var value := label.unicode_at(index)
				ascii += String.chr(value) if value >= 32 and value <= 126 else "?"
			return ascii
		"mouse":
			return (
				{
					MOUSE_BUTTON_LEFT: "Mouse left",
					MOUSE_BUTTON_RIGHT: "Mouse right",
					MOUSE_BUTTON_MIDDLE: "Mouse middle",
					MOUSE_BUTTON_WHEEL_UP: "Wheel up",
					MOUSE_BUTTON_WHEEL_DOWN: "Wheel down",
					MOUSE_BUTTON_XBUTTON1: "Mouse side 1",
					MOUSE_BUTTON_XBUTTON2: "Mouse side 2"
				}
				. get(code, "Mouse " + str(code))
			)
		"joy_button":
			return (
				{
					JOY_BUTTON_A: "Bottom face (A)",
					JOY_BUTTON_B: "Right face (B)",
					JOY_BUTTON_X: "Left face (X)",
					JOY_BUTTON_Y: "Top face (Y)",
					JOY_BUTTON_START: "Start",
					JOY_BUTTON_BACK: "Back / Select",
					JOY_BUTTON_GUIDE: "Guide",
					JOY_BUTTON_LEFT_STICK: "Left stick press",
					JOY_BUTTON_RIGHT_STICK: "Right stick press",
					JOY_BUTTON_LEFT_SHOULDER: "Left shoulder",
					JOY_BUTTON_RIGHT_SHOULDER: "Right shoulder",
					JOY_BUTTON_DPAD_UP: "D-pad up",
					JOY_BUTTON_DPAD_DOWN: "D-pad down",
					JOY_BUTTON_DPAD_LEFT: "D-pad left",
					JOY_BUTTON_DPAD_RIGHT: "D-pad right"
				}
				. get(code, "Button " + str(code))
			)
		"joy_axis":
			var axis: String = (
				{
					JOY_AXIS_LEFT_X: "Left stick X",
					JOY_AXIS_LEFT_Y: "Left stick Y",
					JOY_AXIS_RIGHT_X: "Right stick X",
					JOY_AXIS_RIGHT_Y: "Right stick Y",
					JOY_AXIS_TRIGGER_LEFT: "Left trigger",
					JOY_AXIS_TRIGGER_RIGHT: "Right trigger"
				}
				. get(code, "Axis " + str(code))
			)
			return axis + (" -" if int(binding.sign) < 0 else " +")
	return "Unbound"
