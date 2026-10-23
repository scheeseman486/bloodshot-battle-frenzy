extends RefCounted
## Protocol-6 input datagram: bounded fixed-width primitives with SHA-256.
## Four commands with all 48 individually rounded 16.16 samples fit in 901 B.
## This is only transport framing; admission and source aim rules stay unchanged.
const MAGIC := 0x31434e42
const COMPRESSED_MAGIC := 0x32434e42
const MAX_RAW := 901
const HEADER := 13
const TRAILER := 32
const MAX_COMMANDS := 4
const MAX_AIM := 48
const Wire = preload("res://scripts/network/value_codec.gd")
var last_error := ""


func encode(token: int, commands: Array, compress: bool = true) -> PackedByteArray:
	last_error = ""
	if token <= 0 or commands.size() > MAX_COMMANDS:
		last_error = "Invalid input token or command count"
		return PackedByteArray()
	for command: Variant in commands:
		if not _valid(command):
			last_error = "Invalid input command fields"
			return PackedByteArray()
	var bytes := PackedByteArray()
	bytes.resize(HEADER)
	bytes.encode_u32(0, MAGIC)
	bytes.encode_s64(4, token)
	bytes[12] = commands.size()
	for command: Dictionary in commands:
		var offset := bytes.size()
		bytes.resize(offset + 22 + command.aim.size() * 4)
		bytes.encode_s64(offset, command.sequence)
		bytes.encode_u32(offset + 8, command.controls.held)
		bytes[offset + 12] = int(command.controls.strafe) + 1
		bytes.encode_double(offset + 13, float(command.rate))
		bytes[offset + 21] = command.aim.size()
		for index: int in range(command.aim.size()):
			bytes.encode_s32(offset + 22 + index * 4, command.aim[index])
	bytes.append_array(Wire._sha(bytes))
	if compress and bytes.size() > 128 and compression_available():
		var result: Dictionary = ClassDB.instantiate("BloodshotPrimitiveCodec").compress_payload(
			bytes, 1
		)
		if result.error.is_empty() and result.bytes.size() + 38 < bytes.size():
			var packed := PackedByteArray()
			packed.resize(6)
			packed.encode_u32(0, COMPRESSED_MAGIC)
			packed.encode_u16(4, bytes.size())
			packed.append_array(result.bytes)
			packed.append_array(Wire._sha(packed))
			return packed
	return bytes


func decode(bytes: PackedByteArray) -> Dictionary:
	last_error = ""
	if bytes.size() >= 4 and bytes.decode_u32(0) == COMPRESSED_MAGIC:
		if bytes.size() < 39 or bytes.size() > 1000 or not compression_available():
			return _bad("Invalid or unsupported compressed input")
		var raw_size := bytes.decode_u16(4)
		if (
			raw_size < HEADER + TRAILER
			or raw_size > MAX_RAW
			or bytes.slice(-TRAILER) != Wire._sha(bytes.slice(0, bytes.size() - TRAILER))
		):
			return _bad("Compressed input bounds/checksum mismatch")
		var result: Dictionary = ClassDB.instantiate("BloodshotPrimitiveCodec").decompress_payload(
			bytes.slice(6, bytes.size() - TRAILER), raw_size
		)
		if (
			not result.error.is_empty()
			or result.bytes.size() != raw_size
			or result.bytes.decode_u32(0) != MAGIC
		):
			return _bad("Invalid compressed input payload")
		bytes = result.bytes
	if bytes.size() < HEADER + TRAILER or bytes.size() > 1000:
		return _bad("Invalid input packet size")
	if bytes.decode_u32(0) != MAGIC or bytes[12] > MAX_COMMANDS:
		return _bad("Invalid input header")
	var end := bytes.size() - TRAILER
	if bytes.slice(end) != Wire._sha(bytes.slice(0, end)):
		return _bad("Input checksum mismatch")
	var token := bytes.decode_s64(4)
	if token <= 0:
		return _bad("Invalid input token")
	var commands: Array = []
	var offset := HEADER
	for index: int in range(bytes[12]):
		if offset + 22 > end:
			return _bad("Truncated input command")
		var samples := int(bytes[offset + 21])
		if samples > MAX_AIM or offset + 22 + samples * 4 > end:
			return _bad("Invalid input sample count")
		var aim: Array = []
		for sample: int in range(samples):
			aim.append(bytes.decode_s32(offset + 22 + sample * 4))
		var command := {
			"sequence": bytes.decode_s64(offset),
			"controls":
			{"held": bytes.decode_u32(offset + 8), "strafe": int(bytes[offset + 12]) - 1},
			"rate": bytes.decode_double(offset + 13),
			"aim": aim
		}
		if not _valid(command):
			return _bad("Invalid input command fields")
		commands.append(command)
		offset += 22 + samples * 4
	if offset != end:
		return _bad("Trailing input bytes")
	return {"type": "commands", "token": token, "items": commands}


func _bad(message: String) -> Dictionary:
	last_error = message
	return {}


static func _valid(command: Variant) -> bool:
	if (
		not command is Dictionary
		or command.size() != 4
		or not command.has_all(["sequence", "controls", "rate", "aim"])
	):
		return false
	if not command.sequence is int or command.sequence <= 0:
		return false
	if (
		not command.controls is Dictionary
		or command.controls.size() != 2
		or not command.controls.has_all(["held", "strafe"])
	):
		return false
	if (
		not command.controls.held is int
		or command.controls.held < 0
		or command.controls.held > 0xffffffff
	):
		return false
	if (
		not command.controls.strafe is int
		or command.controls.strafe < -1
		or command.controls.strafe > 1
	):
		return false
	if (
		not (command.rate is float or command.rate is int)
		or not is_finite(float(command.rate))
		or absf(float(command.rate)) > 65536.0
	):
		return false
	if not command.aim is Array or command.aim.size() > MAX_AIM:
		return false
	for delta: Variant in command.aim:
		if not delta is int or delta <= -0x40000000 or delta >= 0x40000000:
			return false
	return true


static func compression_available() -> bool:
	return (
		ClassDB.class_exists("BloodshotPrimitiveCodec")
		and ClassDB.class_has_method("BloodshotPrimitiveCodec", "decompress_payload")
	)
