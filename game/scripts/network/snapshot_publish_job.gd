extends RefCounted
## Pure wire preparation on immutable public state. No World, nodes, media,
## input callbacks or engine resources cross this worker boundary.
const Codec = preload("res://scripts/network/snapshot_codec.gd")
const Wire = preload("res://scripts/network/value_codec.gd")
var baseline: Dictionary
var state: Dictionary
var transfer := 0
var base := 0
var kind := ""
var reliable := false
var result: Dictionary = {}
var last_error := ""
var elapsed_usec := 0
var queued_usec := 0


func configure(
	previous: Dictionary,
	current: Dictionary,
	identity: int,
	base_id: int,
	purpose: String,
	ordered: bool
) -> void:
	assert(current.is_read_only())
	assert(base_id == 0 or previous.is_read_only())
	baseline = previous
	state = current
	transfer = identity
	base = base_id
	kind = purpose
	reliable = ordered
	queued_usec = Time.get_ticks_usec()


func run() -> void:
	var started := Time.get_ticks_usec()
	var wire := Wire.new()
	var payload := state
	if base != 0:
		payload = (
			ClassDB.instantiate("BloodshotPrimitiveCodec").difference(baseline, state)
			if ClassDB.class_exists("BloodshotPrimitiveCodec")
			else Codec.new().difference(baseline, state)
		)
	var raw := wire.encode(payload)
	if raw.is_empty() or raw.size() > Codec.MAX_RAW:
		last_error = (
			wire.last_error if not wire.last_error.is_empty() else "Replicated state exceeds 1 MiB"
		)
		return
	var compressed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var state_bytes := wire.encode(state) if base != 0 else raw
	if state_bytes.is_empty() or state_bytes.size() > Codec.MAX_RAW:
		last_error = (
			wire.last_error if not wire.last_error.is_empty() else "Replicated state exceeds 1 MiB"
		)
		return
	result = {
		"meta":
		{
			"transfer": transfer,
			"epoch": state.epoch,
			"revision": state.revision,
			"base": base,
			"size": compressed.size(),
			"raw": raw.size(),
			"hash": Wire._sha(raw).hex_encode(),
			"packed_hash": Wire._sha(compressed).hex_encode(),
			"kind": kind
		},
		"compressed": compressed,
		"state_bytes": state_bytes
	}
	elapsed_usec = Time.get_ticks_usec() - started
