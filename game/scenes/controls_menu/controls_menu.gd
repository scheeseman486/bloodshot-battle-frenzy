extends "res://scripts/frontend/cd_frontend_view.gd"
## Modal native controls scene. Original artwork/font pixels still load from CD.
signal closed(saved: bool)
const Model = preload("res://scripts/frontend/cd_controls_menu_model.gd")
const SmallTheme = preload("res://scripts/frontend/native_small_theme.gd")
var input_settings: RefCounted
var save_handler := Callable()
var model: RefCounted
var page := "keyboard"
var editing_action := ""
var gamepad_device := -1
# Device readers are injectable for deterministic connection/capture tests.
var connected_devices: Callable = Input.get_connected_joypads
var axis_value: Callable = Input.get_joy_axis
var _axes := {}
var _font: FontFile
var _closed := false
var _visual_time := 0.0
var _capture_cover: Control
var _add_button: Button
var _sliders := {}
var _value_labels := {}
var _diagonals_button: Button
var _navigation := {}
var _blocked_axes := {}
var _selected_actions := {"keyboard": "forward", "gamepad": "forward"}


func _ready() -> void:
	if not mount_frontend():
		return
	var font_catalog: RefCounted = source.load_cd_small_font()
	if font_catalog == null:
		show_error(source.last_error)
		return
	_font = font_catalog.native_font()
	$Canvas.theme = SmallTheme.make(_font)
	$Canvas/Panel.add_theme_stylebox_override(
		"panel", SmallTheme.box(Color(0.015, 0.025, 0.045, 0.98), SmallTheme.ACCENT)
	)
	model = Model.new(input_settings)
	input_settings = model.store
	$Canvas/Tabs/Keyboard.pressed.connect(show_page.bind("keyboard"))
	$Canvas/Tabs/Gamepad.pressed.connect(show_page.bind("gamepad"))
	$Canvas/Tabs/Settings.pressed.connect(show_page.bind("settings"))
	$Canvas/Footer/Defaults.pressed.connect(_defaults)
	$Canvas/Footer/Cancel.pressed.connect(close.bind(false))
	$Canvas/Footer/Save.pressed.connect(save)
	Input.joy_connection_changed.connect(_devices_changed)
	_refresh_devices()
	show_page("keyboard")
	_layout()


func _layout() -> void:
	super._layout()
	if has_node("Canvas"):
		$Canvas.position = frame.position
		$Canvas.scale = artwork_scale


func _process(delta: float) -> void:
	if model == null or _closed:
		return
	_repeat_navigation(delta)
	_visual_time += delta
	update_background(_visual_time * 53203424.0 / 1070460.0)


func show_page(value: String) -> void:
	if model == null:
		return
	if model.capturing:
		model.cancel_capture()
	page = value
	editing_action = ""
	model.status = (
		"Adjust a value. Save keeps your changes."
		if page == "settings"
		else "Select an action. Enter/A: edit.\nEsc/B: cancel menu."
	)
	_build_body()
	_sync()


func _clear_body() -> void:
	for node: Node in $Canvas/Body.get_children():
		$Canvas/Body.remove_child(node)
		node.queue_free()
	_capture_cover = null
	_add_button = null
	_sliders.clear()
	_value_labels.clear()
	_diagonals_button = null


func _build_body() -> void:
	_clear_body()
	for entry: Array in [
		["Keyboard", "keyboard"], ["Gamepad", "gamepad"], ["Settings", "settings"]
	]:
		var tab: Button = get_node("Canvas/Tabs/" + entry[0])
		tab.add_theme_color_override(
			"font_color", SmallTheme.ACCENT if page == entry[1] else SmallTheme.INK
		)
	if page == "settings":
		_build_settings()
	elif not editing_action.is_empty():
		_build_editor()
	else:
		_build_actions()


func _scroll(rect: Rect2) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.position = rect.position
	scroll.size = rect.size
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	$Canvas/Body.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	return list


func _button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 12
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(callback)
	return button


func _shorten(text: String, width: float) -> String:
	var result := text
	while (
		result.length() > 0
		and _font.get_string_size(result, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x > width
	):
		result = result.left(result.length() - 1)
	return result if result == text else result.left(maxi(0, result.length() - 3)) + "..."


func _build_actions() -> void:
	var list := _scroll(Rect2(0, 0, 240, 132))
	for index: int in range(Model.ACTIONS.size()):
		var action: String = Model.ACTIONS[index]
		var row := HBoxContainer.new()
		list.add_child(row)
		var label := Label.new()
		label.text = Model.LABELS[index]
		label.custom_minimum_size.x = 82
		row.add_child(label)
		var names: Array[String] = []
		for entry: Dictionary in model.bindings(action, page):
			names.append(entry.label)
		var text := "Unbound" if names.is_empty() else " / ".join(names)
		var button := _button(_shorten(text, 139), edit_action.bind(action))
		button.name = action
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.tooltip_text = text
		row.add_child(button)
		if action == _selected_actions[page]:
			_focus_later(button)


func edit_action(action: String) -> void:
	editing_action = action
	_selected_actions[page] = action
	model.status = "Select a binding to replace it,\nor its X button to remove it."
	_build_body()
	_sync()


func _build_editor() -> void:
	var heading := Label.new()
	heading.text = Model.LABELS[Model.ACTIONS.find(editing_action)]
	heading.add_theme_color_override("font_color", SmallTheme.ACCENT)
	$Canvas/Body.add_child(heading)
	var tip := Label.new()
	tip.position = Vector2(0, 15)
	tip.text = (
		"Keys + mouse bindings"
		if page == "keyboard"
		else ("Gamepad connected" if gamepad_device >= 0 else "No gamepad connected")
	)
	$Canvas/Body.add_child(tip)
	var list := _scroll(Rect2(0, 31, 240, 74))
	for entry: Dictionary in model.bindings(editing_action, page):
		var row := HBoxContainer.new()
		list.add_child(row)
		var bind := _button(_shorten(entry.label, 206), begin_capture.bind(int(entry.index)))
		bind.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(bind)
		var remove := _button("X", _remove.bind(int(entry.index)))
		remove.custom_minimum_size.x = 20
		remove.tooltip_text = "Remove this binding"
		row.add_child(remove)
	var actions := HBoxContainer.new()
	actions.position = Vector2(0, 116)
	actions.size = Vector2(240, 12)
	$Canvas/Body.add_child(actions)
	_add_button = _button("Add", begin_capture.bind(-1))
	_add_button.disabled = page == "gamepad" and gamepad_device < 0
	for button: Button in [
		_add_button, _button("Clear", _clear_group), _button("Back", _back_to_actions)
	]:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		actions.add_child(button)
	var focus: Control = _add_button if not _add_button.disabled else actions.get_child(2)
	_focus_later(focus)


func _remove(index: int) -> void:
	model.remove_binding(editing_action, index)
	_build_body()
	_sync()


func _clear_group() -> void:
	model.clear_family(editing_action, page)
	_build_body()
	_sync()


func _back_to_actions() -> void:
	editing_action = ""
	_build_body()
	_sync()


func begin_capture(index: int = -1) -> void:
	_navigation.clear()
	model.begin_capture(editing_action, page, index, gamepad_device, _axes)
	if model.capturing:
		_capture_cover = Panel.new()
		_capture_cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_capture_cover.add_theme_stylebox_override(
			"panel", SmallTheme.box(Color(0.025, 0.06, 0.12), SmallTheme.ACCENT)
		)
		$Canvas/Body.add_child(_capture_cover)
		var prompt := Label.new()
		prompt.position = Vector2(8, 38)
		prompt.size = Vector2(224, 60)
		prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		prompt.text = (
			"Press a key or mouse button.\n\nEscape cancels."
			if page == "keyboard"
			else "Release held sticks first.\nMove a stick or press a button.\n\nEscape cancels."
		)
		_capture_cover.add_child(prompt)
	_sync()


func _build_settings() -> void:
	var y := 0.0
	for entry: Array in [
		["Mouse sensitivity", "mouse_degrees_per_pixel", 0.01, 1.0, 0.01],
		["Gamepad turn speed", "gamepad_degrees_per_second", 1.0, 720.0, 1.0],
		["Stick deadzone", "deadzone", 0.05, 0.9, 0.01]
	]:
		var label := Label.new()
		label.position = Vector2(0, y)
		label.text = entry[0]
		$Canvas/Body.add_child(label)
		var value := Label.new()
		value.position = Vector2(137, y)
		value.size.x = 103
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		$Canvas/Body.add_child(value)
		_value_labels[entry[1]] = value
		var slider := HSlider.new()
		slider.position = Vector2(0, y + 14)
		slider.size = Vector2(240, 14)
		slider.min_value = entry[2]
		slider.max_value = entry[3]
		slider.step = entry[4]
		slider.value = model.draft[entry[1]]
		slider.focus_mode = Control.FOCUS_ALL
		slider.value_changed.connect(_numeric_changed.bind(entry[1]))
		$Canvas/Body.add_child(slider)
		_sliders[entry[1]] = slider
		y += 37
	_diagonals_button = _button("", _toggle_diagonals)
	_diagonals_button.position = Vector2(0, 116)
	_diagonals_button.size = Vector2(240, 12)
	_diagonals_button.tooltip_text = "Use the original CD Diagonals On/Off rules."
	$Canvas/Body.add_child(_diagonals_button)
	_value_text()
	_focus_later(_sliders.mouse_degrees_per_pixel)


func _toggle_diagonals() -> void:
	model.numeric("diagonals", 2 if int(model.draft.diagonals) == 1 else 1)
	_value_text()
	_sync()


func _numeric_changed(value: float, field: String) -> void:
	model.numeric(field, value)
	_value_text()
	_sync()


func _value_text() -> void:
	if _value_labels.is_empty():
		return
	_value_labels.mouse_degrees_per_pixel.text = "%.2f deg/px" % model.draft.mouse_degrees_per_pixel
	_value_labels.gamepad_degrees_per_second.text = (
		"%d deg/s" % model.draft.gamepad_degrees_per_second
	)
	_diagonals_button.text = "Diagonals: " + ("On" if int(model.draft.diagonals) == 1 else "Off")
	_value_labels.deadzone.text = "%d%%" % roundi(float(model.draft.deadzone) * 100)


func _defaults() -> void:
	model.reset_defaults()
	editing_action = ""
	_build_body()
	_sync()


func save() -> void:
	if model.save(save_handler) == OK:
		# Preserve the original option alongside its native controls-file value.
		Settings.apply({"diagonals": int(input_settings.values.diagonals)})
		close(true)
	else:
		_sync()


func close(saved: bool = false) -> void:
	if _closed:
		return
	_closed = true
	closed.emit.call_deferred(saved)
	queue_free.call_deferred()


func _sync() -> void:
	$Canvas/Status.text = model.status
	$Canvas/Footer/Save.disabled = not model.dirty()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_navigation.clear()
		if model != null and model.capturing:
			model.cancel_capture()
			_build_body()
			_sync()


func _devices_changed(_id: int, _connected: bool) -> void:
	var previous := gamepad_device
	_refresh_devices()
	if model != null and previous != gamepad_device and page in ["gamepad", "settings"]:
		_build_body()
		_sync()


func _refresh_devices() -> void:
	var devices: Array = connected_devices.call()
	if devices.has(gamepad_device):
		return
	devices.sort()
	gamepad_device = -1 if devices.is_empty() else int(devices[0])
	_axes.clear()
	_blocked_axes.clear()
	_navigation.clear()
	if model != null:
		model.device_changed()
	if gamepad_device >= 0:
		for axis: int in range(JOY_AXIS_MAX):
			_axes[axis] = axis_value.call(gamepad_device, axis)


func _input(event: InputEvent) -> void:
	if model == null or _closed:
		return
	if event is InputEventJoypadMotion and event.device == gamepad_device:
		_axes[event.axis] = event.axis_value
	if model.capturing:
		model.capture_event(event)
		if not model.capturing:
			# A captured stick must return to neutral before it can move UI focus.
			for axis: int in _axes:
				if absf(float(_axes[axis])) > 0.25:
					_blocked_axes[axis] = true
			_build_body()
		_sync()
		get_viewport().set_input_as_handled()
		return
	if (
		(event is InputEventJoypadButton or event is InputEventJoypadMotion)
		and event.device != gamepad_device
	):
		get_viewport().set_input_as_handled()
		return
	if (
		event is InputEventKey
		and event.pressed
		and event.physical_keycode in [KEY_F10, KEY_F11, KEY_F12]
	):
		get_viewport().set_input_as_handled()
		return
	if _navigation_input(event):
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_cancel"):
		if editing_action.is_empty():
			close(false)
		else:
			_back_to_actions()
		get_viewport().set_input_as_handled()


func _unhandled_input(_event: InputEvent) -> void:
	# Unbound keys/Start must not reach gameplay pause or the original cheat history.
	if not _closed:
		get_viewport().set_input_as_handled()


func _focus_later(control: Control) -> void:
	_focus_if_valid.call_deferred(weakref(control))


func _focus_if_valid(target: WeakRef) -> void:
	var control: Control = target.get_ref()
	if (
		control != null
		and control.is_inside_tree()
		and control.is_visible_in_tree()
		and not _closed
		and not model.capturing
	):
		control.grab_focus()


# Translate only within this modal viewport. Gameplay remaps and the original
# menus retain their own bindings; no process-wide InputMap changes are needed.
func _navigation_input(event: InputEvent) -> bool:
	if event is InputEventKey:
		var action: String = (
			{
				KEY_W: "ui_up",
				KEY_S: "ui_down",
				KEY_A: "ui_left",
				KEY_D: "ui_right",
				KEY_Z: "ui_accept",
				KEY_X: "ui_accept",
				KEY_C: "ui_accept"
			}
			. get(event.physical_keycode, "")
		)
		if action.is_empty():
			return false
		_ui_action(action, event.pressed)
		return true
	if event is InputEventJoypadButton:
		var action: String = (
			{
				JOY_BUTTON_DPAD_UP: "ui_up",
				JOY_BUTTON_DPAD_DOWN: "ui_down",
				JOY_BUTTON_DPAD_LEFT: "ui_left",
				JOY_BUTTON_DPAD_RIGHT: "ui_right",
				JOY_BUTTON_A: "ui_accept",
				JOY_BUTTON_X: "ui_accept",
				JOY_BUTTON_B: "ui_cancel"
			}
			. get(event.button_index, "")
		)
		if not action.is_empty():
			if action.begins_with("ui_") and action not in ["ui_accept", "ui_cancel"]:
				_hold_navigation(action, event.pressed)
			else:
				_ui_action(action, event.pressed)
		return true
	if event is InputEventJoypadMotion:
		if _blocked_axes.has(event.axis):
			if absf(event.axis_value) <= 0.25:
				_blocked_axes.erase(event.axis)
			return true
		if event.axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y]:
			var negative := "ui_left" if event.axis == JOY_AXIS_LEFT_X else "ui_up"
			var positive := "ui_right" if event.axis == JOY_AXIS_LEFT_X else "ui_down"
			# Hysteresis avoids focus jitter from an idle stick near the threshold.
			_hold_navigation(
				negative, event.axis_value < (-0.35 if _navigation.has(negative) else -0.5)
			)
			_hold_navigation(
				positive, event.axis_value > (0.35 if _navigation.has(positive) else 0.5)
			)
		return true
	return false


func _ui_action(action: String, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	# Finish raw input dispatch before forwarding it to Godot's normal GUI focus.
	get_viewport().push_input.call_deferred(event)


func _hold_navigation(action: String, pressed: bool) -> void:
	if not pressed:
		_navigation.erase(action)
	elif not _navigation.has(action):
		_navigation[action] = 0.35
		_ui_action(action, true)
		_ui_action(action, false)


func _repeat_navigation(delta: float) -> void:
	if model.capturing:
		return
	for action: String in _navigation.keys():
		_navigation[action] -= delta
		if float(_navigation[action]) <= 0.0:
			_navigation[action] = 0.08
			_ui_action(action, true)
			_ui_action(action, false)
