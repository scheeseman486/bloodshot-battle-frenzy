extends RefCounted
## Owner-local authorization. A broken store revokes all runtime privileges.
## Empty paths are isolated in-memory stores used by tests, never production.
const Bans = preload("res://scripts/network/player_bans.gd")
const Settings = preload("res://scripts/network/network_settings.gd")
const LIMIT := 64
const MAX_BYTES := 16384
signal changed
var path := ""
var entries: Dictionary = {}
var healthy := true
var last_error := ""
var revision := 0


func allows(key: String) -> bool:
	return healthy and entries.has(key)


func reload() -> bool:
	entries.clear()
	healthy = false
	last_error = "Cannot read admin allowlist; remote administration disabled"
	revision += 1
	if path.is_empty():
		healthy = true
	elif not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path):
		# Missing is an empty deny list, never a bootstrap grant.
		healthy = true
	elif not Settings.protect(path, false):
		healthy = false
	else:
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null and file.get_length() <= MAX_BYTES:
			var value: Variant = preload("res://scripts/network/bounded_json.gd").decode(
				file.get_buffer(file.get_length()), MAX_BYTES, 6, true
			)
			if _valid(value):
				entries = value.entries.duplicate(true)
				healthy = true
	if healthy:
		last_error = ""
	changed.emit()
	return healthy


static func _valid(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 2 or not value.has_all(["version", "entries"]):
		return false
	if not (value.version is int or value.version is float) or value.version != 1:
		return false
	if not value.entries is Dictionary or value.entries.size() > LIMIT:
		return false
	for key: Variant in value.entries:
		if not Bans.valid_key(key) or not Settings.valid_name(value.entries[key]):
			return false
	return true


func grant(key: String, name: String = "") -> bool:
	if not healthy:
		last_error = "Repair and reload the admin allowlist first"
		return false
	if not Bans.valid_key(key) or not Settings.valid_name(name):
		last_error = "Expected a complete public fingerprint and printable name"
		return false
	if not entries.has(key) and entries.size() >= LIMIT:
		last_error = "Admin allowlist is full"
		return false
	var candidate := entries.duplicate()
	candidate[key] = name
	return _replace(candidate)


func revoke(key: String) -> bool:
	if not Bans.valid_key(key) or not entries.has(key):
		last_error = "Fingerprint is not granted"
		return false
	var candidate := entries.duplicate()
	candidate.erase(key)
	# _replace disables ALL remote administration on failed persistence. Never
	# leave an apparently revoked key live, or promise durability after failure.
	return _replace(candidate)


func _replace(candidate: Dictionary) -> bool:
	last_error = ""
	if not path.is_empty():
		var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
		if file == null:
			return _write_failed()
		file.store_string(JSON.stringify({"version": 1, "entries": candidate}))
		file.flush()
		var error := file.get_error()
		file.close()
		if (
			error != OK
			or not Settings.protect(path + ".tmp", false)
			or DirAccess.rename_absolute(path + ".tmp", path) != OK
		):
			return _write_failed()
	entries = candidate
	revision += 1
	changed.emit()
	return true


func _write_failed() -> bool:
	healthy = false
	entries.clear()
	last_error = "Admin allowlist write failed; remote administration disabled until local recovery"
	revision += 1
	changed.emit()
	return false
