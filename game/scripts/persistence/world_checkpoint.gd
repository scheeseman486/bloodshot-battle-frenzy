class_name CdWorldCheckpoint
extends RefCounted
## Complete simulation checkpoint. Capture copies a completed revision; restore
## builds a detached candidate, validates it, then publishes in one transaction.
const Codec = preload("res://scripts/persistence/checkpoint_codec.gd")
const Schema = preload("res://scripts/persistence/checkpoint_schema.gd")
const PLAYER_FIELDS := [
	"id",
	"generation",
	"seat",
	"handle",
	"motion",
	"input_state",
	"fighter",
	"weapon_state",
	"keys",
	"wall_cursor",
	"_sightings",
	"_native_keyboard_controls",
	"_query_remainder",
	"_door_remainder",
	"control_scheme",
	"world_origin"
]
const SYSTEM_FIELDS := [
	"actors",
	"active",
	"movement_seed",
	"attack_seed",
	"geometry_remainder",
	"control_scheme",
	"demo_mode",
	"boss_clock",
	"boss_centre",
	"encounter",
	"_update",
	"_dynamic_start",
	"epoch",
	"entity_generations",
	"player_contexts",
	"_player_order",
	"player_proxies",
	"participant_refs",
	"player_schemes",
	"legacy_single_player",
	"_current_player",
	"_last_player_state",
	"projectile_owners",
	"projectile_launches",
	"_projectile_generation"
]
const WORLD_FIELDS := [
	"groups",
	"blocked_doors",
	"update_count",
	"countdown_expired",
	"palette_state",
	"demo_mode",
	"demo_actions",
	"demo_state",
	"stop_when_exhausted",
	"_next_player_id",
	"_seat_generations",
	"_initial_proxy_claimed",
	"campaign_state",
	"presentation_state",
	"event_sequence",
	"pending_events",
	"pending_commands",
	"accepted_controls",
	"admission_state"
]
var last_error := ""


func capture(world: RefCounted) -> PackedByteArray:
	last_error = ""
	if world.definition == null or world.actor_system == null:
		last_error = "Original CD world must be configured before capture"
		return PackedByteArray()
	if world._atomic_depth != 0 or not world.vs_pending.damaged.is_empty() or not world.vs_pending.kills.is_empty():
		last_error = "Checkpoint capture requires a completed simulation boundary"
		return PackedByteArray()
	var state := describe(world)
	var schema := Schema.new()
	if not schema.validate(state, world.definition):
		last_error = schema.last_error
		return PackedByteArray()
	var codec := Codec.new()
	var bytes := codec.encode(state)
	last_error = codec.last_error
	return bytes


func describe(world: RefCounted) -> Dictionary:
	var profile: Resource = world.timing_profile
	var result := {
		"manifest":
		{
			"edition": "European Mega CD",
			"rules": "europe-cd-native-six-responsive-v1",
			"shell": world.tables.source_sha256,
			"level": (-int(world.level.source_path.trim_prefix("/ARENA").trim_suffix(".LEV"))
				if world.level.get_meta("battle_mode", false)
				else int(world.level.source_path.trim_prefix("/LEVEL").trim_suffix(".LEV"))),
			"level_sha256": world.level.source_sha256
		},
		"timing":
		{
			"profile": profile.profile_id,
			"numerator": profile.input_numerator,
			"denominator": profile.input_denominator,
			"samples": profile.samples_per_update,
			"multiplier": world.clock._numerator / int(profile.input_numerator),
			"ordinal": world.clock.tick_count,
			"phase": world.clock._phase
		},
		"world": _fields(world, WORLD_FIELDS),
		"players": [],
		"system": _fields(world.actor_system, SYSTEM_FIELDS),
		"system_collision": _collision(world.actor_system._collision),
		"last_context_bound":
		is_same(
			world.actor_system._last_player_state,
			world.actor_system.player_contexts.get(world.actor_system._current_player)
		),
	}
	if world.music_restart_delay > 0:
		result.world.music_restart_delay = world.music_restart_delay
	if not world.loot_state.is_empty():
		result.world.loot_state = world.loot_state.duplicate(true)
	if not world.score_state.is_empty():
		result.world.score_state = world.score_state.duplicate(true)
	if not world.vs_state.is_empty():
		result.world.vs_state = world.vs_state.duplicate(true)
	if not world.bots.state.rows.is_empty() or world.bots.state.difficulty!=1:
		result.world.bots = world.bots.state.duplicate(true)
	for player: RefCounted in world.players:
		var row := _fields(player, PLAYER_FIELDS)
		if not player.level_stats.is_empty():
			row.level_stats = player.level_stats.duplicate(true)
		row.latch = player.latch.state.duplicate(true)
		row.visibility = player.actor_visibility._previous.duplicate(true)
		row.collision = _collision(player._collision)
		var context: Dictionary = world.actor_system.player_contexts.get(player.handle, {})
		row.keys_bound = is_same(player.keys, context.get("keys"))
		row.weapons_bound = is_same(player.weapon_state, context.get("weapons"))
		result.players.append(row)
	return result


func restore(world: RefCounted, bytes: PackedByteArray, source: RefCounted = null) -> bool:
	last_error = ""
	if world._atomic_depth != 0:
		last_error = "Checkpoint restore requires a completed simulation boundary"
		return false
	var codec := Codec.new()
	var state := codec.decode(bytes)
	if not codec.last_error.is_empty():
		last_error = codec.last_error
		return false
	# Explicit schema-1 migration: historical checkpoints predate timestamped
	# event admission. No queued semantic work is inferred from device state.
	if codec.last_schema == 1 and state.get("world") is Dictionary:
		if state.world.has("admission_state"):
			last_error = "Schema 1 cannot declare timestamped admission state"
			return false
		state.world.admission_state = preload("res://scripts/game/input_admission.gd").initial()
	var schema := Schema.new()
	if not schema.validate_envelope(state):
		last_error = schema.last_error
		return false
	var definition: RefCounted = world.definition
	if definition == null or definition.level.source_sha256 != state.manifest.level_sha256:
		if source == null:
			last_error = "Original CD definitions/source required for checkpoint level"
			return false
		definition = preload("res://scripts/game/world_definition.gd").new()
		var loaded: bool = (definition.load_map(source, "arena-%d" % -int(state.manifest.level))
			if int(state.manifest.level) < 0 else definition.load_from_source(source, int(state.manifest.level)))
		if not loaded:
			last_error = "Cannot reload original CD definitions: " + source.last_error
			return false
	if not schema.validate(state, definition):
		last_error = schema.last_error
		return false
	var demo_recording: Dictionary = world.demo_recording
	if not state.world.demo_state.is_empty():
		if (
			demo_recording.is_empty()
			or demo_recording.get("pointer") != state.world.demo_state.get("pointer")
		):
			if source == null:
				last_error = "Original CD source required to rebind recorded demo"
				return false
			var frontend: RefCounted = source.load_cd_frontend_catalog()
			if frontend == null:
				last_error = "Cannot reload original demo recording"
				return false
			demo_recording = frontend.demo(2)
		if (
			demo_recording.pointer != state.world.demo_state.pointer
			or state.world.demo_state.reader.cursor > demo_recording.records.size()
			or state.world.demo_state.action_cursor > demo_recording.actions.size()
		):
			last_error = "Demo continuation does not match original recording"
			return false
	if not state.world.get("score_state", {}).is_empty() or not state.world.get("loot_state", {}).is_empty():
		# Rebind native session policy from the optional portable record without
		# mutating an existing world's shared immutable definition object.
		var scored_definition := preload("res://scripts/game/world_definition.gd").new()
		scored_definition.configure(definition.level, definition.tables, definition.catalog)
		scored_definition.set_meta("session_flow", true)
		definition = scored_definition
	var candidate: RefCounted = load("res://scripts/game/world_state.gd").new()
	candidate.timing_profile = preload("res://scripts/simulation/cd_timing_profile.gd").new()
	candidate.timing_profile.profile_id = state.timing.profile
	candidate.timing_profile.samples_per_update = int(state.timing.samples)
	candidate.configure_definition(definition)
	candidate.demo_recording = demo_recording
	var new_epoch: int = candidate.actor_system.epoch
	_set_fields(candidate, state.world, WORLD_FIELDS)
	candidate.music_restart_delay = int(state.world.get("music_restart_delay",0))
	candidate.score_state = state.world.get("score_state", {}).duplicate(true)
	candidate.vs_state = state.world.get("vs_state", {}).duplicate(true)
	if state.world.has("bots"): candidate.bots.state=state.world.bots.duplicate(true)
	candidate.loot_state = state.world.get("loot_state", candidate.loot_state).duplicate(true)
	_set_fields(candidate.actor_system, state.system, SYSTEM_FIELDS)
	# Native scoring exclusion is derived from portable campaign provenance,
	# including when research/server callers restore without a campaign scene.
	candidate.actor_system.scoring_disabled = (
		candidate.stop_when_exhausted and not candidate.demo_mode
		and not candidate.actor_system.native_multiplayer
		and bool(candidate.campaign_state.get("cheats_ever_enabled",candidate.campaign_state.get("cheated",false)))
	)
	if candidate.actor_system.scoring_disabled:
		candidate.actor_system.encounter.damage_total = 0
	candidate.actor_system.epoch = new_epoch
	for owner: Dictionary in candidate.actor_system.projectile_owners.values():
		if (
			owner.get("tag") == "actor"
			and owner.has("reference")
			and not owner.reference.is_empty()
		):
			owner.reference.epoch = new_epoch
	if state.last_context_bound:
		candidate.actor_system._last_player_state = candidate.actor_system.player_contexts[
			candidate.actor_system._current_player
		]
	_apply_collision(candidate.actor_system._collision, state.system_collision)
	for row: Dictionary in state.players:
		var player := preload("res://scripts/game/player_state.gd").new()
		player.configure(candidate, int(row.id), int(row.generation), int(row.seat))
		_set_fields(player, row, PLAYER_FIELDS)
		if candidate.actor_system.native_multiplayer and int(player.fighter.proxy) >= 0:
			# Historical native saves predate cosmetic metadata. Live assignments
			# follow seats; unmarked historical corpses retain original red.
			candidate.actor_system.actors[int(player.fighter.proxy)].player_colour = player.seat
		player.level_stats = row.get("level_stats", {}).duplicate(true)
		player.latch.state = row.latch.duplicate(true)
		player.actor_visibility.reset(row.visibility)
		_apply_collision(player._collision, row.collision)
		var context: Dictionary = candidate.actor_system.player_contexts.get(player.handle, {})
		if row.keys_bound:
			player.keys = context.keys
		if row.weapons_bound:
			player.weapon_state = context.weapons
		candidate._players.append(player)
	candidate.clock.configure_ratio(
		int(state.timing.numerator) * int(state.timing.multiplier), int(state.timing.denominator)
	)
	candidate.clock.tick_count = int(state.timing.ordinal)
	candidate.clock._phase = int(state.timing.phase)
	# Publish only fully validated state. Rebind weak/callable owners; no rule or
	# audio callback runs while constructing or installing a checkpoint.
	world._adopt_checkpoint(candidate)
	return true


func digest(world: RefCounted, replicated: bool = false) -> String:
	var data := describe(world)
	data.system.epoch = 0
	for owner: Dictionary in data.system.projectile_owners.values():
		if owner.get("tag") == "actor" and owner.has("reference"):
			owner.reference.epoch = 0
	if replicated:
		var schema := Schema.new()
		var actors: Array = []
		for actor: Dictionary in data.system.actors:
			var visible := {}
			for key: String in actor:
				if schema.records.actor.fields[key].get("replication", "public") != "server_only":
					visible[key] = actor[key]
			actors.append(visible)
		data = {
			"manifest": data.manifest,
			"ordinal": data.timing.ordinal,
			"actors": actors,
			"generations": data.system.entity_generations,
			"doors": data.world.groups,
			"encounter": data.system.encounter,
			"palette": data.world.palette_state,
			"players": data.players.map(_public_player)
		}
	else:
		# Rendering/audio reattachment has its own continuity tests and is not AI
		# authority. Event watermarks and durable pending events stay authoritative.
		data.world.erase("presentation_state")
		data.system.erase("projectile_launches")
		data.system.erase("_projectile_generation")
	return Codec.new().canonical_hash(data)


func _fields(object: Object, fields: Array) -> Dictionary:
	var result := {}
	for key: String in fields:
		var value: Variant = object.get(key)
		result[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	return result


func _set_fields(object: Object, data: Dictionary, fields: Array) -> void:
	for key: String in fields:
		var value: Variant = data[key]
		object.set(key, value.duplicate(true) if value is Array or value is Dictionary else value)


func _collision(collision: RefCounted) -> Dictionary:
	return {
		"fractions": collision.fractions.duplicate(), "axis_remainder": collision.axis_remainder
	}


func _apply_collision(collision: RefCounted, data: Dictionary) -> void:
	collision.fractions = data.fractions.duplicate()
	collision.axis_remainder = data.axis_remainder


func _public_player(row: Dictionary) -> Dictionary:
	return {
		"id": row.id,
		"generation": row.generation,
		"pose":
		{
			"x": row.motion.x,
			"y": row.motion.y,
			"angle": row.motion.angle,
			"x_sub": row.motion.get("x_sub", 0),
			"y_sub": row.motion.get("y_sub", 0),
			"angle_sub": row.motion.get("angle_sub", 0)
		},
		"state": row.fighter.state,
		"health": row.fighter.health,
		"proxy": row.fighter.proxy
	}
