class_name CdCheatSettings
extends RefCounted
## Local access preference only. Permanent campaign history is a different owner.
static var save_path := "user://cheats.cfg"
static var _loaded := false
static var _enabled := false

static func reset_cache() -> void:
	_loaded = false
	_enabled = false

static func enabled() -> bool:
	if not _loaded:
		_loaded = true
		var file := ConfigFile.new()
		if file.load(save_path) == OK:
			var value: Variant = file.get_value("native", "cheats", false)
			_enabled = value if value is bool else false
	return _enabled

static func set_enabled(value: bool) -> bool:
	var file := ConfigFile.new()
	file.set_value("native", "cheats", value)
	var error := file.save(save_path + ".tmp")
	if error == OK:
		error = DirAccess.rename_absolute(save_path + ".tmp", save_path)
	if error != OK:
		DirAccess.remove_absolute(save_path + ".tmp")
		return false
	_enabled = value
	_loaded = true
	return true
