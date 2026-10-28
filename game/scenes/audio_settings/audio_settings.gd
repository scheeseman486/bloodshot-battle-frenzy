extends "res://scripts/frontend/cd_frontend_view.gd"
## Local mix preview. Providers publish only after an atomic Save; original
## runtime media/cache and gameplay audio services retain their own lifetimes.
signal closed(saved: bool)
signal navigation
const Audio = preload("res://scripts/audio/cd_audio_settings.gd")
const SmallTheme = preload("res://scripts/frontend/native_small_theme.gd")
var save_handler := Callable()
var connected_devices: Callable = Input.get_connected_joypads
var _opened: Dictionary = {}
var _volumes: Dictionary = {}
var _providers: Dictionary = {}
var _sliders: Dictionary = {}
var _values: Dictionary = {}
var _provider_buttons: Dictionary = {}
var _closed := false
var _saved := false
var _visual_time := 0.0
var _picker: FileDialog
var _waiting := false
var _pending_provider := ""
var _navigation: Dictionary = {}
var _pad := -1


func _ready() -> void:
	if not mount_frontend():
		return
	_opened = {"Music": Audio.volume("Music"), "Effects": Audio.volume("Effects")}
	_waiting = Audio.preparing()
	_volumes = _opened.duplicate()
	_providers = Audio._providers.duplicate()
	$Canvas.theme = SmallTheme.with_source_sliders(source.load_cd_small_font().native_font(), catalog.ui)
	$Canvas/Panel.add_theme_stylebox_override(
		"panel", SmallTheme.box(Color(0.015, 0.025, 0.045, 0.98), SmallTheme.ACCENT)
	)
	for bus: String in ["Music", "Effects"]:
		var slider: HSlider = get_node("Canvas/" + bus + "/Slider")
		_sliders[bus] = slider
		_values[bus] = get_node("Canvas/" + bus + "/Value")
		slider.set_value_no_signal(roundf(float(_volumes[bus]) * 100))
		slider.value_changed.connect(_volume_changed.bind(bus))
		slider.focus_entered.connect(func(): navigation.emit())
	for kind: String in ["music", "effects"]:
		var button: Button = get_node("Canvas/Providers/" + kind.capitalize())
		_provider_buttons[kind] = button
		button.set_meta("audio_provider", kind)
		button.pressed.connect(_cycle_provider.bind(kind))
	$Canvas/Locate.pressed.connect(_choose_cartridge.bind(""))
	$Canvas/Footer/Defaults.pressed.connect(_defaults)
	$Canvas/Footer/Cancel.pressed.connect(close.bind(false))
	$Canvas/Footer/Save.pressed.connect(save)
	for button: Button in [
		$Canvas/Providers/Music,
		$Canvas/Providers/Effects,
		$Canvas/Locate,
		$Canvas/Footer/Defaults,
		$Canvas/Footer/Cancel,
		$Canvas/Footer/Save
	]:
		button.focus_entered.connect(func(): navigation.emit())
	_sync()
	_layout()
	_sliders.Music.grab_focus.call_deferred()


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
	Audio.poll_cartridge()
	if _waiting and not Audio.preparing():
		_waiting = false
		if Audio.cartridge != null and Audio.cartridge_error.is_empty():
			if not _pending_provider.is_empty():
				_providers[_pending_provider] = "md"
			_status("")
		else:
			_status("Cartridge unavailable. Choose the original European ROM.")
		_pending_provider = ""
		_sync(false)
	for action: String in _navigation.keys():
		_navigation[action] -= delta
		if float(_navigation[action]) <= 0:
			_navigation[action] = 0.08
			_ui_action(action, true)
			_ui_action(action, false)


func _volume_changed(value: float, bus: String) -> void:
	_volumes[bus] = value / 100.0
	Audio.preview_volume(bus, float(_volumes[bus]))
	_sync()


func _cycle_provider(kind: String) -> void:
	if _waiting:
		return
	if _providers[kind] == "cd" and Audio.cartridge == null:
		_choose_cartridge(kind)
		return
	_providers[kind] = "md" if _providers[kind] == "cd" else "cd"
	navigation.emit()
	_sync()


func _defaults() -> void:
	for bus: String in _sliders:
		_sliders[bus].set_value_no_signal(100)
		_volume_changed(100, bus)
	_providers = {"music": "cd", "effects": "cd"}
	_sync()


func _sync(reset_status: bool = true) -> void:
	for bus: String in _values:
		_values[bus].text = "%d%%" % roundi(float(_volumes[bus]) * 100)
	for kind: String in _provider_buttons:
		_provider_buttons[kind].text = "Mega Drive" if _providers[kind] == "md" else "CD"
	$Canvas/Footer/Save.disabled = (
		_waiting or (_volumes == _opened and _providers == Audio._providers)
	)
	$Canvas/Locate.disabled = _waiting
	for button: Button in _provider_buttons.values():
		button.disabled = _waiting
	if reset_status:
		_status("")
		if _waiting:
			_status("Preparing cartridge audio...")
		elif "md" in _providers.values() and Audio.cartridge == null:
			_status("Cartridge unavailable. CD audio is active.")


func _status(text: String) -> void:
	$Canvas/Status.text = text
	$Canvas/Status.visible = not text.is_empty()


func _choose_cartridge(kind: String) -> void:
	if _waiting or is_instance_valid(_picker):
		return
	_pending_provider = kind
	_navigation.clear()
	_picker = FileDialog.new()
	_picker.title = "Select the original European Bloodshot Mega Drive ROM"
	_picker.access = FileDialog.ACCESS_FILESYSTEM
	_picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_picker.use_native_dialog = true
	_picker.filters = PackedStringArray(["*.md,*.bin; Mega Drive cartridge", "*; All files"])
	add_child(_picker)
	$Canvas.process_mode = Node.PROCESS_MODE_DISABLED
	_picker.file_selected.connect(
		func(path: String):
			_finish_picker()
			Audio.prepare_cartridge(path)
			_waiting = true
			_sync()
	)
	_picker.canceled.connect(
		func():
			_pending_provider = ""
			_finish_picker()
	)
	_picker.popup_centered_ratio(0.75)


func _finish_picker() -> void:
	_picker.queue_free()
	_picker = null
	$Canvas.process_mode = Node.PROCESS_MODE_INHERIT
	$Canvas/Locate.grab_focus.call_deferred()


func save() -> void:
	if _waiting:
		return
	var result: int = (
		save_handler.call(_volumes, _providers)
		if save_handler.is_valid()
		else Audio.save_mix(_volumes, _providers)
	)
	if result == OK:
		close(true)
	else:
		_status("Could not save audio settings. Try again.")


func close(saved: bool = false) -> void:
	if _closed:
		return
	_closed = true
	_saved = saved
	_navigation.clear()
	if not saved:
		_restore_preview()
	closed.emit.call_deferred(saved)
	queue_free.call_deferred()


func _restore_preview() -> void:
	for bus: String in _opened:
		Audio.preview_volume(bus, float(_opened[bus]))


func _exit_tree() -> void:
	if not _saved:
		_restore_preview()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_navigation.clear()


func _input(event: InputEvent) -> void:
	if _closed or not is_visible_in_tree() or is_instance_valid(_picker):
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
			if focus != null and focus.has_meta("audio_provider"):
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
	if focus != null and focus.has_meta("audio_provider") and action in ["ui_left", "ui_right"]:
		if pressed:
			_cycle_provider(str(focus.get_meta("audio_provider")))
		return
	var translated := InputEventAction.new()
	translated.action = action
	translated.pressed = pressed
	get_viewport().push_input.call_deferred(translated)


func _unhandled_input(_event: InputEvent) -> void:
	if not _closed:
		get_viewport().set_input_as_handled()
