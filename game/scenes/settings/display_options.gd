extends VBoxContainer
## Reused in development navigation and the campaign pause panel.
signal widescreen_changed(enabled: bool)
const Settings = preload("res://scripts/presentation/cd_display_settings.gd")


func _ready() -> void:
	Settings.initialize_window(get_window())
	$Widescreen.set_pressed_no_signal(Settings.widescreen())
	$Fullscreen.set_pressed_no_signal(Settings.is_fullscreen(get_window()))
	$Widescreen.toggled.connect(_widescreen_changed)
	$Fullscreen.toggled.connect(_fullscreen_changed)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_F10:
		$Widescreen.button_pressed = not $Widescreen.button_pressed
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_F11:
		$Fullscreen.button_pressed = not Settings.is_fullscreen(get_window())
		get_viewport().set_input_as_handled()


func _widescreen_changed(enabled: bool) -> void:
	Settings.set_widescreen(enabled)
	widescreen_changed.emit(enabled)


func _fullscreen_changed(enabled: bool) -> void:
	Settings.set_fullscreen(get_window(), enabled)
