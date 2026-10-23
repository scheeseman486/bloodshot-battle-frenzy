@tool
class_name CdFmSynth
extends RefCounted
## Mightyweenie's unchanged MwChips/ymfm core, pulled by Godot's audio mixer.
## The CD campaign currently requests PCM/CD-DA only. The adapter supports FM
## writes without a render clock, extra presentation delay or chip PCM mixing.
const PAL_RATE := 53203424.0 / 7.0 / 144.0
var last_error := ""
var _stream: AudioStream


func configure() -> bool:
	stop()
	if not ClassDB.class_exists("BloodshotFmStream"):
		last_error = "Build the project audio extension to enable ymfm."
		return false
	last_error = ""
	return true


func generator() -> AudioStream:
	_stream = ClassDB.instantiate("BloodshotFmStream")
	return _stream


func write(port: int, register: int, value: int) -> void:
	if _stream != null and not bool(_stream.call("write", port, register, value)):
		push_error("FM register queue capacity exceeded")


func set_paused(_paused: bool) -> void:
	# AudioStreamPlayer pauses the native playback and therefore the chip clock.
	pass


func stop() -> void:
	_stream = null
