@tool
class_name CdAudioService
extends Node
## Native playback facade. Original data is decoded/cached in memory; the native
## CHD stream reads music on its own worker. No audio result drives gameplay.
const AudioRequests = preload("res://scripts/audio/cd_audio_requests.gd")
const Settings = preload("res://scripts/audio/cd_audio_settings.gd")
const Lifecycle = preload("res://scripts/runtime/cd_application_lifecycle.gd")
const Fm = preload("res://scripts/audio/cd_fm_synth.gd")
signal event_requested(event_id: StringName, world_position: Vector3)
signal source_requested(request: Dictionary)
@export_range(-60.0, 6.0) var effects_volume_db := 0.0
@export_range(-60.0, 6.0) var music_volume_db := 0.0
var last_error := ""
var audio_catalog: RefCounted
var music_track := 0
var level_number := 0
var music_provider := "cd"
var cartridge_effects := 0
var _local_options: Dictionary = {}
var _local_cartridge: RefCounted
var _provider_revision := -1
var _level_music := false
var _frontend_music := false
var _escape_music := false
var _countdown_remaining := -1
var _countdown_epoch := -1
var _gameplay_context := false
var _retiring_music: Array[AudioStreamPlayer] = []
# Logical streaming configuration used to reattach checkpoints, never a buffer.
var music_loop := true
var accepted_samples := 0
var dropped_samples := 0
var _source: RefCounted
var _session: WeakRef
# Each logical slot has a centered and a spatial player, but admits only one.
# Retaining ordinary players keeps frontend previews independent of any camera.
var _effects: Array[AudioStreamPlayer] = []
var _spatial_effects: Array[AudioStreamPlayer3D] = []
# Native 3D play() starts on a later physics frame, so reserve paused requests.
var _pending_spatial: Dictionary = {}
var _listener: AudioListener3D
var _view_camera: WeakRef
var _view_origin := Vector2i.ZERO
const UNITS_PER_METRE := 256.0
const EFFECT_VOICES := 64
const NEAR_METRES := 6.0
const RANGE_METRES := 72.0
var _music: AudioStreamPlayer
var _fm_player: AudioStreamPlayer
var _fm := Fm.new()
var _paused := false
var _cue_paused := false
var _fm_started := false
var _retired_playbacks: Array[WeakRef] = []


func _enter_tree() -> void:
	add_to_group("bloodshot_audio_services")


func _track_player(player: Node) -> void:
	if is_inside_tree() and player.has_stream_playback():
		Lifecycle.track_playback(get_tree(), player.get_stream_playback())


func _remember_playback(player: Node) -> void:
	for index: int in range(_retired_playbacks.size() - 1, -1, -1):
		if _retired_playbacks[index].get_ref() == null:
			_retired_playbacks.remove_at(index)
	if player.has_stream_playback():
		_retired_playbacks.append(weakref(player.get_stream_playback()))


func shutdown_playbacks() -> Array[WeakRef]:
	_disconnect_session()
	stop_all()
	return _retired_playbacks.duplicate()


func configure(source: RefCounted, options: Dictionary = {}, cartridge: RefCounted = null) -> bool:
	stop_all()
	_gameplay_context=false
	level_number=0
	_local_options=options.duplicate()
	_local_cartridge=cartridge
	Settings.ensure()
	_source = source
	audio_catalog = source.load_cd_audio_catalog()
	if audio_catalog == null:
		last_error = source.last_error
		return false
	if not ClassDB.class_exists("BloodshotCddaStream") or not _fm.configure():
		last_error = "Build the project native disc/audio extension with tools/build_audio.py."
		return false
	if _effects.is_empty():
		for index: int in range(EFFECT_VOICES):
			var player := AudioStreamPlayer.new()
			player.name = "Effect%d" % (index + 1)
			player.bus = "Effects"
			add_child(player)
			_effects.append(player)
			var spatial := AudioStreamPlayer3D.new()
			spatial.name = "SpatialEffect%d" % (index + 1)
			spatial.bus = "Effects"
			# Deliberately simple flat-world mix: no Doppler or distance filter.
			spatial.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
			spatial.unit_size = NEAR_METRES
			spatial.max_distance = RANGE_METRES
			spatial.max_db = 0.0
			spatial.attenuation_filter_cutoff_hz = 20500.0
			spatial.attenuation_filter_db = 0.0
			spatial.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
			add_child(spatial)
			_spatial_effects.append(spatial)
		_listener = AudioListener3D.new()
		_listener.name = "EffectListener"
		add_child(_listener)
		_music = AudioStreamPlayer.new()
		_music.name = "CDMusic"
		_music.bus = "Music"
		add_child(_music)
		_fm_player = AudioStreamPlayer.new()
		_fm_player.name = "YMFM"
		_fm_player.bus = "Music"
		add_child(_fm_player)
	# Effects cannot block a gameplay update on decoding or media I/O.
	for source_id: int in audio_catalog.samples:
		audio_catalog.stream(source_id)
	accepted_samples = 0
	dropped_samples = 0
	last_error = ""
	return true


func bind_session(session: RefCounted) -> void:
	_disconnect_session()
	_session = weakref(session)
	session.connect("audio_requested", _on_request)
	_countdown_remaining = -1
	_countdown_epoch = -1
	if session.has_signal("world_updated"):
		session.connect("world_updated", _on_world_audio_updated)
		_on_world_audio_updated()
	_update_listener()


func start_campaign(level: Resource, entry_cue: bool = true) -> bool:
	var number := int(str(level.source_path).get_file().trim_prefix("LEVEL").trim_suffix(".LEV"))
	level_number = number
	_gameplay_context = true
	var started := play_track(int(audio_catalog.level_tracks[(maxi(1, number) - 1) % 8]), true)
	# $36F40/$37074: local player-view establishment, not every respawn.
	# Checkpoint restoration uses play_track directly and never replays this cue.
	if started and entry_cue:
		play_source(0x18700)
	return started


func ensure_completion_music() -> bool:
	# Clear cards and late joins may observe the same semantic more than once.
	# Retain the existing stream even after its natural end; never restart it.
	return true if music_track == 14 and not music_loop else play_track(14, false)


func play_source(source_id: int, position: Dictionary = {}, keep_cd: bool = false) -> bool:
	if not position.is_empty() and not AudioRequests.valid_position(position):
		return false
	if audio_catalog == null or not audio_catalog.samples.has(source_id):
		return false  # The source's negative sample IDs are silent requests.
	_update_listener()
	for index: int in range(_effects.size()):
		if not _effects[index].playing and not _spatial_effects[index].playing and not _pending_spatial.has(index):
			var player: Variant = _effects[index] if position.is_empty() else _spatial_effects[index]
			if not position.is_empty():
				player.position = _point(position)
				player.max_db = effects_volume_db
			var cartridge_stream: AudioStream = (
				_cartridge().effect(source_id)
				if not keep_cd and _provider("effects")=="md" else null
			)
			player.stream = cartridge_stream if cartridge_stream != null else audio_catalog.stream(source_id)
			player.pitch_scale = (MdRate() if cartridge_stream != null else float(audio_catalog.samples[source_id].pitch_scale))
			if cartridge_stream != null: cartridge_effects += 1
			player.volume_db = effects_volume_db
			if _paused and not position.is_empty():
				_pending_spatial[index] = true
			else:
				player.play()
				_track_player(player)
				player.stream_paused = _paused
			accepted_samples += 1
			return true
	dropped_samples += 1  # Bounded native pool: never steal or restart a playing voice.
	return false


func play_track(track: int, loop: bool = true, seek_paused: bool = false) -> bool:
	if _source == null or _music == null:
		return false
	_level_music = _gameplay_context and loop and track == int(audio_catalog.level_tracks[(maxi(1,level_number)-1)%8])
	_frontend_music = not _gameplay_context and loop and track in [2, 3]
	_escape_music = _gameplay_context and not loop and track in [5, 6]
	var use_md := (_level_music or _frontend_music or _escape_music) and _provider("music") == "md"
	# The cartridge keeps backing/Bleeps through escape. Keep the current synth
	# and its phase when the canonical CD lifecycle prepares an escape track.
	if use_md and _escape_music and music_provider == "md" and _music.stream != null:
		music_track = track
		music_loop = loop
		_cue_paused = seek_paused
		_music.stream_paused = _paused
		return true
	var stream: AudioStream
	if use_md:
		stream = _cartridge().frontend(track) if _frontend_music else _cartridge().ambient(level_number)
	else:
		stream = ClassDB.instantiate("BloodshotCddaStream")
	music_provider = "md" if use_md else "cd"
	if stream == null:
		return false
	if not use_md and not bool(stream.call("configure", _source.disc_path(), track, loop)):
		last_error = str(stream.call("get_error"))
		return false
	_remember_playback(_music)
	_music.stop()
	_music.stream = stream
	_music.volume_db = music_volume_db
	_cue_paused = seek_paused
	if not seek_paused or (use_md and _escape_music):
		_music.play()
		_track_player(_music)
	_music.stream_paused = _paused or (_cue_paused and not (_escape_music and music_provider == "md"))
	music_track = track
	music_loop = loop
	return true


func set_paused(paused: bool) -> void:
	_paused = paused
	if paused:
		for index: int in range(_spatial_effects.size()):
			var player := _spatial_effects[index]
			if player.playing and player.get_playback_position() == 0.0:
				# A newly queued voice has no mixer playback to pause yet.
				_remember_playback(player)
				player.stop()
				_pending_spatial[index] = true
	for player: Node in _all_effects():
		player.stream_paused = paused
	if not paused:
		for index: int in _pending_spatial:
			_spatial_effects[index].play()
			_track_player(_spatial_effects[index])
		_pending_spatial.clear()
	if _music != null:
		_music.stream_paused = paused or (_cue_paused and not (_escape_music and music_provider == "md"))
	if _fm_player != null:
		_fm_player.stream_paused = paused
	_fm.set_paused(paused)


func stop_all() -> void:
	stop_effects()
	if _music != null:
		_remember_playback(_music)
		_music.stream_paused = false
		_music.stop()
		_music.stream = null
	music_track = 0
	_level_music=false
	_frontend_music=false
	_escape_music=false
	for old: AudioStreamPlayer in _retiring_music:
		if is_instance_valid(old):
			_remember_playback(old)
			old.stop()
			old.queue_free()
	_retiring_music.clear()
	_cue_paused = false


func stop_effects() -> void:
	_pending_spatial.clear()
	for player: Node in _all_effects():
		_remember_playback(player)
		player.stream_paused = false
		player.stop()
		player.stream = null
	if _fm_player != null:
		_remember_playback(_fm_player)
		_fm_player.stream_paused = false
		_fm_player.stop()
		_fm_player.stream = null
	_fm.stop()
	_fm_started = false


## Compatibility for the original silent service's gameplay-facing interface.
## The campaign now uses the source command channel, avoiding duplicate effects.
func play_event(event_id: StringName, world_position: Vector3 = Vector3.ZERO) -> void:
	event_requested.emit(event_id, world_position)
	var identifiers := {
		&"door_open": 0x2572c,
		&"player_hit": 0x1c5d6,
		&"health_pickup": 0x21272,
		&"ammo_pickup": 0x17c8c,
		&"mine_trigger": 0x10d18,
		&"key_pickup": 0x21c9a,
		&"weapon_pickup": 0x17c8c
	}
	if identifiers.has(event_id):
		play_source(int(identifiers[event_id]))


func _on_request(request: Dictionary) -> void:
	source_requested.emit(request.duplicate(true))
	match str(request.kind):
		"effects_stop":
			stop_effects()
		"sample":
			if request.has("position") and not AudioRequests.valid_position(request.position):
				return
			var position: Dictionary = request.get("position", {})
			var client: RefCounted = _session.get_ref() if _session != null else null
			if client != null and request.get("emitter", {}) == _listener_reference(client):
				position = {}  # Own weapon/pickup feedback stays centered.
			play_source(int(request.source_id), position, request.get("cue","")=="core_unlock")
		"music_play":
			if int(request.track) == 14:
				ensure_completion_music()
			else:
				play_track(int(request.track), bool(request.get("loop", false)))
		"music_seek":
			play_track(int(request.track), false, true)
		"music_resume":
			_cue_paused = false
			if not _music.playing and _music.stream != null:
				_music.play()
				_track_player(_music)
			_music.stream_paused = _paused
		"music_pause":
			_cue_paused = true
			_music.stream_paused = true
		"music_stop":
			_remember_playback(_music)
			_music.stop()
			music_track = 0
		"fm_write":
			if not _fm_started:
				_fm_started = true
				_fm_player.stream = _fm.generator()
				_fm_player.play()
				_track_player(_fm_player)
				_fm_player.stream_paused = _paused
			_fm.write(int(request.port), int(request.register), int(request.value))


func _all_effects() -> Array:
	return _effects + _spatial_effects


static func _point(pose: Dictionary) -> Vector3:
	return Vector3(float(pose.x) / UNITS_PER_METRE, 0.0, -float(pose.y) / UNITS_PER_METRE)


## The same current/predicted pose as the player view, including immediate aim.
## Event positions are immutable; rotating/moving the listener updates live voices.
func set_listener_pose(pose: Dictionary) -> void:
	if _listener == null:
		return
	_listener.position = _point(pose)
	_listener.rotation.y = -float(pose.angle) * TAU / 16384.0
	_listener.make_current()


func _listener_reference(client: RefCounted) -> Dictionary:
	# Source-trace/lifecycle diagnostics also bind the legacy session adapter.
	return client.reference if client.has_method("player_pose") else client.player.player_ref()


## Bind the actual rendered camera, avoiding a second prediction/collision pass.
func bind_listener(camera: Camera3D, source_origin: Vector2i) -> void:
	_view_camera = weakref(camera)
	_view_origin = source_origin
	_update_listener()


func _update_listener() -> void:
	var camera: Camera3D = _view_camera.get_ref() if _view_camera != null else null
	if camera != null and _listener != null:
		# Spatial events use absolute source coordinates. The renderer offsets its
		# world by the map spawn; remove that offset for the independent listener.
		var origin := camera.global_position + _point({"x": _view_origin.x, "y": _view_origin.y})
		origin.y = 0.0
		_listener.global_transform = Transform3D(camera.global_basis, origin)
		_listener.make_current()
		return
	var client: RefCounted = _session.get_ref() if _session != null else null
	if client != null:
		set_listener_pose(client.player_pose() if client.has_method("player_pose") else client.motion)


func _process(_delta: float) -> void:
	_update_listener()
	if not _local_options.is_empty(): return
	var revision := Settings.revision()
	if revision == _provider_revision: return
	_provider_revision=revision
	if (_level_music or _frontend_music or _escape_music) and _music != null and music_track > 0:
		var desired := _provider("music")
		if desired != music_provider:
			_refresh_music_provider()


static func MdRate() -> float:
	return preload("res://scripts/audio/md_audio_catalog.gd").RATE / roundf(preload("res://scripts/audio/md_audio_catalog.gd").RATE)


func _refresh_music_provider() -> void:
	var old := _music
	old.name="RetiringMusic"
	_music=AudioStreamPlayer.new()
	_music.name="CDMusic"
	_music.bus="Music"
	add_child(_music)
	_retiring_music.append(old)
	var track := music_track
	var loop := music_loop
	play_track(track,loop,_cue_paused)
	_music.volume_db=-60.0
	var fade := create_tween().set_parallel(true)
	fade.tween_property(_music,"volume_db",music_volume_db,0.12)
	fade.tween_property(old,"volume_db",-60.0,0.12)
	fade.chain().tween_callback(func():
		if is_instance_valid(old):
			_remember_playback(old)
			old.stop()
			old.queue_free()
		_retiring_music.erase(old)
	)


func _disconnect_session() -> void:
	if _session != null:
		var session: RefCounted = _session.get_ref()
		if session != null:
			if session.is_connected("audio_requested", _on_request):
				session.disconnect("audio_requested", _on_request)
			if session.has_signal("world_updated") and session.is_connected("world_updated", _on_world_audio_updated):
				session.disconnect("world_updated", _on_world_audio_updated)
	_session = null
	_view_camera = null
	if _listener != null:
		_listener.clear_current()


func _exit_tree() -> void:
	shutdown_playbacks()


func _provider(kind: String) -> String:
	if _local_options.is_empty(): return Settings.active_provider(kind)
	return "md" if _local_options.get(kind,"cd")=="md" and _local_cartridge != null else "cd"


func _cartridge() -> RefCounted:
	return Settings.cartridge if _local_options.is_empty() else _local_cartridge


func _on_world_audio_updated() -> void:
	var client: RefCounted = _session.get_ref() if _session != null else null
	if client == null or not "session" in client:
		return
	var encounter: Dictionary = client.session.actor_system.get("encounter", {})
	var remaining := int(encounter.get("countdown", 0))
	if _countdown_epoch != int(client.epoch):
		# A new attachment/load seeds current time; never replay missed beeps.
		_countdown_epoch = int(client.epoch)
		_countdown_remaining = remaining
		return
	_observe_countdown(remaining, bool(client.session.countdown_expired))


func _observe_countdown(remaining: int, expired: bool = false) -> void:
	# ROM $1782..$17AA compares the old/new signed quotient by 50 and
	# requests sequence 35. Observe authoritative snapshots, not render time.
	# A skipped network update emits one current warning, never a catch-up burst.
	var previous := _countdown_remaining
	_countdown_remaining = remaining
	if _provider("effects") != "md":
		return
	if previous == 0 and remaining > 0:
		# The first observed update may already have crossed N*50 -> N*50-1.
		# An epoch/attachment was seeded above, so this is a new live countdown.
		if remaining % 50 != 0:
			play_source(0x20b5e)
		return
	if previous <= 0 or remaining >= previous:
		return
	if (remaining > 0 and remaining / 50 < previous / 50) or (remaining == 0 and expired):
		play_source(0x20b5e)
