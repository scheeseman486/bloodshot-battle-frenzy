class_name CdCheckpointCodec
extends RefCounted
## Portable, canonical primitive values. Never invokes Variant object decoding.
## Envelope: 8-byte magic, LE u16 schema/rules, u32 flags/length, SHA-256, payload.
const MAGIC := "BSCPv001"
const HEADER := 52
const MAX_BYTES := 2 * 1024 * 1024
const MAX_VALUES := 100000
const MAX_COLLECTION := 8192
const MAX_DEPTH := 24
var last_error := ""
var last_schema := 2
var _bytes := PackedByteArray()
var _offset := 0
var _values := 0


func encode(value: Dictionary) -> PackedByteArray:
	last_error = ""
	_bytes.clear()
	_values = 0
	if _use_native():
		var result: Dictionary = ClassDB.instantiate("BloodshotPrimitiveCodec").encode_payload(
			value, _native_visual_vectors()
		)
		_bytes = result.bytes
		_values = int(result.values)
		last_error = result.error
	else:
		_write(value, 0)
	if not last_error.is_empty() or _bytes.size() > MAX_BYTES:
		_fail("Checkpoint value exceeds encoding limits")
		return PackedByteArray()
	var result := MAGIC.to_ascii_buffer()
	result.resize(HEADER)
	result.encode_u16(8, 2)
	result.encode_u16(10, 1)
	result.encode_u32(12, 0)  # Version 1 deliberately supports uncompressed payloads only.
	result.encode_u32(16, _bytes.size())
	var digest := _sha(_bytes)
	for index: int in range(32):
		result[20 + index] = digest[index]
	result.append_array(_bytes)
	return result


func decode(bytes: PackedByteArray) -> Dictionary:
	last_error = ""
	_values = 0
	if bytes.size() < HEADER or bytes.size() > MAX_BYTES + HEADER:
		_fail("Invalid checkpoint length")
		return {}
	if (
		bytes.slice(0, 8).get_string_from_ascii() != MAGIC
		or bytes.decode_u16(8) not in [1, 2]
		or bytes.decode_u16(10) != 1
	):
		_fail("Unsupported checkpoint magic/schema/rules version")
		return {}
	if bytes.decode_u32(12) != 0 or bytes.decode_u32(16) != bytes.size() - HEADER:
		_fail("Unsupported compression/flags or inconsistent payload length")
		return {}
	last_schema = bytes.decode_u16(8)
	_bytes = bytes.slice(HEADER)
	if _sha(_bytes) != bytes.slice(20, HEADER):
		_fail("Checkpoint checksum mismatch")
		return {}
	_offset = 0
	var value: Variant
	if _use_native():
		var result: Dictionary = ClassDB.instantiate("BloodshotPrimitiveCodec").decode_payload(
			_bytes, _native_visual_vectors()
		)
		value = result.value
		_values = int(result.values)
		_offset = int(result.offset)
		last_error = result.error
	else:
		value = _read(0)
	if not last_error.is_empty():
		return {}
	if _offset != _bytes.size() or not value is Dictionary:
		_fail("Trailing data or invalid checkpoint root")
		return {}
	return value


## The portable implementation stays executable as an exact-format oracle and
## fallback. Native work is only this same bounded grammar, never game authority.
func _use_native() -> bool:
	return ClassDB.class_exists("BloodshotPrimitiveCodec")


func _native_visual_vectors() -> bool:
	return false


func canonical_hash(value: Dictionary) -> String:
	var encoded := encode(value)
	return _sha(encoded).hex_encode() if not encoded.is_empty() else ""


static func _sha(bytes: PackedByteArray) -> PackedByteArray:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish()


func _fail(message: String) -> void:
	if last_error.is_empty():
		last_error = message


func _integer(value: int, size: int) -> void:
	var start := _bytes.size()
	_bytes.resize(start + size)
	if size == 4:
		_bytes.encode_u32(start, value)
	else:
		_bytes.encode_s64(start, value)


func _write(value: Variant, depth: int) -> void:
	if not last_error.is_empty():
		return
	_values += 1
	if depth > MAX_DEPTH or _values > MAX_VALUES or _bytes.size() > MAX_BYTES:
		_fail("Checkpoint nesting/value/byte limit exceeded")
		return
	match typeof(value):
		TYPE_NIL:
			_bytes.append(0)
		TYPE_BOOL:
			_bytes.append(2 if value else 1)
		TYPE_INT:
			_bytes.append(3)
			_integer(value, 8)
		TYPE_FLOAT:
			if not is_finite(value):
				_fail("Non-finite checkpoint float")
				return
			_bytes.append(4)
			var start := _bytes.size()
			_bytes.resize(start + 8)
			_bytes.encode_double(start, value)
		TYPE_STRING, TYPE_STRING_NAME:
			var text: PackedByteArray = str(value).to_utf8_buffer()
			for byte: int in text:
				if byte < 32 or byte > 126:
					_fail("Checkpoint strings must contain printable ASCII")
					return
			if text.size() > 4096:
				_fail("Checkpoint string too long")
				return
			_bytes.append(5)
			_integer(text.size(), 4)
			_bytes.append_array(text)
		TYPE_VECTOR2I:
			_bytes.append(6)
			_integer(value.x, 8)
			_integer(value.y, 8)
		TYPE_VECTOR3I:
			_bytes.append(7)
			_integer(value.x, 8)
			_integer(value.y, 8)
			_integer(value.z, 8)
		TYPE_ARRAY, TYPE_DICTIONARY:
			if value.size() > MAX_COLLECTION:
				_fail("Checkpoint collection too large")
				return
			_bytes.append(8 if value is Array else 9)
			_integer(value.size(), 4)
			if value is Array:
				for child: Variant in value:
					_write(child, depth + 1)
			else:
				var normalized := {}
				for original: Variant in value:
					normalized[str(original) if original is StringName else original] = value[original]
				var keys: Array = normalized.keys()
				for key: Variant in keys:
					if not key is String and not key is int:
						_fail("Checkpoint map keys must be strings or integers")
						return
				keys.sort_custom(
					func(a, b): return typeof(a) < typeof(b) if typeof(a) != typeof(b) else a < b
				)
				for key: Variant in keys:
					_write(key, depth + 1)
					_write(normalized[key], depth + 1)
		_:
			_fail("Unsupported checkpoint value type: %s" % type_string(typeof(value)))


func _take(size: int) -> bool:
	if size < 0 or _offset > _bytes.size() - size:
		_fail("Truncated checkpoint value")
		return false
	_offset += size
	return true


func _read_integer(size: int) -> int:
	if not _take(size):
		return 0
	return _bytes.decode_u32(_offset - size) if size == 4 else _bytes.decode_s64(_offset - size)


func _read(depth: int) -> Variant:
	_values += 1
	if not last_error.is_empty():
		return null
	if depth > MAX_DEPTH or _values > MAX_VALUES or not _take(1):
		_fail("Checkpoint nesting/value limit exceeded")
		return null
	match _bytes[_offset - 1]:
		0:
			return null
		1:
			return false
		2:
			return true
		3:
			return _read_integer(8)
		4:
			if not _take(8):
				return null
			var value := _bytes.decode_double(_offset - 8)
			if not is_finite(value):
				_fail("Non-finite checkpoint float")
			return value
		5:
			var size := _read_integer(4)
			if size > 4096 or not _take(size):
				_fail("Invalid checkpoint string length")
				return null
			var raw := _bytes.slice(_offset - size, _offset)
			# ASCII metadata only in schema 1; reject invalid UTF-8 without engine logging.
			for byte: int in raw:
				if byte < 32 or byte > 126:
					_fail("Checkpoint strings must contain printable ASCII")
					return null
			return raw.get_string_from_ascii()
		6, 7:
			var count := 2 if _bytes[_offset - 1] == 6 else 3
			var components: Array = []
			for index: int in range(count):
				var component := _read_integer(8)
				if component < -2147483648 or component > 2147483647:
					_fail("Vector component overflow")
					return null
				components.append(component)
			return (
				Vector2i(components[0], components[1])
				if count == 2
				else Vector3i(components[0], components[1], components[2])
			)
		8, 9:
			var dictionary := _bytes[_offset - 1] == 9
			var size := _read_integer(4)
			if size > MAX_COLLECTION:
				_fail("Checkpoint collection too large")
				return null
			var result: Variant = {} if dictionary else []
			for index: int in range(size):
				var key: Variant = _read(depth + 1)
				if not last_error.is_empty():
					return null
				if dictionary:
					if (not key is String and not key is int) or result.has(key):
						_fail("Invalid or duplicate checkpoint field")
						return null
					var child: Variant = _read(depth + 1)
					if not last_error.is_empty():
						return null
					result[key] = child
				else:
					result.append(key)
			return result
		_:
			_fail("Unknown checkpoint value tag")
			return null
