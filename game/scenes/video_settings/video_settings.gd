extends "res://scripts/frontend/cd_frontend_view.gd"
## Display-only draft/preview; no world, targeting or input settings are changed.
signal closed(saved: bool)
signal navigation
signal changed
const Display = preload("res://scripts/presentation/cd_display_settings.gd")
const SmallTheme = preload("res://scripts/frontend/native_small_theme.gd")
var save_handler := Callable()
var connected_devices: Callable = Input.get_connected_joypads
var _opened: Dictionary = {}
var _draft: Dictionary = {}
var _closed := false
var _saved := false
var _visual_time := 0.0
var _navigation: Dictionary = {}
var _pad := -1


func _ready() -> void:
	if not mount_frontend():
		return
	_opened = Display.values()
	if DisplayServer.get_name() != "headless":
		# A launch/window-manager override may differ from the saved preference.
		_opened.fullscreen = Display.is_fullscreen(get_window())
	_draft = _opened.duplicate()
	$Canvas.theme = SmallTheme.with_source_sliders(
		source.load_cd_small_font().native_font(), catalog.ui
	)
	$Canvas/Panel.add_theme_stylebox_override(
		"panel", SmallTheme.box(Color(0.015, 0.025, 0.045, 0.98), SmallTheme.ACCENT)
	)
	$Canvas/Fullscreen.pressed.connect(_toggle.bind("fullscreen"))
	$Canvas/Widescreen.pressed.connect(_toggle.bind("widescreen"))
	$Canvas/Fullscreen.set_meta("video_toggle", "fullscreen")
	$Canvas/Widescreen.set_meta("video_toggle", "widescreen")
	$Canvas/Fov/Slider.min_value = Display.MIN_FOV
	$Canvas/Fov/Slider.max_value = Display.MAX_FOV
	$Canvas/Fov/Slider.value_changed.connect(_fov_changed)
	$Canvas/Footer/Defaults.pressed.connect(_defaults)
	$Canvas/Footer/Cancel.pressed.connect(close.bind(false))
	$Canvas/Footer/Save.pressed.connect(save)
	for control: Control in [
		$Canvas/Fullscreen,
		$Canvas/Widescreen,
		$Canvas/Fov/Slider,
		$Canvas/Footer/Defaults,
		$Canvas/Footer/Cancel,
		$Canvas/Footer/Save
	]:
		control.focus_entered.connect(func(): navigation.emit())
	_sync()
	_layout()
	$Canvas/Fullscreen.grab_focus.call_deferred()


func _layout() -> void:
	super._layout()
	if has_node("Canvas"):
		$Canvas.position = frame.position
		$Canvas.scale = artwork_scale


func _process(delta: float) -> void:
	if _closed or catalog == null:
		return
	if _pad >= 0 and _pad not in connected_devices.call():
		_pad = -1
		_navigation.clear()
	_visual_time += delta
	update_background(_visual_time * 53203424.0 / 1070460.0)
	for action: String in _navigation.keys():
		_navigation[action] -= delta
		if float(_navigation[action]) <= 0:
			_navigation[action] = 0.08
			_ui_action(action, true)
			_ui_action(action, false)


func _toggle(key: String) -> void:
	_draft[key] = not _draft[key]
	navigation.emit()
	_preview()


func _fov_changed(value: float) -> void:
	_draft.fov = value
	_preview()


func _defaults() -> void:
	_draft = Display.DEFAULTS.duplicate()
	_preview()


func _preview() -> void:
	Display.preview(_draft, get_window())
	changed.emit()
	_sync()


func _sync() -> void:
	$Canvas/Fullscreen.text = "Fullscreen: " + ("On" if _draft.fullscreen else "Off")
	$Canvas/Widescreen.text = "Widescreen: " + ("On" if _draft.widescreen else "Off")
	$Canvas/Fov/Slider.set_value_no_signal(_draft.fov)
	$Canvas/Fov/Value.text = "%d degrees" % roundi(_draft.fov)
	$Canvas/Footer/Save.disabled = _draft == _opened
	$Canvas/Status.text = ""
	$Canvas/Status.hide()


func save() -> void:
	var result: int = (
		save_handler.call(_draft) if save_handler.is_valid() else Display.save(_draft, get_window())
	)
	if result == OK:
		close(true)
	else:
		$Canvas/Status.text = "Could not save video settings. Try again."
		$Canvas/Status.show()


func close(saved: bool = false) -> void:
	if _closed:
		return
	_closed = true
	_saved = saved
	_navigation.clear()
	if not saved:
		Display.preview(_opened, get_window())
		changed.emit()
	closed.emit.call_deferred(saved)
	queue_free.call_deferred()


func _exit_tree() -> void:
	if not _saved and not _opened.is_empty():
		Display.preview(_opened, get_window())
		changed.emit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_navigation.clear()


func _unhandled_input(_event: InputEvent) -> void:
	if not _closed:
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if _closed or not is_visible_in_tree():
		return
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_RIGHT
		and event.pressed
	):
		close(false)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		var devices: Array = connected_devices.call()
		if _pad not in devices:
			_pad = int(devices[0]) if not devices.is_empty() else -1
		if event.device != _pad:
			return
	if event.is_action_pressed("ui_cancel"):
		close(false)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey:
		if event.physical_keycode in [KEY_F10, KEY_F11, KEY_F12]:
			get_viewport().set_input_as_handled()
			return
		var mapped: String = (
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
		if mapped.is_empty() and event.physical_keycode in [KEY_LEFT, KEY_RIGHT]:
			var focus := get_viewport().gui_get_focus_owner()
			if focus != null and focus.has_meta("video_toggle"):
				mapped = "ui_left" if event.physical_keycode == KEY_LEFT else "ui_right"
		if not mapped.is_empty():
			_ui_action(mapped, event.pressed)
			get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton:
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
		if action in ["ui_up", "ui_down", "ui_left", "ui_right"]:
			_hold(action, event.pressed)
		elif not action.is_empty():
			_ui_action(action, event.pressed)
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadMotion:
		if event.axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y]:
			var negative := "ui_left" if event.axis == JOY_AXIS_LEFT_X else "ui_up"
			var positive := "ui_right" if event.axis == JOY_AXIS_LEFT_X else "ui_down"
			_hold(negative, event.axis_value < (-0.35 if _navigation.has(negative) else -0.5))
			_hold(positive, event.axis_value > (0.35 if _navigation.has(positive) else 0.5))
		get_viewport().set_input_as_handled()


func _hold(action: String, pressed: bool) -> void:
	if not pressed:
		_navigation.erase(action)
	elif not _navigation.has(action):
		_navigation[action] = 0.35
		_ui_action(action, true)
		_ui_action(action, false)


func _ui_action(action: String, pressed: bool) -> void:
	if action == "ui_cancel":
		if pressed:
			close(false)
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null and focus.has_meta("video_toggle") and action in ["ui_left", "ui_right"]:
		if pressed:
			_toggle(str(focus.get_meta("video_toggle")))
		return
	var translated := InputEventAction.new()
	translated.action = action
	translated.pressed = pressed
	get_viewport().push_input.call_deferred(translated)
