class_name CdSaveSlots
extends RefCounted
## Five named slots around the shared checked/atomic checkpoint container.
## Metadata is read from the checkpoint itself; there is no parallel save schema.
const Store = preload("res://scripts/persistence/save_store.gd")
const Codec = preload("res://scripts/persistence/checkpoint_codec.gd")
const COUNT := 5
var directory := "user://saves"
var last_error := ""


func path(slot: int) -> String:
	return directory.path_join("slot-%d.bssave" % slot) if slot >= 1 and slot <= COUNT else ""


func describe(slot: int) -> Dictionary:
	var result := {"slot": slot, "exists": false, "valid": false, "level": 0, "error": "", "cheats_enabled":false}
	var location := path(slot)
	if location.is_empty():
		result.error = "Invalid save slot"
		return result
	result.exists = FileAccess.file_exists(location)
	if not result.exists:
		return result
	var bytes := read(slot)
	if bytes.is_empty():
		result.error = last_error
		return result
	var codec := Codec.new()
	var state := codec.decode(bytes)
	result.valid = state.has("manifest") and state.manifest.get("level") is int
	if result.valid:
		result.level = state.manifest.level
		var campaign: Dictionary=state.get("world",{}).get("campaign_state",{})
		var flag: Variant=campaign.get("cheats_ever_enabled",campaign.get("cheated",false))
		if not flag is bool:
			result.valid=false
			result.error="Invalid save cheat flag"
		else:result.cheats_enabled=flag
	else:
		result.error = "Save has no campaign metadata"
	return result


func write(slot: int, checkpoint: PackedByteArray) -> bool:
	last_error = ""
	var location := path(slot)
	if location.is_empty():
		last_error = "Invalid save slot"
		return false
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	if error != OK:
		last_error = "Cannot create save directory: " + error_string(error)
		return false
	var store := Store.new()
	var success := store.write(location, checkpoint)
	last_error = store.last_error
	return success


func read(slot: int) -> PackedByteArray:
	last_error = ""
	var location := path(slot)
	if location.is_empty():
		last_error = "Invalid save slot"
		return PackedByteArray()
	var store := Store.new()
	var bytes := store.read(location)
	last_error = store.last_error
	return bytes


func delete(slot: int) -> bool:
	last_error = ""
	var location := path(slot)
	if location.is_empty():
		last_error = "Invalid save slot"
		return false
	var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(location))
	if error != OK:
		last_error = "Cannot delete save: " + error_string(error)
	return error == OK
