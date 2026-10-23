class_name CdFrontendSettings
extends RefCounted
## Native persistence of original frontend choices. Pure gameplay sessions receive
## explicit values; reference tests never depend on local user preferences.
const AudioSettings = preload("res://scripts/audio/cd_audio_settings.gd")
const DEFAULTS := {"language": 69, "diagonals": 1, "sound": 1}
const ALLOWED := {"language": [69, 70, 68, 83], "diagonals": [1, 2], "sound": [1, 2, 3, 4]}
static var save_path := "user://frontend.cfg"
static var _loaded := false
static var _language_saved := false
static var _values := DEFAULTS.duplicate()


static func reset_cache() -> void:
	_loaded = false
	_language_saved = false
	_values = DEFAULTS.duplicate()


static func values() -> Dictionary:
	if not _loaded:
		_loaded = true
		_language_saved = false
		_values = DEFAULTS.duplicate()
		var file := ConfigFile.new()
		if file.load(save_path) == OK:
			for key: String in _values:
				var raw: Variant = file.get_value("original", key, 0)
				if raw is int and raw in ALLOWED[key]:
					_values[key] = raw
					if key == "language":
						_language_saved = true
	return _values.duplicate()


static func has_saved_language() -> bool:
	values()
	return _language_saved


static func apply(choices: Dictionary) -> Error:
	var candidate := values()
	for key: String in candidate:
		if choices.has(key):
			var value := int(choices[key])
			if value in ALLOWED[key]:
				candidate[key] = value
	var file := ConfigFile.new()
	for key: String in candidate:
		file.set_value("original", key, candidate[key])
	var result := file.save(save_path + ".tmp")
	if result == OK:
		result = DirAccess.rename_absolute(save_path + ".tmp", save_path)
	if result != OK:
		DirAccess.remove_absolute(save_path + ".tmp")
		return result
	_values = candidate
	_language_saved = true
	AudioSettings.set_source_mode(int(_values.sound))
	return OK
