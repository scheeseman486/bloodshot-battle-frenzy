class_name CdWorldState
extends RefCounted
## Authoritative world lifetime is independent of participants and avatars.
## Player phases run in seat order; shared clocks/doors/actors run exactly once.
signal audio_requested(request: Dictionary)
signal weapon_feedback(feedback: Dictionary)
const AudioRequests = preload("res://scripts/audio/cd_audio_requests.gd")
const Definition = preload("res://scripts/game/world_definition.gd")
const Player = preload("res://scripts/game/player_state.gd")
const Actors = preload("res://scripts/simulation/cd_actor_system.gd")
const Clock = preload("res://scripts/simulation/reference_clock.gd")
const Motion = preload("res://scripts/simulation/cd_responsive_motion.gd")
const Progression = preload("res://scripts/simulation/cd_level_progression.gd")
const Palette = preload("res://scripts/simulation/cd_countdown_palette.gd")
const Lifecycle = preload("res://scripts/simulation/cd_player_lifecycle.gd")
const Obstruction = preload("res://scripts/simulation/cd_door_obstruction.gd")
const Doors = preload("res://scripts/simulation/cd_door_rules.gd")
const Versus = preload("res://scripts/game/vs_match.gd")
const DEFAULT_PROFILE = preload("res://resources/simulation/cd_logical_six.tres")
const MAX_PLAYERS := 4
var definition: RefCounted
var actor_system: RefCounted
var groups: Array = []
var blocked_doors: Array = []
var last_events: Array = []
var update_count := 0
var countdown_expired := false
var palette_state := {"phase": 0, "bank": 0}
var demo_mode := false
var demo_actions: Array = []
var demo_state: Dictionary = {}
# Source recording is immutable content and is rebound from the CD on restore.
var demo_recording: Dictionary = {}
# Offline exhaustion is a campaign policy, not an empty-world invariant.
var stop_when_exhausted := false
var _players: Array = []
var _next_player_id := 1
var _seat_generations: Array = [0, 0, 0, 0]
var _initial_proxy_claimed := false
var _external_clock := false
var clock := Clock.new()
var timing_profile: Resource = DEFAULT_PROFILE
# Portable continuation owned by the authority; scene adapters fill optional
# campaign/view records. Physical input devices and wall time are never captured.
var score_state: Dictionary = {}
var vs_state: Dictionary = {}
var bots := preload("res://scripts/game/bot_runtime.gd").new()
# Atomic combat observations settle before a legal snapshot/checkpoint boundary.
var vs_pending := {"damaged": [], "kills": []}
# Native inventory continuation; geometry is a rebuildable content index.
var loot_state: Dictionary = {}
var _loot_geometry := preload("res://scripts/game/native_drop_geometry.gd").new()
var campaign_state: Dictionary = {}
var presentation_state: Dictionary = {}
var event_sequence := 0
var pending_events: Array = []
var pending_commands: Array = []
var accepted_controls: Dictionary = {}
var admission_state: Dictionary = preload("res://scripts/game/input_admission.gd").initial()
var last_checkpoint_error := ""
var _atomic_depth := 0
# Transient listener for per-view UI cues; never checkpoint or gameplay state.
var _audio_listener: Dictionary = {}

var level: Resource:
	get:
		return definition.level
var tables: Resource:
	get:
		return definition.tables
var players: Array:
	get:
		return _players.duplicate()


func configure(
	original_level: Resource, original_tables: Resource, original_catalog: Resource = null
) -> void:
	var data := Definition.new()
	data.configure(original_level, original_tables, original_catalog)
	configure_definition(data)


func configure_definition(data: RefCounted) -> void:
	# Reconfiguration starts a new timeline. A previous single-player driver's
	# clock must not retain authority over this world's new dispatcher.
	if clock.tick.is_connected(_fast_step):
		clock.tick.disconnect(_fast_step)
	clock = Clock.new()
	_external_clock = false
	definition = data
	bots = preload("res://scripts/game/bot_runtime.gd").new()
	_players.clear()
	# Reconfiguring an existing authority invalidates old entity/participant refs.
	# Fresh single-player facades still begin with source handle zero.
	_initial_proxy_claimed = false
	groups.clear()
	for group: Dictionary in level.moving_groups:
		groups.append({"kind": group.kind, "fraction": 0, "state": 0, "timer": 0})
	blocked_doors.clear()
	last_events.clear()
	demo_actions.clear()
	demo_state = {}
	demo_recording = {}
	score_state = (
		preload("res://scripts/game/coop_score.gd").initial_world()
		if data.get_meta("session_flow", false) and level.source_path.begins_with("/LEVEL")
		else {}
	)
	loot_state = (
		preload("res://scripts/game/native_inventory_drops.gd").initial()
		if data.get_meta("session_flow", false) else {}
	)
	if not loot_state.is_empty(): _loot_geometry.configure(level)
	campaign_state = {}
	presentation_state = {}
	pending_commands.clear()
	accepted_controls.clear()
	admission_state = preload("res://scripts/game/input_admission.gd").initial()
	pending_events.clear()
	event_sequence = 0
	update_count = 0
	countdown_expired = false
	palette_state = {"phase": 0, "bank": 0}
	actor_system = null
	vs_state = {}
	vs_pending = {"damaged": [], "kills": []}
	if definition.catalog != null:
		actor_system = Actors.new()
		actor_system.configure(level, definition.catalog, tables, false)
		actor_system.native_multiplayer = data.get_meta("session_flow", false)
		actor_system.participant_died.connect(_drop_dead_inventory)
		# Authority identity is separate from source RNG and logical game time.
		actor_system.epoch = ResourceUID.create_id()
		actor_system.audio_requested.connect(_relay_actor_audio)
		actor_system.combat_scored.connect(_record_score)
		actor_system.mine_stepped.connect(_record_mine)
		actor_system.meltdown_started.connect(_begin_evacuation)
		actor_system.opponent_killed.connect(_vs_killed)
		actor_system.item_collected.connect(_vs_collected)
		actor_system.player_lethal.connect(_vs_lethal)
		if data.get_meta("session_flow", false) and level.get_meta("battle_mode", false):
			# Owner removed obsolete checkpoint pylons from native VS. Keep the
			# original catalog/placement slots immutable and clear only live copies.
			for slot: int in range(actor_system.actors.size()):
				if int(actor_system.actors[slot].kind) == 15:
					actor_system.actors[slot] = preload("res://scripts/simulation/cd_projectile_flight.gd").clear(actor_system.actors[slot])
			vs_state = Versus.initial(self)
	clock.configure_ratio(
		int(timing_profile.input_numerator) * Motion.SUBSTEPS, int(timing_profile.input_denominator)
	)
	if not clock.tick.is_connected(_fast_step):
		clock.tick.connect(_fast_step)


## Read-only capacity check for a whole native roster edit. Source proxy slots,
## seat generations and participant IDs must all be available before committing.
func has_player_capacity(seats: Array, replacing: Dictionary = {}) -> bool:
	var departing: RefCounted = resolve_player(replacing) if not replacing.is_empty() else null
	if not replacing.is_empty() and departing == null:
		return false
	var retained := _players.size() - int(departing != null)
	if (_external_clock and retained > 0) or retained + seats.size() > MAX_PLAYERS:
		return false
	if seats.is_empty():
		return true
	if _next_player_id + seats.size() - 1 > 0xffffffff:
		return false
	var reserved := []
	for seat: Variant in seats:
		if not seat is int or seat < 0 or seat >= MAX_PLAYERS or seat in reserved:
			return false
		if int(_seat_generations[seat]) >= 0xffffffff:
			return false
		if _players.any(func(player): return player != departing and int(player.seat) == seat):
			return false
		reserved.append(seat)
	if actor_system != null:
		# The source's first proxy appends; subsequent ones use first-empty.
		if not _initial_proxy_claimed and actor_system.actors.size() >= 180:
			return false
		var available: int = 180 - actor_system.actors.size()
		for actor: Dictionary in actor_system.actors:
			if int(actor.kind) == 0:
				available += 1
		if departing != null:
			var proxy := int(actor_system.player_proxies.get(departing.handle, -1))
			if proxy >= 0 and proxy < actor_system.actors.size() and int(actor_system.actors[proxy].kind) == 20:
				available += 1
		if available < seats.size():
			return false
	return true


## Native replacement commits at one authority boundary, with no world clone,
## checkpoint round-trip, navigation rebuild or change to surviving participants.
func replace_player(reference: Dictionary) -> Dictionary:
	var departing := resolve_player(reference)
	if (_atomic_depth != 0 or departing == null or not definition.get_meta("session_flow", false)
		or not has_player_capacity([departing.seat], reference)):
		return {}
	var seat: int = departing.seat
	var seed: int = vs_state.get("rng", 0)
	var spawn: Dictionary = (
		preload("res://scripts/game/vs_spawns.gd").select(self, departing.handle)
		if not vs_state.is_empty()
		else preload("res://scripts/game/coop_spawns.gd").select(self, seat, departing.handle)
	)
	if spawn.is_empty():
		if not vs_state.is_empty(): vs_state.rng = seed
		return {}
	# Departure drops use the separate native item pool. Removing this proxy can
	# only increase source capacity; no callback/await can interleave an admission.
	remove_player(reference)
	var replacement := spawn_player(seat, spawn)
	assert(not replacement.is_empty(), "Preflighted native replacement must have capacity")
	return replacement


func spawn_player(seat: int, spawn: Dictionary = {}) -> Dictionary:
	if not has_player_capacity([seat]):
		return {}

	var player := Player.new()
	player.configure(self, _next_player_id, int(_seat_generations[seat]) + 1, seat)
	var spawn_seed: int = vs_state.get("rng", 0)
	if spawn.is_empty():
		spawn = (
			preload("res://scripts/game/vs_spawns.gd").select(self)
			if not vs_state.is_empty()
			else preload("res://scripts/game/coop_spawns.gd").select(self, seat)
		)
		if spawn.is_empty():
			return {}
	for field: String in ["x", "y", "angle"]:
		if spawn.has(field):
			player.motion[field] = int(spawn[field])
	player.fighter.checkpoint_x = player.motion.x
	player.fighter.checkpoint_y = player.motion.y
	player.fighter.checkpoint_angle = player.motion.angle
	player.world_origin = Vector2i(player.motion.x, player.motion.y)
	if actor_system != null:
		var proxy: int = actor_system.add_player_proxy(
			player.handle, player.combat_state(), not _initial_proxy_claimed
		)
		if proxy < 0:
			if not vs_state.is_empty(): vs_state.rng = spawn_seed
			return {}  # Capacity failure publishes neither a participant nor a proxy.
		player.fighter.proxy = proxy
		if actor_system.native_multiplayer:
			actor_system.actors[proxy].player_colour = seat
		actor_system.participant_refs[player.handle] = player.player_ref()
		actor_system.player_schemes[player.handle] = player.control_scheme
	_initial_proxy_claimed = true
	_next_player_id += 1
	_seat_generations[seat] = player.generation
	_players.append(player)
	_players.sort_custom(func(left, right): return int(left.seat) < int(right.seat))
	player.audio_requested.connect(_relay_player_audio.bind(player.player_ref()))
	player.weapon_feedback.connect(weapon_feedback.emit)
	Versus.joined(self, player)
	return player.player_ref()


func resolve_player(reference: Dictionary) -> RefCounted:
	if not reference.has_all(["id", "generation"]):
		return null
	if not reference.id is int or not reference.generation is int:
		return null
	for player: RefCounted in _players:
		if player.id == int(reference.id) and player.generation == int(reference.generation):
			return player
	return null


func get_player(reference: Dictionary) -> RefCounted:
	return resolve_player(reference)


func remove_player(reference: Dictionary) -> bool:
	var player := resolve_player(reference)
	if player == null:
		return false
	if not loot_state.is_empty():
		preload("res://scripts/game/native_inventory_drops.gd").scatter(self, player)
		preload("res://scripts/game/native_inventory_drops.gd").depart(self, player)
	elif int(player.fighter.state) != 0:
		_transfer_keys(player)
	if actor_system != null:
		actor_system.remove_player_context(player.handle)
	accepted_controls.erase(player.handle)
	pending_commands = pending_commands.filter(func(command): return command.player != reference)
	admission_state.controls.erase(player.handle)
	admission_state.rates.erase(player.handle)
	admission_state.queue = admission_state.queue.filter(
		func(event): return event.player != reference
	)
	_players.erase(player)
	bots.sync(self)
	Versus.left(self, player.handle)
	return true


func set_enemy_target(entity: Dictionary, participant: Dictionary) -> bool:
	if actor_system == null or actor_system.resolve_entity(entity) == null:
		return false
	var player := resolve_player(participant)
	if player == null:
		return false
	var slot := int(entity.slot)
	if int(actor_system.actors[slot].kind) < 1 or int(actor_system.actors[slot].kind) > 19:
		return false
	actor_system.actors[slot].target = player.handle
	if not actor_system.active.has(slot):
		actor_system.active.append(slot)
	return true


func enemy_target_ref(entity: Dictionary) -> Dictionary:
	if actor_system == null or actor_system.resolve_entity(entity) == null:
		return {}
	var handle := int(actor_system.actors[int(entity.slot)].target)
	return actor_system.participant_refs.get(handle, {}).duplicate()


func is_complete() -> bool:
	return actor_system != null and int(actor_system.encounter.mode) == 3


func is_game_over() -> bool:
	return actor_system != null and int(actor_system.encounter.mode) == 0


func sample_controls(commands: Dictionary) -> void:
	_atomic_depth += 1
	_sample_controls(commands)
	_atomic_depth -= 1


func _sample_controls(commands: Dictionary) -> void:
	if is_game_over() or is_complete():
		return
	if actor_system != null and stop_when_exhausted and not _players.is_empty():
		actor_system.encounter.mode = Lifecycle.finish(
			int(actor_system.encounter.mode),
			party_players().map(func(player): return player.fighter.state)
		)
		if is_game_over():
			last_events = [{"kind": "game_over"}]
			event_sequence += 1
			return
	_global_input_prefix()
	for player: RefCounted in _players:
		if int(player.fighter.state) != 0:
			player.sample_controls(commands.get(player.id, 0xffffffff))


func _global_input_prefix() -> void:
	if actor_system == null or int(actor_system.encounter.mode) != 2:
		return
	var palette_active := int(actor_system.encounter.countdown) != 0
	var previous_states: Array = _players.map(func(player): return int(player.fighter.state))
	var timer := Progression.tick(
		actor_system.encounter, _players.map(func(player): return player.fighter)
	)
	actor_system.encounter = timer.state
	palette_state = Palette.advance(palette_state, palette_active, bool(timer.expired))
	if int(timer.state.countdown) == int(timer.state.countdown_boundary) + 100:
		audio_requested.emit({"kind": "music_resume"})
	for index: int in range(_players.size()):
		var player: RefCounted = _players[index]
		player.fighter = timer.players[index]
		player.motion.state = player.fighter.state
	if not timer.expired:
		return
	_finish_evacuation(true)
	audio_requested.emit({"kind": "effects_stop"})
	for index: int in range(_players.size()):
		if previous_states[index] == 1:
			actor_system.player_died(_players[index].handle)
			audio_requested.emit(AudioRequests.sample(0x1cc3a, _players[index].motion, _players[index].player_ref()))
			audio_requested.emit(AudioRequests.sample(0x2547e, _players[index].motion, _players[index].player_ref()))
	countdown_expired = true
	# Native co-op settles a mixed evacuation at the deadline. The CD's retry
	# would revive failed arrivals while escaped players remain locked at spawn.
	# Keep source death/life/drop effects above and the normal 150-unit exit hold;
	# no survivor (and all offline play) retains the original reactor retry.
	if actor_system.native_multiplayer and party_players().any(func(player): return int(player.fighter.state) == 3):
		actor_system.encounter.exit_delay = 150
		# Native co-op partial evacuation has the same completed-level handoff.
		audio_requested.emit({"kind": "music_play", "track": 14, "loop": false})
		return
	for index: int in range(actor_system.actors.size()):
		actor_system.actors[index] = Progression.restore(
			actor_system.actors[index], actor_system.catalog
		)
	for player: RefCounted in _players:
		player._sightings = player.actor_visibility.sightings()


func step(elapsed: int, visibility: Dictionary = {}, move_players: bool = true) -> void:
	_atomic_depth += 1
	_step(elapsed, visibility, move_players)
	_atomic_depth -= 1


func _step(elapsed: int, visibility: Dictionary, move_players: bool) -> void:
	if not vs_state.is_empty() and vs_state.phase != "playing": return
	assert(elapsed > 0 and elapsed <= 15)
	last_events.clear()
	if is_complete() or is_game_over():
		return
	var remainder := int(actor_system.geometry_remainder) if actor_system != null else 0
	for player: RefCounted in _players:
		player.begin_step(elapsed, visibility.get(player.id, Callable()), move_players)
		remainder = player._door_remainder
	var blockers: Array = _players.map(func(player): return player.motion)
	if actor_system != null:
		for slot: int in actor_system.active:
			var actor: Dictionary = actor_system.actors[slot]
			blockers.append({"state": actor.kind, "x": actor.x, "y": actor.y})
	var blocked: Array = []
	for index: int in range(groups.size()):
		var group: Dictionary = groups[index]
		var metadata: Dictionary = level.moving_groups[index]
		if int(group.state) == Doors.State.CLOSING and int(metadata.first) >= 0:
			var query := Obstruction.query(
				level,
				index,
				int(group.fraction),
				int(metadata.first),
				int(metadata.last),
				blockers,
				remainder
			)
			remainder = int(query.remainder)
			if query.blocked:
				blocked.append(index)
	blocked_doors = blocked.duplicate()
	var before := groups
	groups = Doors.advance(groups, elapsed, blocked)
	for index: int in range(groups.size()):
		if (
			int(before[index].state) == Doors.State.CLOSING
			and int(groups[index].state) == Doors.State.CLOSED
		):
			audio_requested.emit(AudioRequests.door(0x27392, level, index))
	if actor_system != null:
		actor_system.geometry_remainder = remainder
		var contexts := {}
		var sightings := {}
		for player: RefCounted in _players:
			contexts[player.handle] = player.combat_state()
			# The CD consumes the preceding visibility window even when lifecycle
			# changes this player's state to exhausted during the current prefix.
			# Disconnect removes the participant entirely, rather than erasing history
			# early for a still-present dead/escaped/exhausted participant.
			sightings[player.handle] = player._sightings
		if demo_mode:
			actor_system.apply_demo_actions(demo_actions)
			demo_actions.clear()
		actor_system.advance_players(contexts, elapsed, groups, sightings)
		for player: RefCounted in _players:
			player.commit_combat(actor_system.player_contexts[player.handle])
		last_events.append_array(actor_system.events)
		for player: RefCounted in _players:
			player._sightings = player.actor_visibility.sightings(true)
		var previous_exit_delay := int(actor_system.encounter.exit_delay)
		actor_system.encounter = Progression.finish(
			actor_system.encounter, party_players().map(func(player): return player.fighter), elapsed
		)
		if previous_exit_delay == 0 and int(actor_system.encounter.exit_delay) == 150:
			# Original $3205E/$32068 replaces the old stream when escape begins,
			# before the exit delay/card. This public event reaches every endpoint.
			audio_requested.emit({"kind": "music_play", "track": 14, "loop": false})
		if is_complete():
			_finish_evacuation(false)
	update_count += 1
	Versus.finish_update(self)
	event_sequence += last_events.size()


func _drop_dead_inventory(handle: int, context: Dictionary) -> void:
	for player: RefCounted in _players:
		if player.handle == handle and not loot_state.is_empty():
			var inventory: Dictionary = context if int(context.get("state", 0)) == 2 else player.combat_state()
			var health := Versus.died(self, player, context)
			preload("res://scripts/game/native_inventory_drops.gd").scatter(self, player, inventory, health)
			context.keys = player.keys
			context.weapons = player.weapon_state
			return


func player_exhausted(player: RefCounted) -> void:
	if not loot_state.is_empty():
		preload("res://scripts/game/native_inventory_drops.gd").scatter(self, player)
	else:
		_transfer_keys(player)
	if actor_system != null:
		actor_system.exhaust_player_proxy(player.handle)


func _transfer_keys(donor: RefCounted) -> void:
	# $35E60 copies a contiguous key prefix, preserves the donor and uses 35
	# insertion ticks. Native seats 3/4 choose the first alive survivor in seat order.
	for receiver: RefCounted in _players:
		if receiver == donor or int(receiver.fighter.state) != 1:
			continue
		var slot := 0
		while slot < receiver.keys.size() and int(receiver.keys[slot].kind) != 0:
			slot += 1
		if slot == receiver.keys.size():
			return
		for key: Dictionary in donor.keys:
			if int(key.kind) == 0 or slot >= receiver.keys.size():
				break
			receiver.keys[slot] = {"kind": int(key.kind), "timer": 35}
			slot += 1
		audio_requested.emit(AudioRequests.sample(0x2547e, receiver.motion, receiver.player_ref()))
		return


func advance_usec(elapsed: int, budget: int = 32) -> int:
	var factor := (
		Motion.SUBSTEPS
		if clock._numerator == int(timing_profile.input_numerator) * Motion.SUBSTEPS
		else 1
	)
	return clock.advance(elapsed, budget * factor)


func bind_driver_clock(external: RefCounted, profile: Resource) -> void:
	# A transitional source/native/demo driver supplies the same authority clock.
	# Disconnect our dispatcher before adopting it; two subscribers would run the
	# world twice. Standalone multi-player worlds use the dispatcher below.
	if clock.tick.is_connected(_fast_step):
		clock.tick.disconnect(_fast_step)
	clock = external
	timing_profile = profile
	_external_clock = true


func _fast_step(index: int) -> void:
	_atomic_depth += 1
	if not Versus.fast_step(self):
		_atomic_depth -= 1
		return
	bots.step(self)
	_clock_step(index)
	preload("res://scripts/game/input_admission.gd").apply_due(self)
	if not is_complete() and not is_game_over():
		preload("res://scripts/game/native_inventory_drops.gd").advance(
			self, float(timing_profile.input_denominator) / clock._numerator
		)
	_atomic_depth -= 1


func _clock_step(index: int) -> void:
	_apply_pending_commands(index)
	if not demo_state.is_empty():
		preload("res://scripts/frontend/cd_demo_continuation.gd").advance(
			self, index, _clock_visibility()
		)
		return
	if clock._numerator == int(timing_profile.input_numerator):
		var commands := {}
		for player: RefCounted in _players:
			commands[player.id] = _controls_for(player, index)
		sample_controls(commands)
		if index % int(timing_profile.samples_per_update) == 0:
			step(int(timing_profile.samples_per_update), _clock_visibility())
		return
	if index % Motion.SUBSTEPS == 0:
		var commands := {}
		for player: RefCounted in _players:
			commands[player.id] = (_controls_for(player, index / Motion.SUBSTEPS))
		sample_controls(commands)
	var seconds := (
		float(timing_profile.input_denominator)
		/ (float(timing_profile.input_numerator) * Motion.SUBSTEPS)
	)
	for player: RefCounted in _players:
		if admission_state.rates.has(player.handle):
			Motion.aim(player.motion, float(admission_state.rates[player.handle]) * seconds)
		elif player.aim_rate.is_valid():
			Motion.aim(player.motion, float(player.aim_rate.call()) * seconds)
		player.advance_responsive_motion(int(timing_profile.samples_per_update))
	if index % (Motion.SUBSTEPS * int(timing_profile.samples_per_update)) == 0:
		for player: RefCounted in _players:
			player.motion.prev_x = player.world_origin.x
			player.motion.prev_y = player.world_origin.y
		step(int(timing_profile.samples_per_update), _clock_visibility(), false)
		for player: RefCounted in _players:
			player.world_origin = Vector2i(player.motion.x, player.motion.y)


func capture_checkpoint() -> PackedByteArray:
	var service := preload("res://scripts/persistence/world_checkpoint.gd").new()
	var bytes := service.capture(self)
	last_checkpoint_error = service.last_error
	return bytes


func restore_checkpoint(bytes: PackedByteArray, source: RefCounted = null) -> bool:
	var service := preload("res://scripts/persistence/world_checkpoint.gd").new()
	var restored := service.restore(self, bytes, source)
	last_checkpoint_error = service.last_error
	return restored


func continuation_digest() -> String:
	return preload("res://scripts/persistence/world_checkpoint.gd").new().digest(self)


func replicated_digest() -> String:
	return preload("res://scripts/persistence/world_checkpoint.gd").new().digest(self, true)


func _adopt_checkpoint(candidate: RefCounted) -> void:
	if clock.tick.is_connected(_fast_step):
		clock.tick.disconnect(_fast_step)
	if actor_system != null and actor_system.audio_requested.is_connected(_relay_actor_audio):
		actor_system.audio_requested.disconnect(_relay_actor_audio)
	if actor_system != null and actor_system.combat_scored.is_connected(_record_score):
		actor_system.combat_scored.disconnect(_record_score)
	if actor_system != null and actor_system.mine_stepped.is_connected(_record_mine):
		actor_system.mine_stepped.disconnect(_record_mine)
	if actor_system != null and actor_system.meltdown_started.is_connected(_begin_evacuation):
		actor_system.meltdown_started.disconnect(_begin_evacuation)
	candidate.clock.tick.disconnect(candidate._fast_step)
	candidate.actor_system.audio_requested.disconnect(candidate._relay_actor_audio)
	candidate.actor_system.combat_scored.disconnect(candidate._record_score)
	candidate.actor_system.mine_stepped.disconnect(candidate._record_mine)
	candidate.actor_system.meltdown_started.disconnect(candidate._begin_evacuation)
	candidate.actor_system.participant_died.disconnect(candidate._drop_dead_inventory)
	if actor_system != null and actor_system.participant_died.is_connected(_drop_dead_inventory):
		actor_system.participant_died.disconnect(_drop_dead_inventory)
	for pair: Array in [["opponent_killed", "_vs_killed"], ["item_collected", "_vs_collected"], ["player_lethal", "_vs_lethal"]]:
		if actor_system != null and actor_system.is_connected(pair[0], Callable(self, pair[1])):
			actor_system.disconnect(pair[0], Callable(self, pair[1]))
		candidate.actor_system.disconnect(pair[0], Callable(candidate, pair[1]))
	loot_state = candidate.loot_state.duplicate(true)
	_loot_geometry = candidate._loot_geometry
	score_state = candidate.score_state.duplicate(true)
	vs_state = candidate.vs_state.duplicate(true)
	bots = preload("res://scripts/game/bot_runtime.gd").new()
	bots.state = candidate.bots.state.duplicate(true)
	# Fresh map candidates already prepared navigation before publication. Keep
	# that shared cache so the first playable frame never builds a grid.
	bots.navigation = candidate.bots.navigation
	if not bots.state.rows.is_empty() and candidate.level.source_path!="/NATIVE/LOBBY":
		bots.navigation.configure(candidate.level)
	vs_pending = {"damaged": [], "kills": []}
	definition = candidate.definition
	demo_recording = candidate.demo_recording
	actor_system = candidate.actor_system
	clock = candidate.clock
	timing_profile = candidate.timing_profile
	for field: String in preload("res://scripts/persistence/world_checkpoint.gd").WORLD_FIELDS:
		set(field, candidate.get(field))
	_players = candidate._players.duplicate()
	for player: RefCounted in _players:
		player._world_ref = weakref(self)
		var previous_audio: Callable = candidate._relay_player_audio.bind(player.player_ref())
		if player.audio_requested.is_connected(previous_audio):
			player.audio_requested.disconnect(previous_audio)
		player.audio_requested.connect(_relay_player_audio.bind(player.player_ref()))
		if player.weapon_feedback.is_connected(candidate.weapon_feedback.emit):
			player.weapon_feedback.disconnect(candidate.weapon_feedback.emit)
		player.weapon_feedback.connect(weapon_feedback.emit)
	actor_system.audio_requested.connect(_relay_actor_audio)
	actor_system.combat_scored.connect(_record_score)
	actor_system.mine_stepped.connect(_record_mine)
	actor_system.meltdown_started.connect(_begin_evacuation)
	actor_system.participant_died.connect(_drop_dead_inventory)
	actor_system.opponent_killed.connect(_vs_killed)
	actor_system.item_collected.connect(_vs_collected)
	actor_system.player_lethal.connect(_vs_lethal)
	bots.sync(self)
	clock.tick.connect(_fast_step)
	_external_clock = false
	last_events.clear()  # Historical transient cues are not replayed on attachment.


func queue_command(
	reference: Dictionary, ordinal: int, controls: Variant, aim_events: Array = []
) -> bool:
	# Already-admitted commands at completed fast boundaries. Host timestamp/
	# fractional-event admission belongs to the unified scheduler in 010d.
	var player := resolve_player(reference)
	if player == null or ordinal <= clock.tick_count or pending_commands.size() >= 256:
		return false
	if not pending_commands.is_empty() and ordinal < int(pending_commands.back().ordinal):
		return false
	if controls is Dictionary:
		if controls.size() != 2 or not controls.has_all(["held", "strafe"]):
			return false
		if (
			not controls.held is int
			or not controls.strafe is int
			or controls.strafe < -1
			or controls.strafe > 1
		):
			return false
		if controls.held < 0 or controls.held > 0xffffffff:
			return false
	elif not controls is int or controls < 0 or controls > 0xffffffff:
		return false
	if (
		aim_events.size() > 64
		or not aim_events.all(
			func(delta): return delta is int and delta > -1073741824 and delta < 1073741824
		)
	):
		return false
	pending_commands.append(
		{
			"player": reference.duplicate(),
			"ordinal": ordinal,
			"controls": controls.duplicate(true) if controls is Dictionary else controls,
			"aim_events": aim_events.duplicate()
		}
	)
	return true


func _apply_pending_commands(index: int) -> void:
	while not pending_commands.is_empty() and int(pending_commands.front().ordinal) <= index:
		var command: Dictionary = pending_commands.pop_front()
		var player := resolve_player(command.player)
		if player == null:
			continue
		accepted_controls[player.handle] = command.controls
		for delta: int in command.aim_events:
			Motion.aim(player.motion, float(delta) / 65536.0)


func _controls_for(player: RefCounted, index: int) -> Variant:
	if accepted_controls.has(player.handle):
		return accepted_controls[player.handle]
	if admission_state.controls.has(player.handle):
		return admission_state.controls[player.handle]
	return player.controls.call(index) if player.controls.is_valid() else 0xffffffff


func _clock_visibility() -> Dictionary:
	var result := {}
	if admission_state.source_visibility:
		for player: RefCounted in _players:
			result[player.id] = func(index: int) -> bool:
				var span: Array = player.actor_visibility.door_range()
				return index >= int(span[0]) and index <= int(span[1])
	return result


func _relay_player_audio(request: Dictionary, reference: Dictionary) -> void:
	var outgoing := request.duplicate(true)
	var previous := _audio_listener
	var player: RefCounted = resolve_player(reference)
	var public_cue := bool(outgoing.get("public", false)) or outgoing.has("position")
	outgoing.erase("public")
	if public_cue and not outgoing.has("position") and player != null:
		outgoing = AudioRequests.sample(
			int(request.source_id), player.motion, reference)
		if request.has("cue"):
			outgoing.cue = request.cue
	_audio_listener = {} if public_cue else reference
	if public_cue: bots.hear(self,outgoing)
	audio_requested.emit(outgoing)
	_audio_listener = previous


func _record_score(handle: int, increments: Dictionary) -> void:
	Versus.damage(self, handle, int(increments.get("taken", 0)))
	for player: RefCounted in _players:
		if player.handle != handle or player.level_stats.is_empty():
			continue
		for field: String in increments:
			player.level_stats[field] = mini(
				preload("res://scripts/game/coop_score.gd").LIMIT,
				int(player.level_stats[field]) + increments[field]
			)
		return


func _vs_killed(shooter: int, victim: int) -> void:
	Versus.killed(self, shooter, victim)


func _vs_collected(slot: int) -> void:
	Versus.collected(self, slot)


func _vs_lethal(victim: int, shooter: int) -> void:
	if vs_state.is_empty() or victim != shooter: return
	var entry := Versus.row(self, victim)
	if not entry.is_empty() and not entry.dead:
		entry.suicides = mini(999999, int(entry.suicides) + 1)


func _record_mine(handle: int) -> void:
	if score_state.is_empty() or score_state.mine_claimed:
		return
	if not actor_system.participant_refs.has(handle):
		return
	score_state.mine_claimed = true
	_record_score(handle, {"doofus": 1})


func _begin_evacuation() -> void:
	if score_state.is_empty() or not score_state.evacuation.is_empty():
		return  # One award assessment per level attempt, even if the core restores.
	var eligible := []
	var contributors := []
	for player: RefCounted in _players:
		var context: Dictionary = actor_system.player_contexts.get(player.handle, player.fighter)
		if int(context.state) == 0 or player.level_stats.is_empty():
			continue
		eligible.append(player.player_ref())
		if int(player.level_stats.reactor) > 0 and not bots.is_bot(player.player_ref()):
			contributors.append(player.player_ref())
	score_state.evacuation = {
		"active": true, "eligible": eligible, "contributors": contributors, "arrivals": []
	}


func _record_escape(handle: int) -> void:
	if score_state.is_empty() or score_state.evacuation.is_empty():
		return
	var escape: Dictionary = score_state.evacuation
	var reference: Dictionary = actor_system.participant_refs.get(handle, {})
	if not escape.active or reference not in escape.eligible or reference in escape.arrivals:
		return
	# Only reactor contributors participate in the race back. Other arrivals
	# still count as evacuated, but cannot claim or block Speedy.
	var speedy: bool = (
		reference in escape.contributors and not bots.is_bot(reference)
		and not escape.arrivals.any(func(arrival): return arrival in escape.contributors and not bots.is_bot(arrival))
	)
	escape.arrivals.append(reference.duplicate())
	if speedy:
		_record_score(handle, {"speedy": 1})


func _finish_evacuation(expired: bool) -> void:
	if score_state.is_empty() or score_state.evacuation.is_empty():
		return
	var escape: Dictionary = score_state.evacuation
	if not escape.active:
		return
	escape.active = false
	# A lone returning contributor wins without a Slowpoke penalty. Keep the
	# full arrival list for Cremated; non-contributors must still evacuate.
	var racers: Array = escape.arrivals.filter(func(arrival): return arrival in escape.contributors and not bots.is_bot(arrival))
	if racers.size() >= 2:
		var last: RefCounted = resolve_player(racers.back())
		if last != null:
			_record_score(last.handle, {"slowpoke": 1})
	if expired:
		for reference: Dictionary in escape.eligible:
			if reference in escape.arrivals:
				continue
			var player: RefCounted = resolve_player(reference)
			if player != null:
				_record_score(player.handle, {"cremated": 1})


func _relay_actor_audio(request: Dictionary) -> void:
	var outgoing := request.duplicate(true)
	if outgoing.has("player_handle"):
		for player: RefCounted in _players:
			if player.handle == int(outgoing.player_handle):
				outgoing.emitter = player.player_ref()
				break
		outgoing.erase("player_handle")
	bots.hear(self,outgoing)
	audio_requested.emit(outgoing)


## Native companions cannot be the sole reason a human party survives/finishes.
func party_players() -> Array:
	if bots.state.rows.is_empty() or not vs_state.is_empty(): return _players
	return _players.filter(func(player): return not bots.is_bot(player.player_ref()))
