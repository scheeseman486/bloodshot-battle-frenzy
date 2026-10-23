extends RefCounted
## Host-private public-key deny list. Empty path is isolated in-memory testing.
const Settings = preload("res://scripts/network/network_settings.gd")
const LIMIT := 1024
const MAX_BYTES := 256 * 1024
var path := ""
var entries: Dictionary = {}
var loaded := false
var last_error := ""


static func valid_key(value: Variant) -> bool:
	if not value is String or value.length() != 64: return false
	for index: int in range(value.length()):
		if "0123456789abcdef".find(value[index]) < 0: return false
	return true


func load_list() -> bool:
	if loaded: return true
	last_error = ""
	if not path.is_empty() and DirAccess.dir_exists_absolute(path):
		last_error = "Cannot read player ban list"
		return false
	if path.is_empty():
		loaded = true
		return true
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null and FileAccess.get_open_error() == ERR_FILE_NOT_FOUND:
		loaded = true
		return true
	if file == null or file.get_length() > MAX_BYTES:
		last_error = "Cannot read player ban list"
		return false
	var bytes := file.get_buffer(file.get_length())
	for byte: int in bytes:
		if byte not in [9, 10, 13] and (byte < 32 or byte > 126):
			last_error = "Invalid player ban list encoding"
			return false
	var json := JSON.new()
	if json.parse(bytes.get_string_from_ascii()) != OK or not _valid(json.data):
		last_error = "Invalid player ban list; hosting blocked"
		return false
	entries = json.data.entries.duplicate(true)
	loaded = true
	return true


static func _valid(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 2 or not value.has_all(["version", "entries"]): return false
	if not (value.version is int or value.version is float) or value.version != 1 or not value.entries is Dictionary or value.entries.size() > LIMIT: return false
	for key: Variant in value.entries:
		var row: Variant = value.entries[key]
		if not valid_key(key) or not row is Dictionary or row.size() != 1 or not row.has("name") or not Settings.valid_name(row.name): return false
	return true


func contains(key: String) -> bool:
	return entries.has(key)


func rows() -> Array:
	var result := []
	for key: String in entries: result.append({"key": key, "name": entries[key].name})
	result.sort_custom(func(a, b):
		var order: int = a.name.naturalnocasecmp_to(b.name)
		return order < 0 if order != 0 else a.key < b.key)
	return result


func ban(key: String, name: String) -> bool:
	last_error = ""
	if not load_list(): return false
	if not valid_key(key) or not Settings.valid_name(name):
		last_error = "Invalid player identity"
		return false
	if not entries.has(key) and entries.size() >= LIMIT:
		last_error = "Player ban list is full"
		return false
	var candidate := entries.duplicate(true)
	candidate[key] = {"name": name}
	return _replace(candidate)


func unban(key: String) -> bool:
	last_error = ""
	if not load_list(): return false
	if not valid_key(key) or not entries.has(key):
		last_error = "Player is no longer in the ban list"
		return false
	var candidate := entries.duplicate(true)
	candidate.erase(key)
	return _replace(candidate)


func _replace(candidate: Dictionary) -> bool:
	if not path.is_empty():
		var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
		if file == null:
			last_error = "Could not save player ban list"
			return false
		file.store_string(JSON.stringify({"version": 1, "entries": candidate}))
		file.flush()
		var error := file.get_error()
		file.close()
		if error != OK or DirAccess.rename_absolute(path + ".tmp", path) != OK:
			last_error = "Could not save player ban list"
			return false
	entries = candidate
	return true
