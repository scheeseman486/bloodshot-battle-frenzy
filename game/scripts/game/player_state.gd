class_name CdPlayerState
extends RefCounted
## Explicit participant state and per-player source phases.
## The world owns this record; its weak world binding prevents ownership cycles.
signal audio_requested(request: Dictionary)
signal weapon_feedback(feedback: Dictionary)
const AudioRequests = preload("res://scripts/audio/cd_audio_requests.gd")
const Keyboard = preload("res://scripts/input/cd_keyboard_controls.gd")
const Progression = preload("res://scripts/simulation/cd_level_progression.gd")
const Inputs = preload("res://scripts/simulation/cd_input_rules.gd")
const Movement = preload("res://scripts/simulation/cd_movement_rules.gd")
const Collision = preload("res://scripts/simulation/cd_collision_world.gd")
const Latch = preload("res://scripts/simulation/cd_controller_latch.gd")
const Interaction = preload("res://scripts/simulation/cd_interaction_rules.gd")
const Weapons = preload("res://scripts/simulation/cd_weapon_rules.gd")
const PlayerImpulse = preload("res://scripts/simulation/cd_player_impulse.gd")
const ActorVisibility = preload("res://scripts/world/cd_actor_visibility.gd")
const VisibilityQuery = preload("res://scripts/simulation/cd_visibility_query.gd")
const Lifecycle = preload("res://scripts/simulation/cd_player_lifecycle.gd")
const PlayerFlash = preload("res://scripts/simulation/cd_player_flash.gd")
const SpecialWeapon = preload("res://scripts/simulation/cd_special_weapon.gd")
const HudModel = preload("res://scripts/presentation/cd_hud_model.gd")
const HealthDisplay = preload("res://scripts/simulation/cd_health_display.gd")
const StatusOverlay = preload("res://scripts/simulation/cd_status_overlay.gd")
const LevelData = preload("res://scripts/assets/cd_level_decoder.gd")

var _world_ref: WeakRef
var id := 0
var generation := 0
var seat := 0
# Public presentation only; identity keys and score-reclaim records stay on host.
var public_name := ""
# Monotonic compatibility handle; never a reusable seat or transport peer ID.
var handle := 0
var motion: Dictionary
var input_state: Dictionary
var keys: Array = []
var wall_cursor := 0
var latch := Latch.new()
var _collision := Collision.new()
var _motor := preload("res://scripts/game/player_motor.gd").new()
# Transient presentation correlation; never continuation or authoritative rules.
var _weapon_entities: Array = []
var actor_visibility := ActorVisibility.new()
var _sightings: Array = []
var level_stats: Dictionary = {}
var fighter: Dictionary
var weapon_state: Dictionary
var _native_keyboard_controls := false
var _query_remainder := 0
var _door_remainder := 0
var control_scheme := 1
var world_origin := Vector2i.ZERO
# Local controller adapters; these are rebound, never serialized as Callables.
var controls: Callable
var aim_rate: Callable

var world: RefCounted:
	get:
		return _world_ref.get_ref() if _world_ref != null else null

var level: Resource:
	get:
		return world.level

var tables: Resource:
	get:
		return world.tables

var actor_system: RefCounted:
	get:
		return world.actor_system
	set(value):
		world.actor_system = value

var groups: Array:
	get:
		return world.groups
	set(value):
		world.groups = value

var last_events: Array:
	get:
		return world.last_events
	set(value):
		world.last_events = value

var demo_mode: bool:
	get:
		return world.demo_mode
	set(value):
		world.demo_mode = value

var countdown_expired: bool:
	get:
		return world.countdown_expired
	set(value):
		world.countdown_expired = value


func configure(owner_world: RefCounted, player_id: int, incarnation: int, local_seat: int) -> void:
	_world_ref = weakref(owner_world)
	id = player_id
	generation = incarnation
	seat = local_seat
	handle = id - 1
	level_stats = (
		preload("res://scripts/game/coop_score.gd").initial()
		if (
			world.definition.get_meta("session_flow", false)
			and level.source_path.begins_with("/LEVEL")
		)
		else {}
	)
	_collision.level = level
	latch = Latch.new()
	input_state = {
		"forward": 0,
		"turn": 0,
		"strafe": 0,
		"forward_active": 0,
		"turn_active": 0,
		"strafe_active": 0,
		"use_latch": 0,
		"use_duration": 0,
		"strafe_mode": 0,
		"held": 0xffffffff,
		"edge": 0xffffffff
	}
	motion = {
		"state": 1,
		"x": level.spawn.x,
		"y": level.spawn.y,
		"angle": (int(level.spawn_angle) & 255) << 6,
		"forward": 0,
		"turn": 0,
		"strafe": 0,
		"contact_attempt": 0,
		"walk_phase": 0
	}
	keys.clear()
	for index: int in range(9):
		keys.append({"kind": 0, "timer": 0})
	fighter = {
		"state": 1,
		"health": 128,
		"health_copy": 128,
		"health_hit_timer": 0,
		"health_alarm_timer": 0,
		"health_alarm_on": 0,
		"kill_chain": 0,
		"reward_index": 0,
		"reward_timer": 0,
		"lives_previous": 3,
		"lives_timer": 0,
		"checkpoint_x": level.spawn.x,
		"checkpoint_y": level.spawn.y,
		"checkpoint_angle": (int(level.spawn_angle) & 255) << 6,
		"since_hit": 0,
		"lives": 3,
		"death_timer": 0,
		"proxy": -1,
		"map_timer": 0,
		"message_id": 0,
		"message_timer": 0,
		"panel_weapon": -1,
		"panel_phase": 0,
		"panel_phase_timer": 0,
		"flash_busy": 0,
		"flash_active": 0,
		"flash_hold": 0,
		"flash_cursor": 0,
		"flash_callback": 0,
		"flash_word": -1,
		"grace": 0,
		"impulse_x": 0,
		"impulse_y": 0
	}
	var inventory: Array = []
	for index: int in range(18):
		inventory.append({"kind": 0, "ammo": 0, "extra": 0})
	weapon_state = {
		"state": 1,
		"timer": 0,
		"buffered": 0,
		"selected": -1,
		"manual": 0,
		"pattern": 0,
		"special": -1,
		"inventory": inventory
	}
	actor_visibility.session = weakref(self)
	actor_visibility.reset()
	world_origin = level.spawn


func player_ref() -> Dictionary:
	return {"id": id, "generation": generation}


func combat_state() -> Dictionary:
	var result := motion.duplicate()
	result.prev_x = int(motion.get("prev_x", motion.x))
	result.prev_y = int(motion.get("prev_y", motion.y))
	result.merge(fighter, true)
	result.wall_cursor = wall_cursor
	result.keys = keys.duplicate(true)
	result.weapons = weapon_state.duplicate(true)
	return result


func commit_combat(result: Dictionary) -> void:
	_set_contact_position(result)
	wall_cursor = int(result.wall_cursor)
	for field: String in fighter:
		fighter[field] = result[field]
	keys = result.keys
	weapon_state = result.weapons
	weapon_state.state = fighter.state
	motion.state = fighter.state
	motion.forward = result.forward
	input_state.forward = motion.forward


func sample_controls(controls: Variant) -> void:
	if is_game_over() or is_complete():
		return
	var native_keyboard := controls is Dictionary
	_native_keyboard_controls = native_keyboard
	var held: int = int(controls.held) if native_keyboard else int(controls)
	if native_keyboard and not demo_mode:
		select_native_weapon(held)
	var flash := PlayerFlash.advance(fighter, tables.player_flashes)
	fighter = flash.state
	if not flash.writes.is_empty():
		fighter.flash_word = int(flash.writes[-1])
	if int(fighter.get("flash_active", 0)) == 0:
		fighter.flash_word = -1
	var health_display := HealthDisplay.advance(fighter)
	fighter = health_display.state
	for source_id: int in health_display.audio:
		audio_requested.emit({"kind": "sample", "source_id": source_id})
	fighter = StatusOverlay.advance_input(fighter)
	if demo_mode:
		return  # Recorded motor input is applied six times at the world boundary.
	input_state.held = held
	input_state.edge = latch.sample(held)
	input_state = (
		Keyboard.sample(input_state, int(controls.strafe), control_scheme)
		if native_keyboard
		else Inputs.sample(input_state, control_scheme)
	)


func select_native_weapon(held: int) -> void:
	var selection = preload("res://scripts/input/native_weapon_selection.gd")
	var action: int = selection.take(latch, held)
	if action == 0 or demo_mode or int(fighter.state) != 1 or is_game_over() or is_complete():
		return
	var result: Dictionary = selection.apply(weapon_state, action)
	weapon_state = result.state
	last_events.append_array(result.events)
	for event: Dictionary in result.events:
		if event.kind == "weapon_selected":
			fighter = StatusOverlay.selection(fighter, weapon_state)
		elif event.kind == "sound":
			audio_requested.emit({"kind": "sample", "source_id": int(event.source_id)})


func sample_demo_record(held: int, edge: int) -> void:
	assert(demo_mode)
	_native_keyboard_controls = false
	latch.state.held = held
	latch.state.edge = edge
	input_state.held = held
	# $35CCE copies HELD into the first acceleration edge, then applies five
	# more samples with all edges released. The stream's edge is for weapons/use.
	for sample: int in range(6):
		input_state.edge = held if sample == 0 else 0xffffffff
		input_state = Inputs.sample(input_state, control_scheme, true)


func advance_motion(elapsed: int) -> void:
	if is_complete() or is_game_over():
		return
	_collision.fractions = groups.map(func(group: Dictionary) -> int: return int(group.fraction))
	motion.prev_x = motion.x
	motion.prev_y = motion.y
	var phase := (int(motion.angle) >> 6) & 255
	motion = Movement.advance(
		motion,
		elapsed,
		int(tables.sine[phase]),
		int(tables.cosine[phase]),
		_query,
		func(remainder: int) -> void: _collision.axis_remainder = remainder
	)
	_collision.axis_remainder = null
	_advance_impulse(elapsed)


## Called only by the native high-rate driver, never by a presentation callback.
func advance_responsive_motion(samples_per_update: int) -> void:
	if is_complete() or is_game_over():
		return
	_collision.fractions = groups.map(func(group: Dictionary) -> int: return int(group.fraction))
	var result := _motor.advance(
		motion,
		input_state,
		tables,
		samples_per_update,
		_collision,
		wall_cursor,
		actor_system.actors if actor_system != null else [],
		actor_system.catalog if actor_system != null else null,
		int(fighter.proxy),
		actor_system._dynamic_start if actor_system != null else 0
	)
	motion = result.motion
	wall_cursor = int(result.cursor)


func _advance_impulse(elapsed: int) -> void:
	_collision.fractions = groups.map(func(group: Dictionary) -> int: return int(group.fraction))
	if not _native_keyboard_controls and (int(fighter.impulse_x) != 0 or int(fighter.impulse_y) != 0):
		_query_remainder = (int(fighter.impulse_y) * elapsed) & ~65535
		_collision.axis_remainder = _query_remainder
	var advance_impulse := (
		PlayerImpulse.advance_native if _native_keyboard_controls else PlayerImpulse.advance
	)
	var impulse: Dictionary = advance_impulse.call(
		{
			"x": motion.x,
			"y": motion.y,
			"impulse_x": fighter.impulse_x,
			"impulse_y": fighter.impulse_y
		},
		elapsed,
		_query
	)
	motion.x = impulse.x
	motion.y = impulse.y
	fighter.impulse_x = impulse.impulse_x
	fighter.impulse_y = impulse.impulse_y
	_collision.axis_remainder = null


func begin_step(elapsed: int, visibility: Callable = Callable(), move_player: bool = true) -> void:
	assert(elapsed > 0 and elapsed <= 15)
	if is_complete() or is_game_over():
		return
	_query_remainder = 0
	var previous_pose := Vector3i(int(motion.x), int(motion.y), int(motion.angle))
	var previous_map_timer := int(fighter.map_timer)
	_advance_lifecycle(elapsed)
	if int(fighter.state) != 0:
		fighter.since_hit = Lifecycle._word(int(fighter.since_hit) + elapsed)
		if int(fighter.since_hit) < 0:
			fighter.since_hit = 32767
	if actor_system != null and int(fighter.state) != 0:
		var exiting := fighter.duplicate(true)
		exiting.x = motion.x
		exiting.y = motion.y
		exiting = Progression.escape(
			exiting, int(actor_system.encounter.countdown), {"x": level.spawn.x, "y": level.spawn.y}
		)
		if int(fighter.state) != 3 and int(exiting.state) == 3:
			world._record_escape(handle)
		fighter.state = exiting.state
		motion.state = fighter.state
	if int(fighter.state) != 0:
		var controls := latch.consume()
		var player := {
			"x": motion.x,
			"y": motion.y,
			"view_angle": ((int(motion.angle) >> 6) + 64) & 255,
			# E is independent of strafing in the native keyboard adapter, so its
			# press can request use immediately. Integer CD controls keep release gating.
			"held": (int(controls.held) | 64) if _native_keyboard_controls else controls.held
		}
		if int(input_state.use_latch) != 0 and (int(player.held) & 64) != 0:
			audio_requested.emit({"kind": "sample", "source_id": 0x24d64})
		var result := Interaction.request(
			{"use_latch": input_state.use_latch, "keys": keys, "doors": groups},
			player,
			level,
			tables,
			0,
			level.walls.size() - 1,
			visibility
		)
		input_state.use_latch = result.state.use_latch
		keys = result.state.keys
		groups = result.state.doors
		if result.has("query_remainder"):
			_query_remainder = int(result.query_remainder)
		last_events.append_array(result.events)
		for event: Dictionary in result.events:
			if event.kind == "key_missing":
				fighter = StatusOverlay.request(fighter, StatusOverlay.GET_KEY)
				audio_requested.emit({"kind": "sample", "source_id": 0x29bba})
			elif event.kind == "key_consumed":
				if int(event.key) == 3:
					audio_requested.emit({"kind": "sample", "source_id": 0x18700})
				audio_requested.emit({"kind": "sample", "source_id": 0x2a544})
				audio_requested.emit({"kind": "sample", "source_id": 0x2547e})
			elif event.kind == "door_opening":
				audio_requested.emit(AudioRequests.door(0x2572c, level, int(event.group)))
		if actor_system != null:
			actor_system.geometry_remainder = _query_remainder
			_fire(elapsed, controls)
			_query_remainder = actor_system.geometry_remainder
		for key: String in ["forward", "turn", "strafe"]:
			motion[key] = input_state[key]
		if move_player:
			advance_motion(elapsed)
		else:
			# Knockback displacement/decay and its damage-immunity guard retain the
			# source world cadence. Only intentional locomotion moved to the fast clock.
			if int(motion.state) in [1, 3]:
				if int(motion.forward) == 0:
					motion.walk_phase = 0
				elif int(motion.forward) > 0:
					motion.walk_phase = (
						1 if int(motion.walk_phase) >= 8 else int(motion.walk_phase) + 1
					)
				else:
					motion.walk_phase = (
						8 if int(motion.walk_phase) <= 1 else int(motion.walk_phase) - 1
					)
			_advance_impulse(elapsed)
	if int(fighter.state) != 0:
		fighter = StatusOverlay.advance_world(fighter, elapsed)
	var door_remainder := _query_remainder
	if int(fighter.state) != 0 and int(fighter.map_timer) == 0:
		var pose := Vector3i(int(motion.x), int(motion.y), int(motion.angle))
		if previous_map_timer != 0 or pose != previous_pose:
			door_remainder = _map_row_remainder()
	_door_remainder = door_remainder


func _map_row_remainder() -> int:
	# $33676..3368A leaves the map division remainder in the value subsequently
	# used by $3712A for a zero door axis. Preserve that gameplay dependency as
	# arithmetic here; HUD rendering is independent and cannot change collision.
	var bytes: PackedByteArray = level.source_bytes
	if bytes.size() < 36:
		return 0
	var scale := LevelData._s16(bytes, 30)
	if scale == 0:
		return 0
	var row := (int(motion.y) - LevelData._s16(bytes, 28)) & 65535
	return (row % scale) << 16


func _set_contact_position(player: Dictionary) -> void:
	for axis: String in ["x", "y"]:
		if int(motion[axis]) != int(player[axis]):
			motion[axis] = int(player[axis])
			motion[axis + "_sub"] = 0


func _query(target: Vector2i) -> Dictionary:
	var result := _collision.query(target, wall_cursor)
	wall_cursor = int(result.cursor)
	return result


func _fire(elapsed: int, controls: Dictionary) -> void:
	if world.bots.is_bot(player_ref()) and not world.bots.can_fire(world,self):
		controls=controls.duplicate()
		controls.held=int(controls.held)|16
		controls.edge=int(controls.edge)|16
	_weapon_entities.clear()
	actor_system.player_schemes[handle] = control_scheme
	actor_system.bind_player(handle, combat_state())
	weapon_state.state = fighter.state
	var target := {"hit_flag": 64, "hit_target": -1}
	var selected := int(weapon_state.selected)
	if (
		selected >= 0
		and int(weapon_state.inventory[selected].kind) == 2
		and (int(controls.held) & 16) == 0
	):
		target = _weapon_target()
	var special := int(weapon_state.special)
	var special_kind := (
		int(actor_system.actors[special].kind)
		if special >= 0 and special < actor_system.actors.size()
		else 0
	)
	var result := Weapons.advance(
		weapon_state,
		{
			"elapsed": elapsed,
			"held": controls.held,
			"edge": controls.edge,
			"special_kind": special_kind,
			"hit_flag": target.hit_flag,
			"hit_target": target.hit_target,
			"demo": -1 if demo_mode else 0,
			"control_scheme": control_scheme,
			"resolution_mode": 1,
			"multiplayer": int(level.get_meta("battle_mode", false)),
			"active_nonprop":
			actor_system.active.any(
				func(index: int) -> bool: return int(actor_system.actors[index].kind) != 15
			)
		},
		tables,
		_emit_weapon
	)
	var sounds: Array = []
	for event: Dictionary in result.events:
		if event.kind == "sound":
			sounds.append(int(event.source_id))
	if not sounds.is_empty() or not _weapon_entities.is_empty():
		var weapon := int(weapon_state.inventory[selected].kind) if selected >= 0 else 0
		weapon_feedback.emit(
			{
				"player": player_ref(),
				"weapon": weapon,
				"ordinal": world.clock.tick_count,
				"entities": _weapon_entities.duplicate(true),
				"sounds": sounds
			}
		)
	weapon_state = result.state
	if bool(result.get("map_requested", false)):
		fighter.map_timer = 150
	last_events.append_array(result.events)
	for event: Dictionary in result.events:
		if event.kind == "sound":
			audio_requested.emit({"kind": "sample", "source_id": int(event.source_id), "public": true, "cue": "weapon"})
		elif event.kind == "release_special":
			actor_system.release_special(int(event.handle))
		elif event.kind == "inventory_changed":
			fighter = StatusOverlay.selection(fighter, weapon_state, -1, false)
	result = Weapons.cycle(weapon_state, int(controls.edge))
	weapon_state = result.state
	last_events.append_array(result.events)
	for event: Dictionary in result.events:
		if event.kind == "weapon_selected":
			fighter = StatusOverlay.selection(fighter, weapon_state)
		elif event.kind == "sound":
			# Selection feedback is private; prediction does not replay this cue.
			audio_requested.emit({"kind": "sample", "source_id": int(event.source_id)})


func _emit_weapon(request: Dictionary) -> int:
	if request.kind != "projectile" and request.kind != "direct_hit":
		return -1
	var phase := ((int(motion.angle) >> 6) + int(request.get("spread", 0))) & 255
	var direction := Vector2i(int(tables.sine[phase]), int(tables.cosine[phase]))
	if request.kind == "direct_hit":
		direction = SpecialWeapon.aim(
			motion, _lock_on_actor(int(request.target)), actor_system.catalog
		)
	var projectile_slot: int = actor_system.spawn_projectile(
		{
			"x": motion.x,
			"y": motion.y,
			"height": 45,
			"dx": direction.x,
			"dy": direction.y,
			"speed_offset": int(request.get("speed_offset", 0)),
			"owner": -2 - handle,
			"wall_cursor": wall_cursor
		},
		0x3a710 + int(request.get("weapon", 2)) * 22
	)
	if projectile_slot >= 0:
		_weapon_entities.append([projectile_slot, actor_system.entity_generations[projectile_slot]])
		actor_system.actors[projectile_slot].launch_angle = int(motion.angle)
		last_events.append({"kind": "player_fired", "actor": projectile_slot})
	return projectile_slot


## Source candidate order and visibility at the current authoritative pose.
## Mouse aiming remains immediate; this read-only query cannot commit sightings.


func _weapon_target() -> Dictionary:
	var result := {"hit_flag": 64, "hit_target": -1, "hit_offset": 0}
	var player := {
		"x": motion.x, "y": motion.y, "view_angle": ((int(motion.angle) >> 6) + 64) & 255
	}
	var versus: bool = not world.vs_state.is_empty()
	var view: Dictionary = {}
	# Reject ineligible/off-axis points before building source wall visibility.
	# Ascending pool order preserves the original equal-offset tie rule.
	for index: int in range(actor_system.actors.size()):
		var kind := int(actor_system.actors[index].kind)
		if not (kind >= 1 and kind <= 19) and not (versus and kind == 20):
			continue
		var actor := _lock_on_actor(index)
		if actor.is_empty(): continue
		if kind != 20 and int(actor.target) == -1:
			continue
		var offset := SpecialWeapon.projected_offset(player, actor, tables, 80)
		if absi(offset) > int(result.hit_flag):
			continue
		if view.is_empty():
			view = actor_visibility.world_query()
		if not VisibilityQuery.actor(actor, player, tables, actor_system.catalog, view).visible:
			continue
		result.hit_offset = offset
		result = SpecialWeapon.select_candidate(result, offset, index)
	return result


## Native VS proxies represent current participants, not source AI targets.
## Use the live motor position for both acquisition and shot aim; a proxy's
## drawable position may still name the preceding world-update boundary.
func _lock_on_actor(index: int) -> Dictionary:
	if index < 0 or index >= actor_system.actors.size(): return {}
	var actor: Dictionary = actor_system.actors[index]
	if int(actor.kind) != 20: return actor
	if world.vs_state.is_empty(): return {}
	for opponent: RefCounted in world.players:
		if opponent.handle == handle or int(opponent.fighter.state) != 1: continue
		if actor_system.player_proxies.get(opponent.handle, -1) != index: continue
		if actor_system.participant_refs.get(opponent.handle, {}) != opponent.player_ref(): continue
		var current := actor.duplicate()
		current.x = int(opponent.motion.x)
		current.y = int(opponent.motion.y)
		return current
	return {}


## Read-only view of the same current target used by firing. Native play enables
## the CD's existing all-sights artwork as an aiming aid; this is a presentation
## choice, separate from the European checkpoint's flag value 2. No combat tick,
## RNG, target assignment or ammunition is changed by a presentation query.
func weapon_sight(all_sights: bool = true) -> Dictionary:
	var selected := int(weapon_state.selected)
	var weapon := int(weapon_state.inventory[selected].kind) if selected >= 0 else 0
	var target := {"hit_flag": 64, "hit_offset": 0}
	if weapon == 2 and int(fighter.state) == 1:
		target = _weapon_target()
	return HudModel.weapon_sight(
		int(fighter.state),
		weapon,
		1 if all_sights else 2,
		int(target.hit_flag),
		int(target.hit_offset)
	)


func is_complete() -> bool:
	return actor_system != null and int(actor_system.encounter.mode) == 3


func is_game_over() -> bool:
	return actor_system != null and int(actor_system.encounter.mode) == 0


func _advance_lifecycle(elapsed: int) -> void:
	if not world.vs_state.is_empty():
		return  # Native VS uses one independent two-second return schedule.
	# Source view restoration waits for both the palette script and death delay.
	if (
		int(fighter.get("flash_active", 0)) != 0
		and int(fighter.get("flash_busy", 0)) == 0
		and int(fighter.death_timer) == 0
		and int(fighter.lives) != 0
	):
		fighter.flash_active = 0
		fighter.flash_word = -1
	var player := motion.duplicate(true)
	player.merge(fighter, true)
	for field: String in ["use_latch", "use_duration", "strafe_mode"]:
		player[field] = input_state[field]
	player.weapons = weapon_state
	player.keys = keys
	player.wall_cursor = wall_cursor
	var countdown := int(actor_system.encounter.countdown) if actor_system != null else 0
	var result := Lifecycle.advance(player, elapsed, countdown)
	for field: String in fighter:
		fighter[field] = result.state[field]
	motion.state = fighter.state
	if result.respawned:
		for field: String in ["x", "y", "prev_x", "prev_y", "angle", "forward", "turn", "strafe"]:
			motion[field] = result.state[field]
		for field: String in ["x_sub", "y_sub", "angle_sub"]:
			motion[field] = 0
		for field: String in [
			"forward", "turn", "strafe", "use_latch", "use_duration", "strafe_mode"
		]:
			input_state[field] = result.state[field]
		weapon_state = result.state.weapons
		# Original full-HUD restoration refreshes the selected weapon's map card.
		fighter = StatusOverlay.selection(fighter, weapon_state, -1, false)
		wall_cursor = int(result.state.wall_cursor)
		if actor_system != null:
			fighter.proxy = actor_system.restore_player_proxy(handle)
			if actor_system.native_multiplayer and int(fighter.proxy) >= 0:
				actor_system.actors[int(fighter.proxy)].player_colour = seat
		countdown_expired = false
		last_events.append({"kind": "player_respawned"})
	elif result.removed:
		world.player_exhausted(self)
		last_events.append({"kind": "player_exhausted"})
