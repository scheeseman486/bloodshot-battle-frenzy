class_name CdGameplaySession
extends RefCounted
## Transitional single-player adapter over the explicit world/player services.
## Existing scenes and source replays use the same rules as multi-player worlds.
signal audio_requested(request: Dictionary)
const World = preload("res://scripts/game/world_state.gd")
const Player = preload("res://scripts/game/player_state.gd")
var world := World.new()
var player := Player.new()

var level: Resource:
	get:
		return world.level

var tables: Resource:
	get:
		return world.tables

var groups: Array:
	get:
		return world.groups
	set(value):
		world.groups = value

var blocked_doors: Array:
	get:
		return world.blocked_doors
	set(value):
		world.blocked_doors = value

var update_count: int:
	get:
		return world.update_count
	set(value):
		world.update_count = value

var last_events: Array:
	get:
		return world.last_events
	set(value):
		world.last_events = value

var actor_system: RefCounted:
	get:
		return world.actor_system
	set(value):
		world.actor_system = value

var countdown_expired: bool:
	get:
		return world.countdown_expired
	set(value):
		world.countdown_expired = value

var palette_state: Dictionary:
	get:
		return world.palette_state
	set(value):
		world.palette_state = value

var demo_mode: bool:
	get:
		return world.demo_mode
	set(value):
		world.demo_mode = value

var demo_actions: Array:
	get:
		return world.demo_actions
	set(value):
		world.demo_actions = value

var motion: Dictionary:
	get:
		return player.motion
	set(value):
		player.motion = value

var input_state: Dictionary:
	get:
		return player.input_state
	set(value):
		player.input_state = value

var keys: Array:
	get:
		return player.keys
	set(value):
		player.keys = value

var wall_cursor: int:
	get:
		return player.wall_cursor
	set(value):
		player.wall_cursor = value

var latch: RefCounted:
	get:
		return player.latch
	set(value):
		player.latch = value

var _collision: RefCounted:
	get:
		return player._collision
	set(value):
		player._collision = value

var actor_visibility: RefCounted:
	get:
		return player.actor_visibility
	set(value):
		player.actor_visibility = value

var _sightings: Array:
	get:
		return player._sightings
	set(value):
		player._sightings = value

var fighter: Dictionary:
	get:
		return player.fighter
	set(value):
		player.fighter = value

var weapon_state: Dictionary:
	get:
		return player.weapon_state
	set(value):
		player.weapon_state = value

var _native_keyboard_controls: bool:
	get:
		return player._native_keyboard_controls
	set(value):
		player._native_keyboard_controls = value

var _query_remainder: int:
	get:
		return player._query_remainder
	set(value):
		player._query_remainder = value

var control_scheme: int:
	get:
		return player.control_scheme
	set(value):
		player.control_scheme = value


func _init() -> void:
	# Source input tests can exercise a recorded acceleration window before a
	# level is mounted. This binds only the adapter record, never an avatar.
	player._world_ref = weakref(world)


func configure(
	original_level: Resource, original_tables: Resource, original_actors: Resource = null
) -> void:
	var scheme := control_scheme
	var recorded := demo_mode
	world = World.new()
	world.demo_mode = recorded
	world.stop_when_exhausted = true
	world.configure(original_level, original_tables, original_actors)
	world.audio_requested.connect(audio_requested.emit)
	var reference := world.spawn_player(0)
	assert(not reference.is_empty(), "The original single-player proxy must fit the source pool")
	player = world.get_player(reference)
	player.control_scheme = scheme
	if actor_system != null:
		actor_system.legacy_single_player = true
		actor_system.control_scheme = scheme
		actor_system.demo_mode = recorded


func sample_controls(controls: Variant) -> void:
	world.sample_controls({player.id: controls})


func bind_driver_clock(clock: RefCounted, profile: Resource) -> void:
	world.bind_driver_clock(clock, profile)


func sync_world_origin(origin: Vector2i) -> void:
	player.world_origin = origin


func step(elapsed: int, visibility: Callable = Callable(), move_player: bool = true) -> void:
	world.step(elapsed, {player.id: visibility}, move_player)


func is_complete() -> bool:
	return world.is_complete()


func is_game_over() -> bool:
	return world.is_game_over()


func sample_demo_record(held: int, edge: int) -> void:
	player.sample_demo_record(held, edge)


func advance_motion(elapsed: int) -> void:
	player.advance_motion(elapsed)


func advance_responsive_motion(samples_per_update: int) -> void:
	player.advance_responsive_motion(samples_per_update)


func weapon_sight(all_sights: bool = true) -> Dictionary:
	return player.weapon_sight(all_sights)


func _fire(elapsed: int, controls: Dictionary) -> void:
	player._fire(elapsed, controls)


func _query(target: Vector2i) -> Dictionary:
	return player._query(target)


func _weapon_target() -> Dictionary:
	return player._weapon_target()


func _advance_lifecycle(elapsed: int) -> void:
	player._advance_lifecycle(elapsed)


func capture_checkpoint() -> PackedByteArray:
	return world.capture_checkpoint()


func restore_checkpoint(bytes: PackedByteArray, source: RefCounted = null) -> bool:
	if world._atomic_depth != 0:
		world.last_checkpoint_error = "Checkpoint restore requires a completed simulation boundary"
		return false
	# Validate in an independent authority before changing facade bindings.
	var candidate := World.new()
	candidate.definition = world.definition
	if not candidate.restore_checkpoint(bytes, source):
		world.last_checkpoint_error = candidate.last_checkpoint_error
		return false
	if candidate.players.size() != 1:
		world.last_checkpoint_error = "Single-player scene requires one checkpoint participant"
		return false
	world._adopt_checkpoint(candidate)
	player = world.players[0]
	return true


func continuation_digest() -> String:
	return world.continuation_digest()


func begin_atomic() -> void:
	world._atomic_depth += 1
	world._apply_pending_commands(world.clock.tick_count)


func end_atomic() -> void:
	world._atomic_depth -= 1
