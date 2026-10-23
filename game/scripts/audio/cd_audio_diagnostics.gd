extends Node
## End-to-end native mixer checks. Run with --audio-driver Dummy: sound is
## captured inside Godot without changing desktop volume or playing on speakers.
const Source = preload("res://scripts/assets/original_asset_source.gd")
const Service = preload("res://scripts/audio/cd_audio_service.gd")
var _service: Node


func _ready() -> void:
	get_tree().create_timer(15.0).timeout.connect(_timeout)
	_run.call_deferred()


func _timeout() -> void:
	push_error("Audio mixer verification timed out")
	preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)


func _energy(capture: AudioEffectCapture) -> float:
	var result := 0.0
	for frame: Vector2 in capture.get_buffer(capture.get_frames_available()):
		result += frame.length_squared()
	return result


func _run() -> void:
	# Diagnostics are silent at the device; captures run on the upstream buses.
	AudioServer.set_bus_mute(0, true)
	var source := Source.new()
	if not source.mount(Source.configured_disc_path()):
		push_error(source.last_error)
		preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)
		return
	# Packaged diagnostics also prove the native data reader loads gameplay
	# resources without a development helper or extracted media.
	var level: Resource = source.load_cd_level()
	var actors: Resource = source.load_cd_actor_catalog(level)
	if level == null or actors == null or source.texture_from_cd_wall(level, 0) == null:
		push_error("Native standalone gameplay asset loading failed: " + source.last_error)
		preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)
		return
	_service = Service.new()
	get_tree().root.add_child(_service)
	if not _service.configure(source):
		push_error(_service.last_error)
		preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)
		return
	var effects := AudioEffectCapture.new()
	var music := AudioEffectCapture.new()
	var master := AudioEffectCapture.new()
	master.buffer_length = 1.0
	AudioServer.add_bus_effect(0, master)
	effects.buffer_length = 1.0
	music.buffer_length = 1.0
	for bus: String in ["Effects", "Music"]:
		var index := AudioServer.get_bus_index(bus)
		AudioServer.set_bus_volume_db(index, 0.0)
		AudioServer.set_bus_mute(index, false)
	AudioServer.add_bus_effect(AudioServer.get_bus_index("Effects"), effects)
	AudioServer.add_bus_effect(AudioServer.get_bus_index("Music"), music)
	_service.play_source(0xdc92)
	print(
		"Audio diagnostic: ",
		{
			"driver": AudioServer.get_driver_name(),
			"playing": _service.get_node("Effect1").playing,
			"data_bytes": _service.get_node("Effect1").stream.data.size(),
			"mix_rate": AudioServer.get_mix_rate()
		}
	)
	await _real_wait(150000)
	print(
		"Capture diagnostic: ",
		{
			"frames": effects.get_frames_available(),
			"position": _service.get_node("Effect1").get_playback_position(),
			"paused": _service.get_node("Effect1").stream_paused,
			"bus": _service.get_node("Effect1").bus,
			"captured": effects.get_pushed_frames(),
			"discards": effects.get_discarded_frames()
		}
	)
	var sample_energy := _energy(effects)
	var pcm_master := _energy(master)
	if sample_energy <= 0.01 or pcm_master <= 0.01:
		push_error("Original native PCM did not reach the Godot mixer")
		preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)
		return
	_service.stop_all()
	master.clear_buffer()
	_service.play_track(8, true)
	var player: AudioStreamPlayer = _service.get_node("CDMusic")
	player.seek(10.0)
	await _real_wait(150000)
	var cd_energy := _energy(music)
	var cd_master := _energy(master)
	var playback: AudioStreamPlayback = player.get_stream_playback()
	if cd_energy <= 0.01 or cd_master <= 0.01 or not str(playback.get_error()).is_empty():
		push_error("Original CHD stereo samples did not reach the Godot mixer")
		preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)
		return
	var buffered: int = playback.buffered_frames()
	var underruns: int = playback.underruns()
	await _real_wait(300000)
	var steady_underruns: int = int(playback.underruns()) - underruns
	if steady_underruns != 0:
		push_error("Steady CD streaming must not underrun")
		preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)
		return
	_service.set_paused(true)
	await _real_wait(200000)
	music.clear_buffer()
	var stopped_at := playback.get_playback_position()
	await _real_wait(60000)
	var pause_energy := _energy(music)
	if playback.get_playback_position() != stopped_at or pause_energy > 0.000001:
		print(
			"Pause diagnostic: ",
			{
				"before": stopped_at,
				"after": playback.get_playback_position(),
				"energy": pause_energy,
				"flag": player.stream_paused
			}
		)
		push_error("Native pause must freeze and silence streamed music")
		preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)
		return
	_service.stop_all()
	_service.set_paused(false)
	music.clear_buffer()
	master.clear_buffer()
	for offset: int in [0, 4, 8, 12]:
		_write(0x30 + offset, 1)
		_write(0x40 + offset, 0 if offset == 0 else 127)
		_write(0x50 + offset, 31)
		_write(0x60 + offset, 0)
		_write(0x70 + offset, 0)
		_write(0x80 + offset, 15)
	_write(0xb0, 7)
	_write(0xb4, 0xc0)
	_write(0xa4, 0x22)
	_write(0xa0, 0x22)
	_write(0x28, 0xf0)
	await _real_wait(150000)
	var fm_energy := _energy(music)
	var fm_master := _energy(master)
	if fm_energy <= 0.01 or fm_master <= 0.01:
		push_error("mightyweenie ymfm output did not reach the native Godot mixer")
		preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)
		return
	print(
		JSON.stringify(
			{
				"native_level_walls": level.walls.size(),
				"native_actor_count": actors.actors.size(),
				"runtime_sample_count": _service.audio_catalog.samples.size(),
				"native_pcm_energy": sample_energy,
				"chd_cdda_energy": cd_energy,
				"ymfm_energy": fm_energy,
				"master_bus_energy": [pcm_master, cd_master, fm_master],
				"cdda_buffered_frames": buffered,
				"cdda_underruns_during_seek": underruns,
				"steady_cdda_underruns": steady_underruns,
				"pause_froze_position": true,
				"fm_source_rate": preload("res://scripts/audio/cd_fm_synth.gd").PAL_RATE,
				"driver": AudioServer.get_driver_name()
			}
		)
	)
	_service.stop_all()
	_service.queue_free()
	_service = null
	playback = null
	await _real_wait(120000)
	preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 0)


func _write(register: int, value: int) -> void:
	_service.call(
		"_on_request", {"kind": "fm_write", "port": 0, "register": register, "value": value}
	)


func _real_wait(usec: int) -> void:
	var until := Time.get_ticks_usec() + usec
	while Time.get_ticks_usec() < until:
		await get_tree().process_frame
