extends RefCounted
## Protocol-6 fixed control records. Same complete metadata and SHA checks as the
## generic value envelope; no simulation work or token/ownership decisions here.
const MAGIC := 0x314f4342
const HEADER := 13
const TRAILER := 32
const TYPES := ["begin", "ack", "finalized", "ping", "pong"]
const SIZES := [150, 117, 53, 53, 61]
const KINDS := ["key", "delta", "attach"]
const Wire = preload("res://scripts/network/value_codec.gd")
var last_error := ""


func encode(message: Dictionary) -> PackedByteArray:
	last_error = ""
	if not _valid(message):
		last_error = "Unsupported or invalid control record"
		return PackedByteArray()
	var type := TYPES.find(message.type)
	var bytes := PackedByteArray()
	bytes.resize(int(SIZES[type]) - TRAILER)
	bytes.encode_u32(0, MAGIC)
	bytes[4] = type
	bytes.encode_s64(5, message.token)
	match type:
		0:
			var meta: Dictionary = message.meta
			for index: int in range(4):
				bytes.encode_s64(
					HEADER + index * 8, meta[["transfer", "epoch", "revision", "base"][index]]
				)
			bytes.encode_u32(45, meta.size)
			bytes.encode_u32(49, meta.raw)
			_copy_hash(bytes, 53, meta.hash)
			_copy_hash(bytes, 85, meta.packed_hash)
			bytes[117] = KINDS.find(meta.kind)
		1:
			bytes.encode_s64(HEADER, message.transfer)
			_copy_hash(bytes, 21, message.hash)
			_copy_hash(bytes, 53, message.state_hash)
		2:
			bytes.encode_s64(HEADER, message.sequence)
		3:
			bytes.encode_s64(HEADER, message.echo)
		4:
			bytes.encode_s64(HEADER, message.echo)
			bytes.encode_double(21, message.tick)
	bytes.append_array(Wire._sha(bytes))
	return bytes


func decode(bytes: PackedByteArray) -> Dictionary:
	last_error = ""
	if bytes.size() < HEADER + TRAILER or bytes.decode_u32(0) != MAGIC or bytes[4] >= TYPES.size():
		return _bad()
	var type := int(bytes[4])
	if (
		bytes.size() != int(SIZES[type])
		or bytes.slice(-TRAILER) != Wire._sha(bytes.slice(0, bytes.size() - TRAILER))
	):
		return _bad()
	var message := {"type": TYPES[type], "token": bytes.decode_s64(5)}
	match type:
		0:
			if bytes[117] >= KINDS.size():
				return _bad()
			message.meta = {
				"transfer": bytes.decode_s64(13),
				"epoch": bytes.decode_s64(21),
				"revision": bytes.decode_s64(29),
				"base": bytes.decode_s64(37),
				"size": bytes.decode_u32(45),
				"raw": bytes.decode_u32(49),
				"hash": bytes.slice(53, 85).hex_encode(),
				"packed_hash": bytes.slice(85, 117).hex_encode(),
				"kind": KINDS[bytes[117]]
			}
		1:
			message.transfer = bytes.decode_s64(13)
			message.hash = bytes.slice(21, 53).hex_encode()
			message.state_hash = bytes.slice(53, 85).hex_encode()
		2:
			message.sequence = bytes.decode_s64(13)
		3:
			message.echo = bytes.decode_s64(13)
		4:
			message.echo = bytes.decode_s64(13)
			message.tick = bytes.decode_double(21)
	return message if _valid(message) else _bad()


func _bad() -> Dictionary:
	last_error = "Invalid control record size/checksum/fields"
	return {}


static func _copy_hash(bytes: PackedByteArray, offset: int, hash_value: String) -> void:
	var raw := hash_value.hex_decode()
	for index: int in range(32):
		bytes[offset + index] = raw[index]


static func _hash(value: Variant) -> bool:
	if not value is String or value.length() != 64:
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true


static func _valid(message: Dictionary) -> bool:
	if not message.get("type") in TYPES or not message.get("token") is int or message.token <= 0:
		return false
	match message.type:
		"begin":
			if message.size() != 3 or not message.get("meta") is Dictionary:
				return false
			return (
				preload("res://scripts/network/transfer.gd").new().begin(message.meta, 0)
				and _hash(message.meta.hash)
				and _hash(message.meta.packed_hash)
			)
		"ack":
			return (
				message.size() == 5
				and message.get("transfer") is int
				and message.transfer > 0
				and _hash(message.get("hash"))
				and _hash(message.get("state_hash"))
			)
		"finalized":
			return message.size() == 3 and message.get("sequence") is int and message.sequence >= 0
		"ping":
			return message.size() == 3 and message.get("echo") is int and message.echo >= 0
		"pong":
			return (
				message.size() == 4
				and message.get("echo") is int
				and message.echo >= 0
				and message.get("tick") is float
				and is_finite(message.tick)
				and message.tick >= 0
			)
	return false
