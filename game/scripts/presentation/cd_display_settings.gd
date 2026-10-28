class_name CdDisplaySettings
extends RefCounted
## Per-project user preferences and reversible window transitions. Presentation
## options never access the simulation or alter the original source media.
const DEFAULTS := {"widescreen": true, "fullscreen": true, "fov": 70.0}
const MIN_FOV := 70.0
const MAX_FOV := 105.0
static var config_path := "user://display.cfg"
static var _loaded := false
static var _wide := true
static var _fullscreen := true
static var _fov := 70.0
static var _window_id := 0
static var _windowed := {}


static func values() -> Dictionary:
	_load()
	return {"widescreen": _wide, "fullscreen": _fullscreen, "fov": _fov}


static func field_of_view() -> float:
	_load()
	return _fov


static func focal_scale() -> float:
	return tan(deg_to_rad(70.0) * 0.5) / tan(deg_to_rad(field_of_view()) * 0.5)


static func preview(candidate: Dictionary, window: Window) -> bool:
	if not valid(candidate):
		return false
	_load()
	_wide = candidate.widescreen
	_fov = float(candidate.fov)
	_transition_window(window, candidate.fullscreen)
	return true


static func save(candidate: Dictionary, window: Window) -> Error:
	if not valid(candidate):
		return ERR_INVALID_DATA
	# Write the complete draft before publishing saved values. A failed write
	# leaves both the persisted file and the open preview/draft intact.
	var config := ConfigFile.new()
	config.load(config_path)
	for key: String in DEFAULTS:
		config.set_value("display", key, candidate[key])
	var result := config.save(config_path + ".tmp")
	if result == OK:
		result = DirAccess.rename_absolute(config_path + ".tmp", config_path)
	if result != OK:
		DirAccess.remove_absolute(config_path + ".tmp")
		return result
	preview(candidate, window)
	return OK


static func valid(candidate: Dictionary) -> bool:
	return (
		candidate.size() == 3
		and candidate.has_all(DEFAULTS.keys())
		and candidate.widescreen is bool
		and candidate.fullscreen is bool
		and (candidate.fov is float or candidate.fov is int)
		and is_finite(float(candidate.fov))
		and float(candidate.fov) >= MIN_FOV
		and float(candidate.fov) <= MAX_FOV
	)


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
		_transition_window(window, true)


static func is_fullscreen(window: Window) -> bool:
	return window.mode in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]


static func set_fullscreen(window: Window, enabled: bool) -> void:
	_load()
	_transition_window(window, enabled)
	_save()


static func _transition_window(window: Window, enabled: bool) -> void:
	if enabled != is_fullscreen(window):
		if enabled:
			_windowed = {
				"mode": window.mode,
				"size": window.size,
				"position": window.position,
				"screen": window.current_screen
			}
			window.mode = Window.MODE_FULLSCREEN
		else:
			window.mode = int(_windowed.get("mode", Window.MODE_WINDOWED))
			if not _windowed.is_empty():
				window.current_screen = int(_windowed.screen)
				if window.mode == Window.MODE_WINDOWED:
					window.size = _windowed.size
					window.position = _windowed.position
	_fullscreen = enabled


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var config := ConfigFile.new()
	config.load(config_path)
	var candidate := DEFAULTS.duplicate()
	for key: String in DEFAULTS:
		var raw: Variant = config.get_value("display", key, DEFAULTS[key])
		if key == "fov":
			if (
				(raw is int or raw is float)
				and is_finite(float(raw))
				and raw >= MIN_FOV
				and raw <= MAX_FOV
			):
				candidate[key] = float(raw)
		elif raw is bool:
			candidate[key] = raw
	_wide = candidate.widescreen
	_fullscreen = candidate.fullscreen
	_fov = candidate.fov


static func _save() -> void:
	var config := ConfigFile.new()
	config.load(config_path)
	config.set_value("display", "widescreen", _wide)
	config.set_value("display", "fullscreen", _fullscreen)
	config.set_value("display", "fov", _fov)
	if config.save(config_path + ".tmp") == OK:
		DirAccess.rename_absolute(config_path + ".tmp", config_path)
