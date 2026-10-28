class_name CdActorSystem
extends RefCounted
## Ascending source-pool actor order. Pure state owns animation/awareness/chase
## and shared RNG; scene nodes only present it. No render-frame callbacks here.
signal audio_requested(request: Dictionary)
# Accounting observers never choose damage, rewards, animation or RNG outcomes.
signal combat_scored(handle: int, increments: Dictionary)
## Native competitive accounting observes committed lethal player damage only.
signal opponent_killed(shooter: int, victim: int)
signal item_collected(slot: int)
signal player_lethal(victim: int, shooter: int)
signal participant_died(handle: int, context: Dictionary)
signal mine_stepped(handle: int)
signal meltdown_started
const AudioRequests = preload("res://scripts/audio/cd_audio_requests.gd")
const Awareness = preload("res://scripts/simulation/cd_enemy_awareness.gd")
const AttackClock = preload("res://scripts/simulation/cd_enemy_attack_clock.gd")
const Chase = preload("res://scripts/simulation/cd_enemy_chase.gd")
const ActorAnimation = preload("res://scripts/simulation/cd_actor_animation.gd")
const Aim = preload("res://scripts/simulation/cd_enemy_aim.gd")
const Impulse = preload("res://scripts/simulation/cd_enemy_impulse.gd")
const BossOrbit = preload("res://scripts/simulation/cd_boss_orbit.gd")
const ItemPickup = preload("res://scripts/simulation/cd_item_pickup.gd")
const KeyPickup = preload("res://scripts/simulation/cd_key_pickup.gd")
const ProximityMine = preload("res://scripts/simulation/cd_proximity_mine.gd")
const Pool = preload("res://scripts/simulation/cd_actor_pool.gd")
const ProjectileFactory = preload("res://scripts/simulation/cd_projectile_factory.gd")
const ProjectileFlight = preload("res://scripts/simulation/cd_projectile_flight.gd")
const CoreDamage = preload("res://scripts/simulation/cd_core_damage.gd")
const StagedDamage = preload("res://scripts/simulation/cd_staged_enemy_damage.gd")
const BodyContact = preload("res://scripts/simulation/cd_player_body_contact.gd")
const SpecialWeapon = preload("res://scripts/simulation/cd_special_weapon.gd")
const KillReward = preload("res://scripts/simulation/cd_kill_reward.gd")
const CombatCheckpoint = preload("res://scripts/simulation/cd_combat_checkpoint.gd")
const Damage = preload("res://scripts/simulation/cd_combat_damage.gd")
const Collision = preload("res://scripts/simulation/cd_collision_world.gd")
const StatusOverlay = preload("res://scripts/simulation/cd_status_overlay.gd")
# Rebuilt from native companion metadata; never changes original pickup rules.
var weapon_only_collectors: Array = []

var catalog: Resource
# Original zero-axis wall queries depend on the previous arithmetic remainder.
# Track only that semantic dependency; drawing and hardware registers are absent.
var geometry_remainder := 0
var control_scheme := 1
var demo_mode := false
# Derived from the authority definition, never from a client's requested mode.
var native_multiplayer := false
# Rebuilt by the application authority; original/reference sessions leave this off.
var native_swept_hits := false
var actors: Array = []
var active: Array = []
var movement_seed := 0x39ea017f
var attack_seed := 0xe8732f10
var events: Array = []
# Native presentation metadata, separate from source actor state and RNG. Kept
# per pool slot so drawing can read snapshots without consuming simulation events.
var projectile_launches: Dictionary = {}
var _projectile_generation := 0
var _collision := Collision.new()
var _dynamic_start: int
var _tables: Resource
var boss_clock: Dictionary
var boss_centre: Vector2i
# Shared mutable encounter values; catalog.theme remains immutable source data.
var encounter: Dictionary = {}
# Source remaining counts kind-19 terminals; satellites use the separate gate.
var remaining_bosses: int:
	get:
		return int(encounter.get("remaining", 0))
	set(value):
		encounter.remaining = value
var attack_gate: int:
	get:
		return int(encounter.get("gate", 0))
	set(value):
		encounter.gate = value
var player_contexts: Dictionary = {}
var _player_order: Array = []
var player_proxies: Dictionary = {}
var participant_refs: Dictionary = {}
var player_schemes: Dictionary = {}
var legacy_single_player := false
var _current_player := 0
var _last_player_state: Dictionary = {}
var epoch := 1
var entity_generations: Array = []
var projectile_owners: Dictionary = {}
var player_state: Dictionary:
	get:
		return _last_player_state
	set(value):
		_last_player_state = value
		if not value.is_empty():
			player_contexts[_current_player] = value
			if not _player_order.has(_current_player):
				_player_order.append(_current_player)
# Legacy tests/presenters bind the source single-player proxy through this view.
var _proxy_id: int:
	get:
		return int(player_proxies.get(_current_player, -1))
	set(value):
		player_proxies[_current_player] = value
var _update := 0
# Derived native single-player policy; reconstructed from campaign save history.
var scoring_disabled := false


func configure(
	level: Resource, original_catalog: Resource, original_tables: Resource, with_player: bool = true
) -> void:
	catalog = original_catalog
	legacy_single_player = with_player
	_tables = original_tables
	boss_clock = {"clock": 0, "radius": 0, "speed": int(catalog.theme.radial_speed)}
	encounter = {
		"gate": 0,
		"remaining": 0,
		"angular_speed": int(catalog.theme.angular_speed),
		"satellite_rate": int(catalog.theme.satellite_rate),
		"countdown": 0,
		"countdown_boundary": 0,
		"exit_delay": 0,
		"mode": 2,
		"kills": 0,
		"bonuses": 0,
		"damage_total": 0
	}
	attack_gate = int(catalog.theme.satellites)
	remaining_bosses = 0
	for placement: Dictionary in level.placements:
		if int(placement.template_offset) == 0xde:
			remaining_bosses += 1
	for actor: Dictionary in catalog.actors:
		if int(actor.kind) == 4:
			boss_centre = Vector2i(int(actor.x), int(actor.y))
	actors = catalog.actors.duplicate(true)
	player_contexts.clear()
	_player_order.clear()
	player_proxies.clear()
	participant_refs.clear()
	player_schemes.clear()
	projectile_owners.clear()
	_last_player_state = {}
	_current_player = 0
	entity_generations.resize(actors.size())
	entity_generations.fill(1)
	if with_player:
		add_player_proxy(
			0,
			{"x": level.spawn.x, "y": level.spawn.y, "angle": (int(level.spawn_angle) & 255) << 6},
			true
		)
	_update = 0
	active.clear()
	events.clear()
	projectile_launches.clear()
	_projectile_generation = 0
	movement_seed = 0x39ea017f
	attack_seed = 0xe8732f10
	_collision.level = level
	_dynamic_start = int(level.dynamic_start)


func advance(player: Dictionary, elapsed: int, groups: Array, sightings: Array) -> void:
	# Source replay adapter; the shared actor traversal is identical for N players.
	advance_players({0: player}, elapsed, groups, {0: sightings})


func bind_player(handle: int, state: Dictionary = {}) -> void:
	if not state.is_empty():
		player_contexts[handle] = state
	assert(player_contexts.has(handle), "An actor helper requires an explicit player context")
	_current_player = handle
	_last_player_state = player_contexts[handle]


func advance_players(
	contexts: Dictionary, elapsed: int, groups: Array, sightings: Dictionary
) -> void:
	assert(catalog != null)
	_collision.fractions = groups.map(func(group: Dictionary) -> int: return int(group.fraction))
	events.clear()
	player_contexts = contexts.duplicate(true)
	_player_order = contexts.keys()
	# Dictionary insertion order is the world's stable SEAT order. Handles may be
	# sparse after departures and are never reused for a replacement participant.
	for handle: int in _player_order:
		for index: int in sightings.get(handle, []):
			if (
				index >= 0
				and index < actors.size()
				and int(actors[index].kind) >= 1
				and int(actors[index].kind) <= 19
			):
				actors[index].seen = handle
	_update = (_update + 1) & 65535
	var index := _dynamic_start
	while index < actors.size():
		_advance_actor(index, elapsed, groups)
		index += 1
	var orbit_theme: Dictionary = catalog.theme.duplicate()
	orbit_theme.angular_speed = encounter.angular_speed
	boss_clock = BossOrbit.advance(boss_clock, elapsed, remaining_bosses, orbit_theme)
	for handle: int in _player_order:
		bind_player(handle)
		_update_player_proxy()


func add_player_proxy(handle: int, state: Dictionary, append_initial: bool = false) -> int:
	if player_proxies.has(handle) and int(player_proxies[handle]) >= 0:
		return -1
	var slot := -1
	if append_initial:
		# The initial offline proxy reserves the original trailing slot even if an
		# earlier actor record is empty. Later respawns use first-empty allocation.
		if actors.size() < 180:
			slot = actors.size()
			actors.append(_empty_actor())
			_birth(slot)
	else:
		slot = _allocate()
	if slot < 0:
		return -1
	var proxy: Dictionary = actors[slot]
	proxy.kind = 20
	proxy.local_player = handle == 0
	proxy.x = state.x
	proxy.y = state.y
	proxy.height = 128
	var direction := posmod(-int(state.get("angle", 0)) + 2048, 16384) >> 12
	proxy.frame = int(_tables.player_proxy_frames[36 + direction])
	player_proxies[handle] = slot
	return slot


func remove_player_context(handle: int) -> void:
	exhaust_player_proxy(handle)
	player_proxies.erase(handle)
	player_contexts.erase(handle)
	participant_refs.erase(handle)
	player_schemes.erase(handle)
	_player_order.erase(handle)
	for index: int in range(actors.size()):
		var actor: Dictionary = actors[index]
		if int(actor.get("target", -1)) == handle:
			actor.target = -1
			active.erase(index)
		if int(actor.get("seen", -1)) == handle:
			actor.seen = -1
	# Retain the last context only as continuation/presentation history. No rule
	# may use it without binding a currently registered participant first.


func exhaust_player_proxy(handle: int) -> void:
	var slot := int(player_proxies.get(handle, -1))
	if slot >= 0 and slot < actors.size() and int(actors[slot].kind) == 20:
		actors[slot] = ProjectileFlight.clear(actors[slot])
	player_proxies[handle] = -1


func _allocate() -> int:
	var slot := Pool.allocate(actors, _empty_actor)
	if slot >= 0:
		_birth(slot)
	return slot


func _birth(slot: int) -> void:
	while entity_generations.size() <= slot:
		entity_generations.append(0)
	entity_generations[slot] = int(entity_generations[slot]) + 1
	if int(entity_generations[slot]) > 0xffffffff:
		epoch = ResourceUID.create_id()
		entity_generations.fill(1)
	projectile_owners.erase(slot)
	# A reused source slot must never inherit a previous human's appearance.
	actors[slot].erase("player_colour")


func entity_ref(slot: int) -> Dictionary:
	if slot < 0 or slot >= actors.size() or int(actors[slot].kind) == 0:
		return {}
	while entity_generations.size() <= slot:
		entity_generations.append(1)  # Explicit legacy replay seeds can materialize slots.
	return {"epoch": epoch, "slot": slot, "generation": entity_generations[slot]}


func resolve_entity(reference: Dictionary) -> Variant:
	if not reference.has_all(["epoch", "slot", "generation"]):
		return null
	if not reference.epoch is int or not reference.slot is int or not reference.generation is int:
		return null
	if reference.epoch != epoch:
		return null
	var slot := int(reference.slot)
	if (
		slot < 0
		or slot >= actors.size()
		or slot >= entity_generations.size()
		or int(actors[slot].kind) == 0
	):
		return null
	return actors[slot] if int(entity_generations[slot]) == int(reference.generation) else null


func apply_demo_actions(commands: Array) -> void:
	const Playback = preload("res://scripts/frontend/cd_demo_playback.gd")
	for command: Dictionary in commands:
		var index := int(command.actor)
		if index < 0 or index >= actors.size():
			continue
		if command.kind == "remove" and not active.has(index):
			# Native normalized scheduling can remove a shot victim before the
			# recorded cleanup. Do not corrupt the live list or invent a respawn.
			continue
		var actor: Dictionary = actors[index]
		var result := Playback.action(
			{"active": active, "target": actor.target, "lost": actor.lost},
			command.kind,
			index,
			int(command.target)
		)
		active = result.active
		actor.target = int(result.target)
		actor.lost = int(result.lost)
		if command.kind == "activate" and int(actor.parameter) != 0:
			_sound(int(catalog.parameters[int(actor.parameter)].audio_activation), actor)


## Death detaches the current proxy and leaves the source corpse animation in
## its existing pool slot. A later respawn allocates independently; no map reset.
func player_died(handle: int = -1) -> void:
	var selected := _current_player if handle < 0 else handle
	var slot := int(player_proxies.get(selected, -1))
	if slot < 0:
		if native_multiplayer:
			participant_died.emit(selected, player_contexts.get(selected, {}))
		return
	var corpse: Dictionary = actors[slot].duplicate(true)
	corpse.kind = 23
	corpse.local_player = false
	actors[slot] = ActorAnimation.select(corpse, 0x30592, catalog).state
	player_proxies[selected] = -1
	combat_scored.emit(selected, {"deaths": 1, "campaign_deaths": 1})
	participant_died.emit(selected, player_contexts.get(selected, {}))


func restore_player_proxy(handle: int = -1) -> int:
	var selected := _current_player if handle < 0 else handle
	var slot := int(player_proxies.get(selected, -1))
	if slot < 0:
		slot = _allocate()
		if slot >= 0:
			actors[slot].kind = 20
			actors[slot].local_player = selected == 0
		player_proxies[selected] = slot
	return slot


func _update_player_proxy() -> void:
	if _proxy_id < 0 or int(player_state.get("state", 0)) == 0:
		return
	var proxy: Dictionary = actors[_proxy_id]
	proxy.x = player_state.x
	proxy.y = player_state.y
	proxy.height = 128
	var row := (
		9
		if int(player_state.get("since_hit", 0)) <= 25
		else clampi(int(player_state.get("walk_phase", 0)), 0, 8)
	)
	var direction := posmod(-int(player_state.get("angle", 0)) + 2048, 16384) >> 12
	proxy.frame = int(_tables.player_proxy_frames[row * 4 + direction])


func _advance_actor(index: int, elapsed: int, groups: Array) -> void:
	var actor: Dictionary = actors[index]
	if int(actor.kind) == 0 or index < _dynamic_start:
		return  # Static prefix is rendered but not dispatched by $03988E.
	if int(actor.timer) != 0:
		actor.timer = _word(int(actor.timer) - elapsed)
		if int(actor.timer) <= 0:
			actor = _animate(actor, int(actor.cursor) + 4)
			actors[index] = actor
			if int(actor.kind) == 0:
				return
	if int(actor.kind) >= 1 and int(actor.kind) <= 22:
		for handle: int in _player_order:
			bind_player(handle)
			if int(player_state.get("state", 0)) != 1:
				continue
			player_state = BodyContact.resolve(
				player_state,
				{"id": index, "kind": actor.kind, "x": actor.x, "y": actor.y},
				_proxy_id,
				catalog,
				_query_player_contact,
				func(remainder: int) -> void:
					geometry_remainder = remainder
					_collision.axis_remainder = remainder
			)
			_collision.axis_remainder = null
	if (int(actor.kind) >= 29 and int(actor.kind) <= 38) or int(actor.kind) in [43, 44, 45]:
		for handle: int in _player_order:
			bind_player(handle)
			_collect_item(index)
		return
	if int(actor.kind) >= 40 and int(actor.kind) <= 42:
		for handle: int in _player_order:
			bind_player(handle)
			_collect_key(index)
		return
	if int(actor.kind) == 46:
		_advance_mine(index)
		return
	if int(actor.kind) == 48:
		_advance_explosion(index)
		return
	if int(actor.kind) >= 24 and int(actor.kind) <= 28:
		_advance_projectile(index, elapsed, groups)
		return
	if int(actor.kind) < 1 or int(actor.kind) > 19:
		return
	if int(actor.target) >= 0 and not player_contexts.has(int(actor.target)):
		actor.target = -1
		active.erase(index)
	if int(actor.seen) >= 0 and not player_contexts.has(int(actor.seen)):
		actor.seen = -1
	var grace := {}
	for handle: int in _player_order:
		grace[handle] = int(player_contexts[handle].get("grace", 0))
	var awareness := Awareness.advance(
		{"target": actor.target, "seen": actor.seen, "lost": actor.lost},
		index,
		active,
		grace,
		elapsed,
		demo_mode
	)
	active = awareness.active
	events.append_array(awareness.events)
	for event: Dictionary in awareness.events:
		if event.kind == "enemy_activated":
			_sound(int(catalog.parameters[int(actor.parameter)].audio_activation), actor)
	actor.merge(awareness.state, true)
	if not awareness.proceed or int(actor.kind) == 15 or int(actor.kind) == 19:
		return
	bind_player(int(actor.target))
	var params: Dictionary = catalog.parameters[int(actor.parameter)]
	var distance := _word(
		(
			absi(_word(int(player_state.x) - int(actor.x)))
			+ absi(_word(int(player_state.y) - int(actor.y)))
		)
	)
	if (
		int(actor.kind) != 4
		and int(actor.kind) != 17
		and (int(actor.impulse_x) != 0 or int(actor.impulse_y) != 0)
	):
		var state := {
			"x": actor.x,
			"y": actor.y,
			"counter": actor.counter,
			"impulse_x": actor.impulse_x,
			"impulse_y": actor.impulse_y
		}
		var moved := Impulse.advance(
			state,
			elapsed,
			func(target: Vector2i) -> Dictionary: return _query(actor, params, target),
			func(remainder: int) -> void:
				geometry_remainder = remainder
				_collision.axis_remainder = remainder
		)
		_collision.axis_remainder = null
		actor.merge(moved, true)
		return
	if int(actor.kind) == 17:
		if remaining_bosses != 0:
			return
		actor.merge(
			BossOrbit.position(
				int(actor.phase),
				int(boss_clock.clock),
				int(boss_clock.radius),
				boss_centre,
				_tables
			),
			true
		)
	elif int(actor.kind) != 4:
		var fields := {
			"x": actor.x,
			"y": actor.y,
			"aim_x": actor.aim_x,
			"aim_y": actor.aim_y,
			"charge": actor.charge,
			"cooldown": actor.cooldown
		}
		var chase := Chase.advance(
			fields,
			params,
			player_state,
			distance,
			elapsed,
			movement_seed,
			catalog,
			func(target: Vector2i) -> Dictionary: return _query(actor, params, target),
			func(remainder: int) -> void:
				geometry_remainder = remainder
				_collision.axis_remainder = remainder
		)
		_collision.axis_remainder = null
		movement_seed = int(chase.seed)
		actor.merge(chase.state, true)
		for animation: int in chase.animations:
			actor = _animate(actor, animation)
		actors[index] = actor
	if int(actor.frame) == 0x5293c and remaining_bosses == 0:
		_checkpoint_all()
		actor = _animate(actor, 0x3041a)
		actors[index] = actor
	var scale := int(params.rate)
	if int(actor.kind) == 4:
		scale = int(catalog.theme.boss_rate)
	elif int(actor.kind) == 17:
		scale = int(encounter.satellite_rate)
	var attack := AttackClock.advance(
		int(actor.counter), int(actor.kind), distance, scale, elapsed, attack_gate
	)
	actor.counter = int(attack.counter)
	if attack.attempt:
		var aim := Aim.request(actor, player_state, distance, attack_seed, params, catalog)
		attack_seed = int(aim.seed)
		events.append(
			{
				"kind": "enemy_attack_requested",
				"actor": index,
				"x": actor.x,
				"y": actor.y,
				"aim": aim
			}
		)
		_sound(int(_tables.projectile_weapons[int(aim.weapon)].sound_id), actor)
		spawn_projectile(
			{
				"x": actor.x,
				"y": actor.y,
				"height": aim.height,
				"dx": aim.dx,
				"dy": aim.dy,
				"speed_offset": 0,
				"owner": index,
				"wall_cursor": actor.wall_cursor
			},
			int(aim.weapon)
		)


func _query_player_contact(target: Vector2i) -> Dictionary:
	return _collision.query(target, int(player_state.get("wall_cursor", 0)))


func _query(actor: Dictionary, params: Dictionary, target: Vector2i) -> Dictionary:
	var contact := _collision.query(target, int(actor.wall_cursor), int(params.radius))
	actor.wall_cursor = int(contact.cursor)
	return contact


func _animate(actor: Dictionary, request: int) -> Dictionary:
	return ActorAnimation.select(actor, request, catalog).state


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768


func spawn_projectile(arguments: Dictionary, weapon: int) -> int:
	assert(_tables.projectile_weapons.has(weapon), "Unknown original projectile parameters")
	var index := _allocate()
	if index < 0:
		return -1
	var targeting := 0
	var owner_handle := -2 - int(arguments.owner)
	for actor_id: int in active:
		if int(arguments.owner) <= -2 and int(actors[actor_id].target) == owner_handle:
			targeting += 1
	var pure_arguments := arguments.duplicate()
	if int(arguments.owner) <= -4:
		pure_arguments.owner = -2  # Original helper recognizes its two source sentinels.
	actors[index] = ProjectileFactory.create(
		actors[index],
		pure_arguments,
		_tables.projectile_weapons[weapon],
		{
			"demo_flag": -1 if demo_mode else 0,
			"control_scheme": _scheme_for(owner_handle),
			"resolution": 1,
			"multiplayer": int(_collision.level.get_meta("battle_mode", false)),
			"targeting_owner": targeting
		}
	)
	actors[index].owner = arguments.owner
	if int(arguments.owner) <= -2:
		projectile_owners[index] = {
			"tag": "player", "reference": participant_refs.get(owner_handle, {}).duplicate()
		}
	elif int(arguments.owner) >= 0:
		projectile_owners[index] = {"tag": "actor", "reference": entity_ref(int(arguments.owner))}
	var speed := _word(int(arguments.speed_offset) + int(_tables.projectile_weapons[weapon].speed))
	var product := int(arguments.dy) * speed
	@warning_ignore("integer_division")
	geometry_remainder = (product - (product / 16384) * 16384) << 16
	_record_launch(index)
	return index


func _record_launch(index: int) -> void:
	if not projectile_owners.has(index):
		_record_owner(index)
	_projectile_generation += 1
	projectile_launches[index] = {
		"generation": _projectile_generation,
		"kind": actors[index].kind,
		"x": actors[index].x,
		"y": actors[index].y,
		"height": actors[index].height,
		"flight_started": false
	}


## Release reuses the live shot and clones it in first-empty source pool order.
## Existing fragments survive exhaustion; the original launch heading is retained.
func release_special(index: int) -> void:
	if index < 0 or index >= actors.size() or int(actors[index].kind) != 24:
		return
	var clones: Array = []
	for attempt: int in range(6):
		var clone_id := _allocate()
		if clone_id < 0:
			break
		actors[clone_id] = actors[index].duplicate(true)
		clones.append(clone_id)
	var projectile: Dictionary = actors[index].duplicate(true)
	projectile.launch_angle = int(projectile.get("launch_angle", 0))
	var result := SpecialWeapon.split(
		projectile, clones, _tables, func(remainder: int) -> void: geometry_remainder = remainder
	)
	actors[index] = result.state
	_record_launch(index)
	for item: Dictionary in result.created:
		actors[int(item.id)] = item.state
		if projectile_owners.has(index):
			projectile_owners[int(item.id)] = projectile_owners[index].duplicate(true)
		_record_launch(int(item.id))
	for sound: int in result.audio:
		_sound(sound, projectile)
	events.append({"kind": "special_released", "actor": index, "fragments": clones.size() + 1})


func _advance_projectile(index: int, elapsed: int, groups: Array) -> void:
	var projectile: Dictionary = actors[index]
	var targets: Array = []
	for actor_id: int in active:
		var actor: Dictionary = actors[actor_id]
		targets.append(
			{
				"id": actor_id,
				"kind": actor.kind,
				"x": actor.x,
				"y": actor.y,
				"radius": catalog.parameters[int(actor.parameter)].hit_radius
			}
		)
	var players: Array = []
	for handle: int in _player_order:
		var player: Dictionary = player_contexts[handle]
		players.append({"id": -2 - handle, "state": player.state, "x": player.x, "y": player.y})
	var result := ProjectileFlight.advance(
		projectile,
		elapsed,
		_collision.level,
		groups.map(func(group: Dictionary) -> int: return int(group.fraction)),
		players,
		targets,
		func(target: int) -> Dictionary:
			var impact := _impact(projectile, target, index)
			for at: int in range(targets.size() - 1, -1, -1):
				if not active.has(int(targets[at].id)):
					targets.remove_at(at)
			return impact,
		catalog,
		geometry_remainder,
		native_swept_hits
	)
	actors[index] = result.state
	if int(projectile.kind) in [27, 28] and int(result.state.kind) == 48:
		_sound(0x10d18, result.state)
	elif int(projectile.kind) == 25 and int(result.wall) >= 0 and int(result.state.kind) == 25:
		_sound(0x10122, result.state)
	if projectile_launches.has(index):
		# Presentation observes actual dispatch, not displacement: a processed
		# stationary shot is different from a slot not yet visited by the loop.
		projectile_launches[index].flight_started = true
	if int(result.wall) >= 0:
		events.append({"kind": "projectile_hit_wall", "wall": result.wall})


func _impact(projectile: Dictionary, target: int, projectile_slot: int = -1) -> Dictionary:
	var response: Dictionary = {}
	if target <= -2:
		var handle := -2 - target
		if not player_contexts.has(handle):
			return response
		bind_player(handle)
		if native_multiplayer and (int(player_state.state) != 1 or int(projectile.owner) == target):
			return response
		var owner: Variant = null
		var params: Dictionary = {}
		var owner_id := int(projectile.owner)
		if (
			owner_id >= 0
			and owner_id < actors.size()
			and (
				projectile_slot < 0
				or not projectile_owners.has(projectile_slot)
				or resolve_entity(projectile_owners[projectile_slot].reference) != null
			)
			and int(actors[owner_id].kind) >= 1
			and int(actors[owner_id].kind) <= 19
		):
			owner = {
				"id": owner_id,
				"parameter": actors[owner_id].parameter,
				"counter": actors[owner_id].counter,
				"lost": actors[owner_id].lost
			}
			params = catalog.parameters[int(owner.parameter)]
		var pure_projectile := projectile.duplicate()
		if int(projectile.owner) <= -4:
			pure_projectile.owner = -2
		var player_hit := Damage.player_impact(
			player_state,
			pure_projectile,
			owner,
			params,
			{
				"demo_flag": -1 if demo_mode else 0,
				"control_scheme": _scheme_for(handle),
				"multiplayer": int(
					_collision.level.get_meta("battle_mode", false)
					or (native_multiplayer and _collision.level.source_path != "/NATIVE/LOBBY")
				)
			},
			catalog
		)
		for sound: int in AudioRequests.player(player_state, player_hit.state):
			_player_sound(sound)
		var was_dead := int(player_state.state) == 2
		if not was_dead and owner_id > -2:
			var direction := Chase.normalize_direction(
				int(projectile.vx), int(projectile.vy), catalog
			)
			geometry_remainder = _word(direction.y * _word(int(projectile.damage) * 6)) << 16
			# $037306..$03730C subtracts the original unsigned projectile
			# damage from the packed campaign tally, before difficulty scaling.
			encounter.damage_total = (
				(int(encounter.damage_total) - (int(projectile.damage) & 65535)) & 0xffffffff
			)
		_score_player_damage(handle, player_state, player_hit.state, projectile, projectile_slot)
		player_state = player_hit.state
		if not was_dead and int(player_state.state) == 2:
			player_died()
		if player_hit.owner != null:
			actors[owner_id].counter = player_hit.owner.counter
			actors[owner_id].lost = player_hit.owner.lost
		events.append({"kind": "player_damaged", "health": player_state.health})
		return response
	var actor: Dictionary = actors[target]
	var guarded := (
		(int(actor.kind) == 4 and attack_gate != 0)
		or (
			int(actor.kind) in [5, 6]
			and int(actor.cursor) >= 0x303a2
			and int(actor.cursor) < 0x303c6
			and int(projectile.kind) != 26
		)
	)
	if int(actor.kind) not in [15, 19] and not guarded:
		geometry_remainder = Chase.direction_remainder(int(projectile.vx), int(projectile.vy))
		# $2F8EC normalizes D4/D5 without restoring the projectile's lookahead
		# point. A piercing shot resumes $3A2A8 with that direction for later
		# candidates; its actual position remains unchanged.
		response.ahead = Chase.normalize_direction(int(projectile.vx), int(projectile.vy), catalog)
	if int(actor.kind) == 15:
		_prop_checkpoint(projectile)
	var clone_id := -1
	if (
		int(actor.kind) in [15, 19]
		or (int(actor.kind) in [11, 12] and int(actor.health) <= int(projectile.damage))
		or (
			int(actor.kind) == 4
			and attack_gate == 0
			and int(actor.health) <= int(projectile.damage)
		)
	):
		clone_id = _allocate()
	if int(actor.kind) in [4, 17, 19]:
		var core_result := CoreDamage.impact(
			actor, projectile, _damage_context(target, clone_id), catalog
		)
		for sound: int in AudioRequests.impact(
			actor, projectile, core_result, attack_gate, catalog
		):
			_sound(sound, actor)
		_score_enemy(actor, core_result.state, projectile, projectile_slot)
		_combat_side_effects(actor, core_result.state, int(projectile.damage), false)
		for field: String in ["kills", "bonuses", "damage_total"]:
			core_result.globals[field] = encounter[field]
		_apply_core_damage(target, core_result)
		return response
	var result: Dictionary
	if int(actor.kind) in [11, 12]:
		result = StagedDamage.impact(actor, projectile, _damage_context(target, clone_id), catalog)
	else:
		result = Damage.enemy_impact(
			actor,
			projectile,
			catalog.parameters[int(actor.parameter)],
			active,
			target,
			attack_gate,
			_update,
			catalog,
			clone_id
		)
	for sound: int in AudioRequests.impact(actor, projectile, result, attack_gate, catalog):
		_sound(sound, actor)
	_score_enemy(actor, result.state, projectile, projectile_slot)
	_combat_side_effects(actor, result.state, int(projectile.damage), false)
	actors[target] = result.state
	active = result.active
	for created: Dictionary in result.created:
		actors[int(created.id)] = created.state
	events.append({"kind": "enemy_damaged", "actor": target, "health": result.state.health})
	return response


## $02F778 and $02FA66..$02FAFC: direct damage counter and qualifying kills.
## The reward belongs to the defeated actor's target, not an arbitrary shooter.
func _combat_side_effects(before: Dictionary, after: Dictionary, damage: int, area: bool) -> void:
	var kind := int(before.kind)
	if kind == 15:
		return  # The prop helper bypasses ordinary health on direct and area paths.
	if not area:
		if kind in [15, 19] or (kind == 4 and attack_gate != 0):
			return
		if kind in [5, 6] and int(before.health) == int(after.health):
			return
		if not scoring_disabled:
			encounter.damage_total = (int(encounter.get("damage_total", 0)) + damage) & 0xffffffff
	if kind == 4 or int(after.health) != 0 or int(after.kind) == kind:
		return
	encounter.kills = _word(int(encounter.get("kills", 0)) + 1)
	if native_multiplayer and _collision.level.get_meta("battle_mode", false):
		return  # Native competitive rewards come only from confirmed opponents.
	if area or kind in [14, 17] or not player_contexts.has(int(before.target)):
		return
	if int(before.target) in weapon_only_collectors:
		# Native companions keep normal combat accounting, without source streak
		# gifts (including keys), healing, ammo, lives or bonus score/audio.
		player_contexts[int(before.target)].kill_chain = 0
		player_contexts[int(before.target)].reward_timer = 0
		return
	bind_player(int(before.target))
	if not player_state.has("weapons"):
		return
	player_state.reward_index = int(player_state.get("reward_index", 0))
	player_state.reward_timer = int(player_state.get("reward_timer", 0))
	var reward := KillReward.apply(player_state, player_state.weapons, encounter, _tables)
	player_state = reward.player
	player_state.weapons = reward.weapons
	encounter = reward.globals
	for sound: int in reward.audio:
		_player_sound(sound)
	events.append(
		{"kind": "kill_reward", "chain": player_state.kill_chain, "next": player_state.reward_index}
	)


func _empty_actor() -> Dictionary:
	var result: Dictionary = catalog._actor(0, 0, Vector2i.ZERO, 0)
	result.merge({"vx": 0, "vy": 0, "damage": 0, "age": 0, "gravity": 0, "owner": -1}, true)
	return result


func _advance_explosion(index: int) -> void:
	var effect: Dictionary = actors[index]
	for handle: int in _player_order:
		bind_player(handle)
		var before := int(player_state.health)
		var player_before := player_state.duplicate(true)
		player_state = Damage.area_player(
			player_state,
			effect,
			int(_collision.level.get_meta("battle_mode", false)),
			catalog,
			_area_query_remainder
		)
		_score_player_damage(handle, player_before, player_state, effect, index)
		if int(player_before.state) != 2 and int(player_state.state) == 2:
			player_died()
		for sound: int in AudioRequests.player(player_before, player_state):
			_player_sound(sound)
		if int(player_state.health) != before:
			events.append({"kind": "player_damaged", "health": player_state.health})
	var origin := {"x": effect.x, "y": effect.y}
	var owner_handle := -2 - int(effect.get("owner", -1))
	if int(effect.get("owner", -1)) <= -2 and player_contexts.has(owner_handle):
		origin = {"x": player_contexts[owner_handle].x, "y": player_contexts[owner_handle].y}
	var cursor := 0
	while cursor < active.size():
		var target := int(active[cursor])
		var actor: Dictionary = actors[target]
		var clone_id := -1
		if int(actor.kind) == 15 and Damage._near_effect(actor, effect, 180):
			_prop_checkpoint(effect)
		if (
			int(actor.kind) == 15
			and absi(int(actor.x) - int(effect.x)) <= 180
			and absi(int(actor.y) - int(effect.y)) <= 180
		):
			clone_id = _allocate()
		if (
			int(actor.kind) in [11, 12]
			and int(actor.health) <= 70
			and Damage._near_effect(actor, effect, 180)
			and int(actor.impulse_x) == 0
			and int(actor.impulse_y) == 0
		):
			clone_id = _allocate()
		if int(actor.kind) in [4, 17, 19]:
			if (
				int(actor.kind) == 4
				and int(actor.health) <= 70
				and Damage._near_effect(actor, effect, 180)
				and int(actor.impulse_x) == 0
				and int(actor.impulse_y) == 0
			):
				clone_id = _allocate()
			var core_result := CoreDamage.area(
				actor,
				effect,
				origin,
				_damage_context(target, clone_id),
				catalog,
				_area_query_remainder
			)
			for sound: int in AudioRequests.impact(
				actor, effect, core_result, attack_gate, catalog, true
			):
				_sound(sound, actor)
			_score_enemy(actor, core_result.state, effect, index)
			_combat_side_effects(actor, core_result.state, 70, true)
			for field: String in ["kills", "bonuses", "damage_total"]:
				core_result.globals[field] = encounter[field]
			_apply_core_damage(target, core_result)
			cursor += 1
			continue
		var result: Dictionary
		if int(actor.kind) in [11, 12]:
			result = StagedDamage.area(
				actor,
				effect,
				origin,
				_damage_context(target, clone_id),
				catalog,
				_area_query_remainder
			)
		else:
			result = Damage.area_enemy(
				actor,
				effect,
				origin,
				catalog.parameters[int(actor.parameter)],
				active,
				target,
				attack_gate,
				catalog,
				clone_id,
				_area_query_remainder
			)
		for sound: int in AudioRequests.impact(actor, effect, result, attack_gate, catalog, true):
			_sound(sound, actor)
		_score_enemy(actor, result.state, effect, index)
		_combat_side_effects(actor, result.state, 70, true)
		actors[target] = result.state
		active = result.active
		for created: Dictionary in result.created:
			actors[int(created.id)] = created.state
		cursor += 1


func _area_query_remainder(remainder: int) -> void:
	# $039D82/$039E98 multiply and SWAP the normalized Y impulse. Later
	# moving-wall queries retain this high word when their X delta is zero.
	geometry_remainder = remainder


func _advance_mine(index: int) -> void:
	var targets: Array = []
	for actor_id: int in active:
		var actor: Dictionary = actors[actor_id]
		targets.append({"id": actor_id, "x": actor.x, "y": actor.y})
	var mine_players: Array = []
	for handle: int in _player_order:
		var player: Dictionary = player_contexts[handle]
		mine_players.append({"state": player.get("state", 0), "x": player.x, "y": player.y})
	var result := ProximityMine.advance(actors[index], mine_players, targets, catalog)
	actors[index] = result.state
	if not result.triggers.is_empty():
		_sound(0x10d18, actors[index])
		var triggers: Array = []
		for trigger: int in result.triggers:
			if trigger <= -2:
				var handle := int(_player_order[-2 - trigger])
				bind_player(handle)
				player_state = StatusOverlay.request(player_state, StatusOverlay.MINE)
				mine_stepped.emit(handle)
				triggers.append(-2 - handle)
			else:
				triggers.append(trigger)
		events.append({"kind": "mine_triggered", "actor": index, "targets": triggers})


func _damage_context(actor: int, clone_id: int) -> Dictionary:
	return {
		"globals": encounter,
		"gate": attack_gate,
		"active": active,
		"actor": actor,
		"clone_id": clone_id,
		"update": _update,
		"seconds": _collision.level.countdown_seconds
	}


func _apply_core_damage(target: int, result: Dictionary) -> void:
	var previous_gate := attack_gate
	var before: Dictionary = actors[target]
	var kind := int(before.kind)
	encounter = result.globals
	actors[target] = result.state
	active = result.active
	for created: Dictionary in result.created:
		actors[int(created.id)] = created.state
	if kind == 4 and int(result.state.kind) != 4:
		meltdown_started.emit()
		_checkpoint_all()
		audio_requested.emit(
			{
				"kind": "music_seek",
				"track": 6 if int(_collision.level.countdown_seconds) == 90 else 5
			}
		)
		events.append({"kind": "core_destroyed", "actor": target})
	elif kind == 17 and int(result.state.kind) != 17:
		# $2FAAE is shared by direct and splash health paths. Availability of
		# this sample on a weapon does not replace the final-satellite cue.
		if previous_gate > 0 and attack_gate == 0:
			var cue := AudioRequests.sample(0x12aa4, before)
			cue.cue = "core_unlock"
			audio_requested.emit(cue)
		events.append({"kind": "satellite_destroyed", "actor": target, "remaining": attack_gate})
	elif kind == 4 and attack_gate != 0 and int(result.state.health) == int(before.health):
		events.append({"kind": "core_shielded", "actor": target, "remaining": attack_gate})
	if int(result.state.health) != int(before.health) or int(result.state.kind) != kind:
		events.append({"kind": "enemy_damaged", "actor": target, "health": result.state.health})


func _checkpoint_all() -> void:
	for handle: int in _player_order:
		var player: Dictionary = player_contexts[handle]
		player.checkpoint_x = player.x
		player.checkpoint_y = player.y
		player.checkpoint_angle = int(player.get("angle", 0))


func _prop_checkpoint(effect: Dictionary) -> void:
	var owner := int(effect.get("owner", -1))
	var handle := -2 - owner
	if owner > -2 or not player_contexts.has(handle):
		return
	bind_player(handle)
	var kinds := active.map(func(index: int) -> int: return int(actors[index].kind))
	player_state = (
		CombatCheckpoint
		. prop(
			[player_state],
			-2,
			int(_collision.level.get_meta("battle_mode", false)),
			_collision.level,
			_collision.fractions,
			kinds
		)[0]
	)


func _sound(source_id: int, origin: Dictionary) -> void:
	if source_id >= 0:
		audio_requested.emit(AudioRequests.sample(source_id, origin))


func _player_sound(source_id: int) -> void:
	# Context is already bound to the victim, collector or rewarded participant.
	# World relay fills the lifetime-safe player reference without mutating state.
	if source_id >= 0:
		var request := AudioRequests.sample(source_id, player_state)
		request.player_handle = _current_player
		audio_requested.emit(request)


func _collect_item(index: int) -> void:
	if native_multiplayer and int(player_state.get("state", 0)) != 1:
		return
	var actor: Dictionary = actors[index]
	if _current_player in weapon_only_collectors and int(actor.kind) not in range(29, 39):
		return
	if not ((int(actor.kind) >= 29 and int(actor.kind) <= 38) or int(actor.kind) in [43, 44, 45]):
		return
	if player_state.has("weapons"):
		var pickup := ItemPickup.collect(
			actor,
			player_state,
			player_state.weapons,
			int(_collision.level.get_meta("battle_mode", false))
		)
		actors[index] = pickup.actor
		player_state = pickup.player
		player_state.weapons = pickup.weapons
		if pickup.collected:
			item_collected.emit(index)
			if int(actor.kind) == 45:
				_player_sound(0x2547e)
				_player_sound(0x1f72a)
			else:
				_player_sound(0x21272 if int(actor.kind) == 43 else 0x17c8c)
			if int(actor.kind) <= 38:
				_player_sound(0x2547e)
			var category := (
				"weapon"
				if int(actor.kind) <= 38
				else (
					"health"
					if int(actor.kind) == 43
					else "life" if int(actor.kind) == 45 else "ammo"
				)
			)
			events.append(
				{"kind": "item_collected", "category": category, "source_kind": actor.kind}
			)


func _collect_key(index: int) -> void:
	if _current_player in weapon_only_collectors: return
	if native_multiplayer and int(player_state.get("state", 0)) != 1:
		return
	var actor: Dictionary = actors[index]
	if int(actor.kind) < 40 or int(actor.kind) > 42:
		return
	if player_state.has("keys"):
		if native_multiplayer and player_state.keys.all(func(key): return int(key.kind) != 0):
			return  # Native shared objectives cannot disappear into a full inventory.
		var pickup := KeyPickup.collect(actor, player_state, player_state.keys)
		actors[index] = pickup.actor
		player_state.keys = pickup.keys
		if int(pickup.slot) >= 0:
			_player_sound(0x21c9a)
			_player_sound(0x2547e)
			events.append(
				{"kind": "key_collected", "key": int(actor.kind) - 39, "slot": pickup.slot}
			)


func _scheme_for(handle: int) -> int:
	return (
		control_scheme if legacy_single_player else int(player_schemes.get(handle, control_scheme))
	)


func _record_owner(slot: int) -> void:
	var owner := int(actors[slot].get("owner", -1))
	if owner <= -2:
		projectile_owners[slot] = {
			"tag": "player", "reference": participant_refs.get(-2 - owner, {}).duplicate()
		}
	elif owner >= 0:
		projectile_owners[slot] = {"tag": "actor", "reference": entity_ref(owner)}
	else:
		projectile_owners[slot] = {"tag": "none"}


func owner_ref(entity: Dictionary) -> Dictionary:
	if resolve_entity(entity) == null:
		return {}
	return projectile_owners.get(int(entity.slot), {}).duplicate(true)


func _score_enemy(before: Dictionary, after: Dictionary, projectile: Dictionary, slot: int) -> void:
	# Props/terminals are objectives rather than renewable score sources.
	if (
		int(before.kind) < 1
		or int(before.kind) > 19
		or int(before.kind) in [15, 19]
		or int(before.health) <= 0
	):
		return
	var handle := -2 - int(projectile.get("owner", -1))
	if handle < 0 or not participant_refs.has(handle):
		return  # Environmental/enemy damage and departed owners earn no credit.
	if projectile_owners.has(slot):
		var owner: Dictionary = projectile_owners[slot]
		if owner.get("tag") != "player" or owner.get("reference", {}) != participant_refs[handle]:
			return
	var damage := maxi(0, int(before.health) - maxi(0, int(after.health)))
	var killed := int(after.health) == 0 and int(before.kind) != int(after.kind)
	if damage > 0 or killed:
		combat_scored.emit(
			handle,
			{
				"damage": damage,
				"kills": 1 if killed else 0,
				"reactor": damage if int(before.kind) == 4 else 0
			}
		)


func _score_player_damage(
	handle: int, before: Dictionary, after: Dictionary, projectile: Dictionary, slot: int
) -> void:
	var taken := maxi(0, int(before.health) - maxi(0, int(after.health)))
	if taken == 0:
		return
	combat_scored.emit(handle, {"taken": taken})
	var shooter := -2 - int(projectile.get("owner", -1))
	if int(before.state) == 1 and int(after.state) == 2:
		var valid_owner := participant_refs.has(shooter)
		if projectile_owners.has(slot):
			var recorded: Dictionary = projectile_owners[slot]
			valid_owner = valid_owner and recorded.get("tag") == "player" and recorded.get("reference", {}) == participant_refs.get(shooter, {})
		player_lethal.emit(handle, shooter if valid_owner else -1)
	if shooter < 0 or shooter == handle or not participant_refs.has(shooter):
		return
	if projectile_owners.has(slot):
		var owner: Dictionary = projectile_owners[slot]
		if owner.get("tag") != "player" or owner.get("reference", {}) != participant_refs[shooter]:
			return
	combat_scored.emit(shooter, {"friendly": taken})
	if (
		_collision.level.get_meta("battle_mode", false)
		and int(before.state) == 1
		and int(after.state) == 2
	):
		opponent_killed.emit(shooter, handle)
