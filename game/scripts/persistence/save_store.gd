class_name CdSaveStore
extends RefCounted
## Versioned disk container; same-directory temporary write plus atomic rename.
## Errors are returned to the caller. No UI bindings or source-media writes.
const Codec = preload("res://scripts/persistence/checkpoint_codec.gd")
const MAGIC := "BSSAVE01"
const HEADER := 48
var last_error := ""


func write(path: String, checkpoint: PackedByteArray) -> bool:
	last_error = ""
	var codec := Codec.new()
	var record := codec.decode(checkpoint)
	if not codec.last_error.is_empty():
		last_error = codec.last_error
		return false
	var schema := preload("res://scripts/persistence/checkpoint_schema.gd").new()
	if not schema.validate_envelope(record):
		last_error = schema.last_error
		return false
	var bytes := MAGIC.to_ascii_buffer()
	bytes.resize(HEADER)
	bytes.encode_u32(8, 1)
	bytes.encode_u32(12, checkpoint.size())
	var hash := Codec._sha(checkpoint)
	for index: int in range(32):
		bytes[16 + index] = hash[index]
	bytes.append_array(checkpoint)
	var absolute := ProjectSettings.globalize_path(path)
	var temporary := absolute + ".tmp-%x" % ResourceUID.create_id()
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		last_error = (
			"Cannot create save temporary file: " + error_string(FileAccess.get_open_error())
		)
		return false
	file.store_buffer(bytes)
	file.flush()
	var error := file.get_error()
	file.close()
	if error == OK:
		# Read back the full container before publishing; short writes and storage
		# errors cannot replace a previously valid save.
		if FileAccess.get_file_as_bytes(temporary) != bytes:
			error = ERR_FILE_CORRUPT
	if error == OK:
		error = DirAccess.rename_absolute(temporary, absolute)
	if error != OK:
		DirAccess.remove_absolute(temporary)
		last_error = "Cannot replace save atomically: " + error_string(error)
		return false
	return true


func read(path: String) -> PackedByteArray:
	last_error = ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		last_error = "Cannot open save: " + error_string(FileAccess.get_open_error())
		return PackedByteArray()
	if file.get_length() < HEADER or file.get_length() > HEADER + Codec.HEADER + Codec.MAX_BYTES:
		file.close()
		last_error = "Invalid save length"
		return PackedByteArray()
	var bytes := file.get_buffer(file.get_length())
	file.close()
	if (
		bytes.slice(0, 8).get_string_from_ascii() != MAGIC
		or bytes.decode_u32(8) != 1
		or bytes.decode_u32(12) != bytes.size() - HEADER
	):
		last_error = "Unsupported or truncated save container"
		return PackedByteArray()
	var checkpoint := bytes.slice(HEADER)
	if Codec._sha(checkpoint) != bytes.slice(16, HEADER):
		last_error = "Save checksum mismatch"
		return PackedByteArray()
	var codec := Codec.new()
	codec.decode(checkpoint)
	last_error = codec.last_error
	return checkpoint if last_error.is_empty() else PackedByteArray()
