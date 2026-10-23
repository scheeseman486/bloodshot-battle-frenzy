extends "res://scripts/persistence/checkpoint_codec.gd"
## Same bounded primitive grammar as saves, with explicit finite visual vectors.
## Distinct envelope prevents a save or another protocol being accepted as a packet.
const WIRE_MAGIC := "BSNET001"


func encode(value: Dictionary) -> PackedByteArray:
	var result := super.encode(value)
	if not result.is_empty():
		for i: int in range(8):
			result[i] = WIRE_MAGIC.to_ascii_buffer()[i]
	return result


func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < HEADER or bytes.slice(0, 8).get_string_from_ascii() != WIRE_MAGIC:
		last_error = "Invalid network envelope"
		return {}
	var copy := bytes.duplicate()
	for i: int in range(8):
		copy[i] = MAGIC.to_ascii_buffer()[i]
	return super.decode(copy)


func _native_visual_vectors() -> bool:
	return true


func _write(value: Variant, depth: int) -> void:
	if value is Vector3:
		_values += 1
		if depth > MAX_DEPTH or _values > MAX_VALUES or not value.is_finite():
			_fail("Invalid visual vector")
			return
		_bytes.append(10)
		var start := _bytes.size()
		_bytes.resize(start + 24)
		for i: int in range(3):
			_bytes.encode_double(start + i * 8, value[i])
	else:
		super._write(value, depth)


func _read(depth: int) -> Variant:
	if _offset < _bytes.size() and _bytes[_offset] == 10:
		_values += 1
		if depth > MAX_DEPTH or _values > MAX_VALUES or not _take(25):
			_fail("Truncated visual vector")
			return null
		var result := Vector3.ZERO
		for i: int in range(3):
			result[i] = _bytes.decode_double(_offset - 24 + i * 8)
		if not result.is_finite():
			_fail("Invalid visual vector")
		return result
	return super._read(depth)
