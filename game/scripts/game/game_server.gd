class_name CdGameServer
extends RefCounted
## The application authority owns simulation, input time and campaign decisions.
## An offline endpoint is immediate delivery, not a second gameplay implementation.
signal updated
signal effect(event: Dictionary)
const Session = preload("res://scripts/simulation/cd_gameplay_session.gd")
const Admission = preload("res://scripts/game/input_admission.gd")
const Client = preload("res://scripts/game/game_client.gd")
const Motion = preload("res://scripts/simulation/cd_responsive_motion.gd")
const Snapshot = preload("res://scripts/persistence/world_checkpoint.gd")
var session := Session.new()  # Compatibility access for source/debug harnesses only.
var campaign := preload("res://scripts/game/campaign_host.gd").new()
var _paths := preload("res://scripts/presentation/cd_forward_motion_presentation.gd").new()
var _endpoints: Dictionary = {}
var _next_endpoint := 1
var _last_update := 0
var _publishing := false
var _actor_fields: Dictionary = (
	preload("res://scripts/persistence/checkpoint_schema.gd").new().records.actor.fields
)
var _public_actor_fields: Dictionary = {}
var _view_key: Array = []
var _view_actors: Array = []
# Private comparison cache catches input-phase births/deaths and changes made
# between coarse actor passes. A join cannot inherit a stale presentation cache.
var _view_source: Array = []
var _view_generations: Array = []
var _view_paths: Dictionary = {}
var _path_generations: Array = []
var _path_tick := 0
var last_error := ""
var world: RefCounted:
	get:
		return session.world


func configure(
	definition: RefCounted,
	offline: bool = true,
	scheme: int = 1,
	recording: Dictionary = {},
	carry: Dictionary = {}
) -> void:
	var previous_player: Dictionary = (
		session.fighter.duplicate(true)
		if campaign.cheated and not carry.is_empty() and session.fighter != null
		else {}
	)
	_endpoints.clear()
	_view_key = []
	_paths = preload("res://scripts/presentation/cd_forward_motion_presentation.gd").new()
	session.control_scheme = scheme
	session.demo_mode = not recording.is_empty()
	if offline:
		session.configure(definition.level, definition.tables, definition.catalog)
	else:
		session.world = preload("res://scripts/game/world_state.gd").new()
		session.player = preload("res://scripts/game/player_state.gd").new()
		session.player._world_ref = weakref(session.world)
		session.world.configure_definition(definition)
	world.stop_when_exhausted = offline
	world.admission_state = Admission.initial()
	world.admission_state.source_visibility = true
	if not recording.is_empty():
		world.demo_recording = recording
		world.demo_state = {
			"pointer": int(recording.pointer),
			"reader": {"cursor": 0, "remaining": 0, "held": 0, "edge": 0},
			"action_cursor": 0,
			"world_calls": 0,
			"finished": false
		}
		world.clock.configure_ratio(
			int(world.timing_profile.input_numerator), int(world.timing_profile.input_denominator)
		)
		session.fighter.grace = 20
		session.fighter.map_timer = 150
	world.campaign_state = campaign.describe()
	world.campaign_state.card = {}
	campaign.restore(world.campaign_state)
	campaign.level_number = int(
		(
			definition.level.source_path.trim_prefix("/LEVEL").trim_suffix(".LEV")
			if definition.level.source_path.begins_with("/LEVEL")
			else "0"
		)
	)
	campaign._transition_pending = false
	campaign._game_over_presented = false
	campaign.paused = false
	preload("res://scripts/simulation/cd_campaign_carry.gd").apply_to(session, carry)
	if campaign.cheated:
		var state := pause_state([])
		for field: String in ["lives_previous", "lives_timer", "panel_phase", "panel_phase_timer"]:
			if previous_player.has(field):
				state.player[field] = previous_player[field]
		apply_pause_state(
			preload("res://scripts/frontend/cd_pause_rules.gd").after_level_load(state), false
		)
	sync_score_policy()
	bind_world()
	refresh_views(true)


func bind_world() -> void:
	# Native play fixes source projectile tunneling. Demo/reference playback
	# keeps the original endpoint/lookahead routine, including after restore.
	if world.actor_system != null:
		world.actor_system.native_swept_hits = world.demo_recording.is_empty()
		if world.actor_system.native_swept_hits:
			preload("res://scripts/simulation/cd_projectile_flight.gd").prepare_native_geometry(world.level)
	for player: RefCounted in world.players:
		player.controls = Admission.controls.bind(weakref(world), player.handle)
		player.aim_rate = Admission.rate.bind(weakref(world), player.handle)
	if not world.audio_requested.is_connected(_audio):
		world.audio_requested.connect(_audio)
	if not world.clock.tick.is_connected(_completed):
		world.clock.tick.connect(_completed)
	_last_update = world.update_count


func attach_client(seat: int) -> RefCounted:
	var player: RefCounted
	for row: RefCounted in world.players:
		if row.seat == seat:
			player = row
	if player == null:
		return null
	if world.bots.is_bot(player.player_ref()): return null
	var client := Client.new()
	var link := preload("res://scripts/game/immediate_link.gd").new()
	link._authority = weakref(self)
	link._endpoint = _next_endpoint
	_endpoints[_next_endpoint] = {
		"player": player.player_ref(),
		"epoch": world.actor_system.epoch,
		"sequence": 0,
		"view": weakref(client)
	}
	_next_endpoint += 1
	client.link = link
	client.reference = player.player_ref()
	client.session.level = world.level
	client.session.tables = world.tables
	client.receive(snapshot(player))
	return client


func receive_command(
	endpoint: int, sequence: int, controls: Dictionary, rate: float, aim: Array
) -> bool:
	if (
		world._atomic_depth != 0
		or not _endpoints.has(endpoint)
		or campaign.paused
		or not world.demo_state.is_empty()
	):
		return false
	var binding: Dictionary = _endpoints[endpoint]
	if binding.epoch != world.actor_system.epoch or sequence != int(binding.sequence) + 1:
		return false
	if not Admission.admit(world, binding.player, controls, rate, aim):
		return false
	binding.sequence = sequence
	refresh_views()
	return true


func advance_usec(elapsed: int, budget: int = 32) -> int:
	if elapsed < 0 or budget < 0 or campaign.paused or campaign._transition_pending:
		return 0
	# Accumulate once. Events queued against this complete accepted time remain
	# behind old debt even when a caller drains only a few periods per frame.
	world.clock._phase += elapsed * world.clock._numerator
	var factor := 4 if world.demo_state.is_empty() else 1
	var executed := 0
	Admission.apply_due(world)
	while world.clock._phase >= world.clock._threshold and executed < budget * factor:
		world.clock._phase -= world.clock._threshold
		world.clock.tick_count += 1
		world.clock.tick.emit(world.clock.tick_count)
		executed += 1
		Admission.apply_due(world)
	refresh_views()
	return executed


func _completed(_ordinal: int) -> void:
	if _last_update == world.update_count:
		return
	_last_update = world.update_count
	_prepare_paths()
	for event: Dictionary in world.last_events:
		_deliver("gameplay", event)
	refresh_views()
	_publishing = true
	updated.emit()
	_publishing = false


func _audio(request: Dictionary) -> void:
	_deliver("audio", request)


func _deliver(category: String, payload: Dictionary) -> void:
	world.event_sequence += 1
	var event := {
		"epoch": world.actor_system.epoch,
		"sequence": world.event_sequence,
		"ordinal": world.clock.tick_count,
		"category": category,
		"payload": payload.duplicate(true)
	}
	if category == "audio" and world.players.size() > 1 and not world._audio_listener.is_empty():
		event.audience = world._audio_listener.duplicate()
	if payload.get("kind") == "player_fired":
		var slot := int(payload.actor)
		event.shot = {
			"epoch": world.actor_system.epoch,
			"slot": slot,
			"generation": world.actor_system.entity_generations[slot],
			"sequence": world.event_sequence
		}
	effect.emit(event.duplicate(true))
	for binding: Dictionary in _endpoints.values():
		var client: RefCounted = binding.view.get_ref()
		if client != null:
			client.receive_event(event.duplicate(true))


func refresh_views(rebuild_paths: bool = false) -> void:
	if rebuild_paths:
		_view_key = []
	if rebuild_paths and session.player.motion != null:
		_last_update = world.update_count
		_prepare_paths()
	_publishing = true
	for binding: Dictionary in _endpoints.values():
		var client: RefCounted = binding.view.get_ref()
		var player: RefCounted = world.resolve_player(binding.player)
		if client != null and player != null and binding.epoch == world.actor_system.epoch:
			client.receive(snapshot(player))
	_publishing = false


func snapshot(player: RefCounted = null) -> Dictionary:
	var key := [
		world.update_count,
		int(world.actor_system.encounter.countdown),
		world.actor_system._projectile_generation
	]
	if (
		key != _view_key
		or world.actor_system.actors != _view_source
		or world.actor_system.entity_generations != _view_generations
	):
		_view_key = key
		_view_source = world.actor_system.actors.duplicate(true)
		_view_generations = world.actor_system.entity_generations.duplicate()
		_view_actors = _public_actors(world.actor_system.actors)
		_view_paths = _paths._segments.duplicate(true)
		for slot: int in _view_paths.keys():
			if (
				slot >= _path_generations.size()
				or slot >= world.actor_system.entity_generations.size()
				or _path_generations[slot] != world.actor_system.entity_generations[slot]
			):
				_view_paths.erase(slot)
				continue
			var path: Dictionary = _view_paths[slot]
			if path.has("end"):
				var position := {}
				for field: String in ["x", "y", "height"]:
					if path.end.has(field):
						position[field] = path.end[field]
				path.end = position
		var slots: Array = _view_paths.keys()
		var sources: Array = []
		for slot: int in slots:
			sources.append(_view_paths[slot].source)
		var public_sources := _public_actors(sources)
		for index: int in range(slots.size()):
			_view_paths[slots[index]].source = public_sources[index]
		freeze(_view_actors)
		freeze(_view_paths)
	var pending_aim := 0
	for event: Dictionary in world.admission_state.queue:
		if player != null and event.player == player.player_ref():
			for delta: int in event.aim:
				pending_aim += delta
	var factor := 4 if world.demo_state.is_empty() else 1
	var period := factor * int(world.timing_profile.samples_per_update)
	var result := {
		"epoch": world.actor_system.epoch,
		"revision": world.clock.tick_count,
		"watermark": world.event_sequence,
		"pending_aim": pending_aim,
		"phase":
		clampf(
			(float(world.clock.tick_count % period) + world.clock.subtick_fraction()) / period, 0, 1
		),
		"animation_time": (float(world.clock.tick_count) + world.clock.subtick_fraction()) / factor,
		"boundary_time": float(world.clock.tick_count) / factor,
		"segments": _view_paths,
		"sight": player.weapon_sight() if player != null else {},
		"records":
		{
			"motion": player.motion.duplicate(true) if player != null else {},
			"fighter": player.fighter.duplicate(true) if player != null else {},
			"input_state": player.input_state.duplicate(true) if player != null else {},
			"keys": player.keys.duplicate(true) if player != null else [],
			"weapon_state": player.weapon_state.duplicate(true) if player != null else {},
			"groups": world.groups.duplicate(true),
			"blocked_doors": world.blocked_doors.duplicate(),
			"palette_state": world.palette_state.duplicate(),
			"last_events": world.last_events.duplicate(true),
			"countdown_expired": world.countdown_expired,
			"update_count": world.update_count,
			"demo_mode": world.demo_mode,
			"actor_system":
			{
				"actors": _view_actors,
				"encounter": world.actor_system.encounter.duplicate(true),
				"projectile_launches": world.actor_system.projectile_launches.duplicate(true),
				"entity_generations": world.actor_system.entity_generations.duplicate()
			}
		}
	}
	if not world.loot_state.is_empty():
		result.loot = world.loot_state.duplicate(true)
	if not world.vs_state.is_empty():
		result.versus = preload("res://scripts/game/vs_match.gd").public_state(world)
	freeze(result)
	return result


func _public_actors(originals: Array) -> Array:
	if ClassDB.class_exists("BloodshotPrimitiveCodec"):
		if _public_actor_fields.is_empty():
			for field: String in _actor_fields:
				if _actor_fields[field].get("replication", "public") != "server_only":
					_public_actor_fields[field] = true
		return ClassDB.instantiate("BloodshotPrimitiveCodec").project_scalar_records(
			originals, _public_actor_fields
		)
	var result := []
	for original: Dictionary in originals:
		result.append(public_actor(original, _actor_fields))
	return result


static func public_actor(actor: Dictionary, fields: Dictionary) -> Dictionary:
	var result := {}
	for key: String in actor:
		if fields[key].get("replication", "public") != "server_only":
			result[key] = actor[key]
	return result


static func freeze(value: Variant) -> void:
	if ClassDB.class_exists("BloodshotPrimitiveCodec"):
		var native: Object = ClassDB.instantiate("BloodshotPrimitiveCodec")
		if native.has_method("freeze_tree"):
			native.freeze_tree(value)
			return
	_freeze_portable(value)


static func _freeze_portable(value: Variant) -> void:
	if value is Array or value is Dictionary:
		if value.is_read_only():
			return
		for child: Variant in value.values() if value is Dictionary else value:
			_freeze_portable(child)
		value.make_read_only()


func capture_checkpoint() -> PackedByteArray:
	return world.capture_checkpoint()


func restore_checkpoint(bytes: PackedByteArray, source: RefCounted = null) -> bool:
	if world._atomic_depth != 0:
		last_error = "Restore requires a completed authority boundary"
		return false
	var candidate := preload("res://scripts/game/world_state.gd").new()
	candidate.definition = world.definition
	candidate.demo_recording = world.demo_recording
	if not candidate.restore_checkpoint(bytes, source):
		last_error = candidate.last_checkpoint_error
		return false
	install_checkpoint(candidate)
	return true


func install_checkpoint(candidate: RefCounted) -> void:
	# Scene adapters may prevalidate a candidate before rebuilding native views.
	var old_cheats := campaign.cheats_ever_enabled
	var old_eligible := campaign.score_eligible
	var preserve_history: bool = world.stop_when_exhausted and candidate.stop_when_exhausted
	world._adopt_checkpoint(candidate)
	_view_key = []
	_endpoints.clear()
	if not world.players.is_empty():
		session.player = world.players[0]
	if not world.campaign_state.is_empty():
		campaign.restore(world.campaign_state)
	else:
		campaign = preload("res://scripts/game/campaign_host.gd").new()
		campaign.level_number = int(
			(
				world.level.source_path.trim_prefix("/LEVEL").trim_suffix(".LEV")
				if world.level.source_path.begins_with("/LEVEL")
				else "0"
			)
		)
		world.campaign_state = campaign.describe()
		campaign.restore(world.campaign_state)
	if preserve_history:
		if old_cheats:
			campaign.disable_scoring_for_cheats()
		campaign.score_eligible = campaign.score_eligible and old_eligible
	sync_score_policy()
	bind_world()
	refresh_views(true)


func sync_score_policy() -> void:
	# Derived from durable campaign history, never the local access switch.
	if world.actor_system == null:
		return
	world.actor_system.scoring_disabled = (
		campaign.cheats_ever_enabled and world.stop_when_exhausted
		and not world.demo_mode and not world.actor_system.native_multiplayer
	)
	if world.actor_system.scoring_disabled:
		world.actor_system.encounter.damage_total = 0


func release_controls(flush_latch: bool) -> void:
	# Neutral input is admitted after older accepted work, including debt. A
	# resume never erases semantic events accepted before a save or pause.
	world.accepted_controls.clear()
	for player: RefCounted in world.players:
		if world.bots.is_bot(player.player_ref()): continue
		Admission.admit(world, player.player_ref(), {"held": 0xffffffff, "strafe": 0}, 0.0, [])
		if flush_latch:
			player.latch.state = {"held": 0xffffffff, "edge": 0xffffffff, "previous": 0xffffffff}
	refresh_views()


func pause_state(history: Array) -> Dictionary:
	var player: Dictionary = session.fighter.duplicate(true)
	player.keys = session.keys.duplicate(true)
	player.weapons = session.weapon_state.duplicate(true)
	return {
		"player": player,
		"mode": 1 if campaign.paused else 2,
		"level": campaign.level_number,
		"damage_total": int(world.actor_system.encounter.damage_total),
		"cheated": -1 if campaign.cheated else 0,
		"exit_delay": int(world.actor_system.encounter.exit_delay),
		"history": history.duplicate(),
		"windows": [0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff]
	}


func apply_pause_state(state: Dictionary, timers: bool = true) -> void:
	# Retained source backend; the shipped pause menu does not dispatch cheats.
	var player: Dictionary = state.player.duplicate(true)
	session.keys = player.keys
	session.weapon_state = player.weapons
	player.erase("keys")
	player.erase("weapons")
	session.fighter = player
	world.actor_system.encounter.damage_total = int(state.damage_total)
	if timers:
		world.actor_system.encounter.exit_delay = int(state.exit_delay)
	campaign.cheated = int(state.cheated) != 0


func _prepare_paths() -> void:
	_paths.prepare(session, int(world.timing_profile.samples_per_update))
	_path_generations = world.actor_system.entity_generations.duplicate()
	_path_tick = world.clock.tick_count
