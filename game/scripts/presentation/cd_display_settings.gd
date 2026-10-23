class_name CdDisplaySettings
extends RefCounted
## Per-project user preferences and reversible window transitions. Presentation
## options never access the simulation or alter the original source media.
static var _loaded := false
static var _wide := false
static var _fullscreen := false
static var _window_id := 0
static var _windowed := {}


static func widescreen() -> bool:
	_load()
	return _wide


static func set_widescreen(value: bool) -> void:
	_load()
	if _wide == value:
		return
	_wide = value
	_save()


static func initialize_window(window: Window) -> void:
	_load()
	if _window_id == window.get_instance_id():
		return
	_window_id = window.get_instance_id()
	if _fullscreen:
		set_fullscreen(window, true)


static func is_fullscreen(window: Window) -> bool:
	return window.mode in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]


static func set_fullscreen(window: Window, enabled: bool) -> void:
	_load()
	if enabled != is_fullscreen(window):
		if enabled:
			_windowed = {"mode": window.mode, "size": window.size,
				"position": window.position, "screen": window.current_screen}
			window.mode = Window.MODE_FULLSCREEN
		else:
			window.mode = int(_windowed.get("mode", Window.MODE_WINDOWED))
			if not _windowed.is_empty():
				window.current_screen = int(_windowed.screen)
				if window.mode == Window.MODE_WINDOWED:
					window.size = _windowed.size
					window.position = _windowed.position
	_fullscreen = enabled
	_save()


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var config := ConfigFile.new()
	config.load("user://display.cfg")
	_wide = bool(config.get_value("display", "widescreen", false))
	_fullscreen = bool(config.get_value("display", "fullscreen", false))


static func _save() -> void:
	var config := ConfigFile.new()
	config.set_value("display", "widescreen", _wide)
	config.set_value("display", "fullscreen", _fullscreen)
	config.save("user://display.cfg")
