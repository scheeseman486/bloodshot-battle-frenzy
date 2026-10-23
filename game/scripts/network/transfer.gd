extends RefCounted
## One bounded atomic assembly. Compressed bytes never allocate beyond declared
## raw size. A newer monotonic transfer supersedes old unreliable fragments.
const Codec = preload("res://scripts/network/snapshot_codec.gd")
const PART := 900
const HEADER := 28
const MAX_PARTS := 1166
var metadata: Dictionary = {}
var parts: Dictionary = {}
var started := 0
var last_error := ""


func begin(value: Dictionary, now: int) -> bool:
	if (
		not value.has_all(
			["transfer", "epoch", "revision", "base", "size", "raw", "hash", "kind", "packed_hash"]
		)
		or value.size() != 9
	):
		return false
	for key: String in ["transfer", "epoch", "revision", "base", "size", "raw"]:
		if not value[key] is int or value[key] < 0:
			return false
	if (
		value.transfer < 1
		or value.size < 1
		or value.size > Codec.MAX_RAW
		or value.raw < 1
		or value.raw > Codec.MAX_RAW
		or not value.hash is String
		or value.hash.length() != 64
		or not value.packed_hash is String
		or value.packed_hash.length() != 64
		or not value.kind is String
		or value.kind not in ["key", "delta", "attach"]
	):
		return false
	metadata = value.duplicate(true)
	parts.clear()
	started = now
	return true


func fragment(bytes: PackedByteArray) -> bool:
	if (
		metadata.is_empty()
		or bytes.size() < HEADER
		or bytes.size() > HEADER + PART
		or bytes.decode_u32(0) != 0x314e5342
		or bytes.decode_s64(4) != metadata.transfer
		or bytes.decode_s64(12) != metadata.epoch
	):
		return false
	var index := bytes.decode_u32(20)
	var count := bytes.decode_u32(24)
	var expected := ceili(float(metadata.size) / PART)
	if (
		count != expected
		or count > MAX_PARTS
		or index >= count
		or bytes.size() - HEADER != mini(PART, int(metadata.size) - int(index) * PART)
	):
		return false
	var data := bytes.slice(HEADER)
	if parts.has(index) and parts[index] != data:
		last_error = "Conflicting duplicate chunk"
		return false
	parts[index] = data
	return true


func complete() -> bool:
	return not metadata.is_empty() and parts.size() == ceili(float(metadata.size) / PART)


func finish() -> Dictionary:
	last_error = ""
	if not complete():
		last_error = "Incomplete transfer"
		return {}
	var compressed := PackedByteArray()
	for i: int in range(parts.size()):
		compressed.append_array(parts[i])
	if (
		preload("res://scripts/network/value_codec.gd")._sha(compressed).hex_encode()
		!= metadata.packed_hash
	):
		last_error = "Compressed transfer checksum mismatch"
		return {}
	var raw := compressed.decompress(int(metadata.raw), FileAccess.COMPRESSION_ZSTD)
	if raw.size() != int(metadata.raw):
		last_error = "Uncompressed transfer size mismatch"
		return {}  # Size is checked before grammar decoding below.
	var codec := Codec.new()
	var result := codec.unpack(raw)
	if (
		not codec.last_error.is_empty()
		or preload("res://scripts/network/value_codec.gd")._sha(raw).hex_encode() != metadata.hash
	):
		last_error = "Transfer checksum or grammar mismatch"
		return {}
	return result


static func split(raw: PackedByteArray, transfer: int, epoch: int) -> Array:
	var result: Array = []
	var count := ceili(float(raw.size()) / PART)
	for index: int in range(count):
		var bytes := PackedByteArray()
		bytes.resize(HEADER)
		bytes.encode_u32(0, 0x314e5342)
		bytes.encode_s64(4, transfer)
		bytes.encode_s64(12, epoch)
		bytes.encode_u32(20, index)
		bytes.encode_u32(24, count)
		bytes.append_array(raw.slice(index * PART, (index + 1) * PART))
		result.append(bytes)
	return result
