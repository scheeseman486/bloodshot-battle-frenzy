@tool
class_name CdAudioCatalog
extends RefCounted
## European CD sample descriptors and the $00CCCE upload decoder. Original bytes
## are translated once in memory; Godot owns playback, mixing and resampling.
const Data = preload("res://scripts/assets/cd_behaviour_tables.gd")
const SHELL_SHA256 := "e96ddb13dbe99087d1cd526bc15e022ac76c42b2efce14703fef9214ac8193a4"
# The original sets RF5C164 increment $0140 at 12.5 MHz / 384 chip samples/sec.
const SAMPLE_RATE := 12500000.0 / 384.0 * 320.0 / 2048.0
const MIX_RATE := 5086
const POINTER_TABLE := 0x2b094 - 0x8000
const LOOKUP := 0x2b12c - 0x8000
var samples: Dictionary = {}
var level_tracks := PackedInt32Array()
var last_error := ""
var _shell := PackedByteArray()
var _waves: Dictionary = {}
var _pcm: Dictionary = {}
var _streams: Dictionary = {}


func decode(shell: PackedByteArray) -> bool:
	samples.clear()
	level_tracks.clear()
	_waves.clear()
	_pcm.clear()
	_streams.clear()
	_shell.clear()
	last_error = ""
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(shell)
	if digest.finish().hex_encode() != SHELL_SHA256:
		last_error = "Audio requires the verified European CD SHELL data."
		return false
	for index: int in range(37):
		var source_id := Data._u32(shell, POINTER_TABLE + index * 4)
		var at := source_id - 0x8000
		var count := Data._s16(shell, at + 6)
		var interpolated := Data._s16(shell, at + 8) != 0
		@warning_ignore("integer_division")
		var encoded := count / 2 if interpolated else count
		if count <= 0 or (interpolated and count % 2 != 0) or at + 14 + encoded > POINTER_TABLE:
			last_error = "Unsupported original sample descriptor."
			samples.clear()
			return false
		samples[source_id] = {
			"index": index,
			"source_id": source_id,
			"length": count,
			"interpolated": interpolated,
			"encoded_length": encoded,
			"data_offset": at + 14,
			"rate": SAMPLE_RATE,
			"mix_rate": MIX_RATE,
			"pitch_scale": SAMPLE_RATE / MIX_RATE
		}
	for index: int in range(8):
		level_tracks.append(Data._s16(shell, 0x31130 - 0x8000 + index * 2))
	_shell = shell.duplicate()
	return true


func wave_bytes(source_id: int) -> PackedByteArray:
	if not samples.has(source_id):
		return PackedByteArray()
	if _waves.has(source_id):
		return (_waves[source_id] as PackedByteArray).duplicate()
	var metadata: Dictionary = samples[source_id]
	var result := PackedByteArray()
	var previous := 0
	for index: int in range(int(metadata.encoded_length)):
		var value := int(_shell[int(metadata.data_offset) + index])
		var signed := value - 256 if value >= 128 else value
		if metadata.interpolated:
			# The source's signed average is rounded down before the sign/magnitude
			# lookup. This is source data reconstruction, not hardware emulation.
			result.append(_shell[LOOKUP + (((previous + signed) >> 1) & 255)])
		result.append(_shell[LOOKUP + value])
		previous = signed
	_waves[source_id] = result
	return result.duplicate()


func pcm16(source_id: int) -> PackedByteArray:
	if _pcm.has(source_id):
		return (_pcm[source_id] as PackedByteArray).duplicate()
	var wave := wave_bytes(source_id)
	var result := PackedByteArray()
	result.resize(wave.size() * 2)
	for index: int in range(wave.size()):
		var value := int(wave[index])
		var signed := (value & 127) if (value & 128) != 0 else -(value & 127)
		# Original envelope $52 and centred $FF pan, per-channel signed 16-bit
		# mix level. Godot combines these mono streams on both output channels.
		var amplitude := (signed * 82 * 15) >> 5
		result.encode_s16(index * 2, amplitude)
	if samples.has(source_id):
		_pcm[source_id] = result
	return result.duplicate()


func stream(source_id: int) -> AudioStreamWAV:
	if not samples.has(source_id):
		return null
	if not _streams.has(source_id):
		var audio := AudioStreamWAV.new()
		audio.format = AudioStreamWAV.FORMAT_16_BITS
		audio.mix_rate = MIX_RATE
		audio.stereo = false
		audio.data = pcm16(source_id)
		_streams[source_id] = audio
	return _streams[source_id]
