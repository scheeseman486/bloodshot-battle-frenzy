@tool
extends EditorExportPlugin


## Imported textures do not retain PNG bytes. Only the explicitly authored
## overlay is embedded raw; original CD media and decoded artwork stay external.
func _get_name() -> String:
	return "BloodshotRuntimeData"


func _export_begin(_features: PackedStringArray, _debug: bool, _path: String, _flags: int) -> void:
	var manifest: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://resources/ui/cd_small_font_inventory.json")
	)
	var record: Dictionary = manifest.authored_asset
	var path := str(record.path)
	if not path.begins_with("res://resources/fonts/"):
		push_error("Runtime authored font must belong to the project font directory")
		return
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("Runtime authored font bytes are missing")
		return
	var hash_value := HashingContext.new()
	hash_value.start(HashingContext.HASH_SHA256)
	hash_value.update(bytes)
	if hash_value.finish().hex_encode() != record.sha256:
		push_error("Runtime authored font hash mismatch before export")
		return
	add_file(path, bytes, false)
