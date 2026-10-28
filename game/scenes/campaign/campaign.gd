extends Node3D
## Stage 1 interactive player/door/actor slice. Uses original runtime data and pure
## combat rules on the normalized source clock, with responsive native movement.
const DisplaySettings = preload("res://scripts/presentation/cd_display_settings.gd")
const FrontendSettings = preload("res://scripts/frontend/cd_frontend_settings.gd")
const PauseRules = preload("res://scripts/frontend/cd_pause_rules.gd")
const CardRules = preload("res://scripts/frontend/cd_campaign_card_rules.gd")
const InputSettings = preload("res://scripts/input/cd_input_settings.gd")
const NativeControls = preload("res://scripts/input/cd_native_controls.gd")
const Pickups = preload("res://scripts/simulation/cd_item_pickup.gd")
const Progression = preload("res://scripts/simulation/cd_level_progression.gd")
const Driver = preload("res://scripts/game/offline_driver.gd")
const Visibility = preload("res://scripts/world/cd_interaction_visibility.gd")
const Presentation = preload("res://scripts/presentation/cd_replica_presentation.gd")
var server := preload("res://scripts/game/game_server.gd").new()
var client: RefCounted
# Debug/source harness compatibility only. HUD and rendering consume client.session.
var session: RefCounted:
	get:
		return server.session
var driver: RefCounted = Driver.new()
var visibility := Visibility.new()
var level_number: int:
	get:
		return server.campaign.level_number
	set(value):
		server.campaign.level_number = value
var _transition_pending: bool:
	get:
		return server.campaign._transition_pending
	set(value):
		server.campaign._transition_pending = value
var ready_to_play := false
var paused: bool:
	get:
		return server.campaign.paused
	set(value):
		server.campaign.paused = value
var _previous_usec: int
var actor_catalog: Resource
var presentation := Presentation.new()
var door_motion := preload("res://scripts/presentation/cd_door_motion_presentation.gd").new()
var actor_animations := (
	preload("res://scripts/presentation/cd_sprite_animation_presentation.gd").new()
)
# Horizontal aiming only: the source combat plane has no vertical aim.
@export_range(0.01, 1.0) var mouse_degrees_per_pixel := 0.12
var _previous_accumulation := true
var _previous_mouse_mode := Input.MOUSE_MODE_VISIBLE
var _resume_capture := false
# Quantized local look waits for the next frame/button boundary. Raw reports
# update heading only; they never run combat, visibility or replica publication.
var _pending_mouse_aim := 0
var _game_over_presented: bool:
	get:
		return server.campaign._game_over_presented
	set(value):
		server.campaign._game_over_presented = value
var _campaign_transition: Control
var _transition_carry: Dictionary:
	get:
		return server.campaign._transition_carry
	set(value):
		server.campaign._transition_carry = value
var continue_credits: int:
	get:
		return server.campaign.continue_credits
	set(value):
		server.campaign.continue_credits = value
var score_eligible: bool:
	get:
		return server.campaign.score_eligible
	set(value):
		server.campaign.score_eligible = value
var cheated: bool:
	get:
		return server.campaign.cheated
	set(value):
		server.campaign.cheated = value
var _pause_view: Control
var _pause_history: Array = [0, 0, 0, 0, 0, 0]
var input_settings := InputSettings.new(
	"user://controls.json", int(FrontendSettings.values().diagonals)
)
var native_controls := NativeControls.new()
var _pause_input_event: InputEvent
# Restored accepted latch windows survive the first user-facing resume.
var _checkpoint_resume := false


func is_single_player_campaign() -> bool:
	# The scene alone is insufficient: recorded demos and one-seat online
	# authorities must never inherit a selectable campaign cheat boundary.
	return (
		ready_to_play
		and session.world.stop_when_exhausted
		and not session.world.demo_mode
		and driver.recording.is_empty()
		and session.world.players.size() == 1
		and session.world.vs_state.is_empty()
		and not session.actor_system.native_multiplayer
	)


func sync_cheat_policy() -> void:
	if not is_single_player_campaign():
		return
	if preload("res://scripts/frontend/cd_cheat_settings.gd").enabled():
		server.campaign.disable_scoring_for_cheats()
	server.sync_score_policy()


func apply_menu_cheat(callback: int) -> bool:
	var rules = preload("res://scripts/frontend/cd_pause_rules.gd")
	if (
		not is_single_player_campaign()
		or not paused
		or not is_instance_valid(_pause_view)
		or not _pause_view.accepts_controls
		or _pause_view._done
		or not preload("res://scripts/frontend/cd_cheat_settings.gd").enabled()
	):
		return false
	if (
		callback not in [0x30a12, 0x30a46, 0x30a5e, 0x30a8a, 0x30a96, 0x30aa6]
		and not rules.WEAPON_CALLBACKS.has(callback)
	):
		return false
	sync_cheat_policy()
	var state: Dictionary = rules.apply(_pause_state(), callback)
	_commit_pause_state(state)
	for sound: int in state.audio:
		_pause_view.get_node("Audio").play_source(sound)
	server.refresh_views(true)
	if callback == 0x30a12:
		# Source skip bypasses completion cards and caps at a reload of level 16.
		var carry: Dictionary = preload("res://scripts/simulation/cd_campaign_carry.gd").capture(session)
		_pause_view._done = true
		_pause_view.accepts_controls = false
		_transition_pending = true
		load_level.call_deferred(int(state.level), carry)
	else:
		_updated()
	return true


func _ready() -> void:
	# Attract playback subclasses this scene with its own recorded-input driver.
	if driver.recording.is_empty():
		native_controls.configure(input_settings.values)
		mouse_degrees_per_pixel = float(input_settings.values.mouse_degrees_per_pixel)
		native_controls.devices_changed(Input.get_connected_joypads())
		Input.joy_connection_changed.connect(_joy_connection_changed)
		driver.aim_rate = _aim_rate
	_previous_accumulation = Input.use_accumulated_input
	_previous_mouse_mode = Input.mouse_mode
	$Overlay/Panel/Content/DisplayOptions.widescreen_changed.connect(set_widescreen)
	$OriginalHud/Hud.layout_changed.connect(_refresh_projection)
	$OriginalHud/Hud.set_widescreen(DisplaySettings.widescreen())
	$Overlay/Panel/Content/Menu.pressed.connect(
		func() -> void: get_tree().change_scene_to_file("res://scenes/main_menu/main_menu.tscn")
	)
	$Overlay/Panel/Content/Restart.pressed.connect(restart)
	driver.updated.connect(_updated)
	$BillboardPass.configure($Player/Camera)
	# Preserve the complete mouse displacement, but service expensive authority
	# and lock-on views once per drawn frame rather than once per device report.
	Input.use_accumulated_input = true
	get_window().focus_exited.connect(_focus_lost)
	var initial := int(get_tree().get_meta("campaign_level", 1))
	score_eligible = initial == 1 and bool(get_tree().get_meta("campaign_score_eligible", true))
	get_tree().remove_meta("campaign_score_eligible")
	var arguments := OS.get_cmdline_user_args()
	for index: int in range(arguments.size() - 1):
		if arguments[index] == "--level":
			initial = int(arguments[index + 1])
			score_eligible = false
	load_level(clampi(initial, 1, 16))


func load_level(number: int, carry: Dictionary = {}) -> bool:
	if number < 1 or number > 16:
		return false
	_close_pause_view()
	native_controls.clear()
	_pending_mouse_aim = 0
	ready_to_play = false
	$Audio.stop_all()
	$Overlay/Panel.visible = true
	var level_path := "/LEVEL%d.LEV" % number
	# A restart replaces authority state; unchanged immutable geometry/resources
	# can stay attached, retaining the existing native door/sprite view lifetime.
	if $World.level == null or $World.level.source_path != level_path:
		if not $World.load_original(level_path):
			$Overlay/Panel/Content/Status.text = $World.last_error
			return false
	var tables: Resource = $World.source.load_cd_behaviour_tables()
	actor_catalog = $World.source.load_cd_actor_catalog($World.level)
	if tables == null or actor_catalog == null:
		$Overlay/Panel/Content/Status.text = $World.source.last_error
		return false
	$Actors.configure($World, actor_catalog)
	actor_animations.configure(actor_catalog)
	door_motion = preload("res://scripts/presentation/cd_door_motion_presentation.gd").new()
	var choices := FrontendSettings.values()
	session.control_scheme = int(input_settings.values.diagonals)
	var definition := preload("res://scripts/game/world_definition.gd").new()
	definition.configure($World.level, tables, actor_catalog)
	server.configure(
		definition, true, int(input_settings.values.diagonals), driver.recording, carry
	)
	client = server.attach_client(0)
	$OriginalHud/Hud.status_language = int(choices.language)
	preload("res://scripts/audio/cd_audio_settings.gd").restore_user_mix(int(choices.sound))
	if not $OriginalHud/Hud.configure($World, client.session):
		$Overlay/Panel/Content/Status.text = $World.source.last_error
		return false
	if not $Audio.configure($World.source):
		$Overlay/Panel/Content/Status.text = $Audio.last_error
		return false
	$Audio.bind_session(client)
	$Audio.bind_listener($Player/Camera, $World.level.spawn)
	$Audio.set_paused(false)
	$Audio.start_campaign($World.level)
	visibility.session = session
	driver.attach(server, client, _controls)
	level_number = number
	_transition_pending = false
	_game_over_presented = false
	$Overlay/Panel/Content/Restart.text = "Restart level"
	paused = false
	ready_to_play = true
	sync_cheat_policy()
	$Overlay/Panel.visible = false
	$Overlay/Panel/Content/Status.text = "LEVEL%d · European CD" % level_number
	_previous_usec = Time.get_ticks_usec()
	_updated()
	if (
		driver.recording.is_empty()
		and DisplayServer.get_name() != "headless"
		and get_window().has_focus()
	):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	return true


func _next_level() -> void:
	if not ready_to_play or not session.is_complete():
		_transition_pending = false
		return
	_begin_campaign_transition(false)


func _begin_campaign_transition(exhausted: bool) -> void:
	if is_instance_valid(_campaign_transition):
		return
	var transition := server.campaign.begin(session, exhausted)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_resume_capture = false
	$Overlay/Panel.visible = false
	var kind: String = transition.kind
	_campaign_transition = (
		load("res://scenes/campaign_%s/campaign_%s.tscn" % [kind, kind]).instantiate()
	)
	_campaign_transition.result = transition.result
	_campaign_transition.phase = transition.phase
	_campaign_transition.completed.connect(_campaign_transition_done.call_deferred)
	_campaign_transition.music_changed.connect(func(_track: int) -> void: $Audio.stop_all())
	var layer := CanvasLayer.new()
	layer.name = "CampaignTransition"
	layer.layer = 20
	add_child(layer)
	layer.add_child(_campaign_transition)


func _campaign_transition_done(action: String) -> void:
	var decision := server.campaign.complete(action, session)
	if decision.is_empty():
		return
	_clear_campaign_transition()
	if decision.kind == "load":
		load_level(int(decision.level), decision.carry)
	else:
		var flow = preload("res://scripts/frontend/cd_frontend_flow.gd")
		var destination: String = flow.show_scores(
			"res://scenes/startup/startup.tscn",
			int(decision.level),
			int(decision.rating),
			bool(decision.ineligible),
			4
		)
		get_tree().change_scene_to_file(destination)


func _clear_campaign_transition() -> void:
	if is_instance_valid(_campaign_transition):
		_campaign_transition._done = true
		_campaign_transition.get_node("Audio").stop_all()
		_campaign_transition.get_parent().queue_free()
	_campaign_transition = null
	_transition_pending = false


func restart() -> void:
	if paused:
		_set_paused(false, false)
	# Development restart is separate from the original continuation route.
	score_eligible = false
	_clear_campaign_transition()
	if not ready_to_play:
		return
	if session.is_game_over():
		continue_credits = 3
		load_level(1)
		return
	load_level(level_number)


func _advance_to_now() -> void:
	var now := Time.get_ticks_usec()
	var elapsed := now - _previous_usec
	_previous_usec = now
	if ready_to_play and not paused and not _transition_pending and not session.is_game_over():
		driver.advance_usec(elapsed)
		if _pending_mouse_aim != 0:
			driver.aim_units(float(_pending_mouse_aim) / 65536.0)
			_pending_mouse_aim = 0


func _process(_delta: float) -> void:
	sync_cheat_policy()
	_advance_to_now()
	if ready_to_play and not paused:
		_present()
		if session.is_complete() and not _transition_pending:
			_transition_pending = true
			_next_level.call_deferred()
	if ready_to_play:
		_present_objective()
		if session.is_game_over() and not _game_over_presented:
			_game_over_presented = true
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			_resume_capture = false
			$Audio.stop_all()
			$Overlay/Panel.visible = true
			$Overlay/Panel/Content/Restart.text = "Restart campaign"
			$Overlay/Panel/Content/Status.text = "Game over · No lives remaining"
			_begin_campaign_transition(true)


func _input(event: InputEvent) -> void:
	if _transition_pending:
		return
	# Advance with the previous event state. Polling Input here would apply the
	# new event retroactively to elapsed motion and combat during catch-up.
	if (
		event is InputEventKey
		or event is InputEventMouseButton
		or event is InputEventJoypadButton
		or event is InputEventJoypadMotion
	):
		_advance_to_now()
		_pause_input_event = event if native_controls.ingest(event, _allow_mouse_actions(), not paused and int(session.fighter.state) == 1) else null
		if ready_to_play and not paused:
			client.command(_controls(0), _aim_rate())
	if (
		ready_to_play
		and not paused
		and event is InputEventMouseMotion
		and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	):
		_aim_mouse(event.screen_relative.x)
		get_viewport().set_input_as_handled()


func _aim_mouse(horizontal_pixels: float) -> void:
	if int(session.fighter.state) not in [1, 3]:
		return
	var delta := horizontal_pixels * mouse_degrees_per_pixel * 16384.0 / 360.0
	var fixed := roundi(fmod(delta, 16384.0) * 65536.0)
	_pending_mouse_aim = (_pending_mouse_aim + fixed) % 1073741824
	var angle: float = float(client.player_pose().angle) + float(_pending_mouse_aim) / 65536.0
	$Player.rotation.y = -fposmod(angle, 16384.0) * TAU / 16384.0
	# Both native views rotate immediately; projection/viewport work stays in
	# the regular billboard pass rather than being repeated for each report.
	$BillboardPass/View/Camera.global_transform = $Player/Camera.global_transform


func _unhandled_input(event: InputEvent) -> void:
	if (
		paused
		and event is InputEventKey
		and event.pressed
		and not event.echo
		and event.physical_keycode == KEY_F12
	):
		$Overlay/Panel.visible = not $Overlay/Panel.visible
		_pause_view.accepts_controls = not $Overlay/Panel.visible
		_pause_view._held = 0xffffffff
		_pause_view._previous = 0xffffffff
		_pause_view._pending = 0xffffffff
		_pause_view.navigation._reset_controls_edges()
		get_viewport().set_input_as_handled()
		return
	if _transition_pending or not ready_to_play:
		return
	var native_escape: bool = (
		event is InputEventKey
		and event.pressed
		and not event.echo
		and event.physical_keycode == KEY_ESCAPE
	)
	# Direct pause injection is also used by regression tools. Gameplay input
	# already passed through _input; the fallback must never queue a second
	# weapon request, including wheel pulses that have no held/release state.
	var request_pause := (
		_pause_input_event == event
		or native_controls.ingest(event, _allow_mouse_actions(), false)
	)
	_pause_input_event = null
	if native_escape or request_pause:
		if not paused and not native_escape:
			_advance_to_now()
			if not PauseRules.can_pause(session.fighter):
				get_viewport().set_input_as_handled()
				return
		_set_paused(not paused)
		get_viewport().set_input_as_handled()
	elif (
		ready_to_play
		and not paused
		and event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_LEFT
		and int(session.fighter.state) in [1, 3]
	):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()


func _set_paused(value: bool, cue: bool = true) -> void:
	sync_cheat_policy()
	if _transition_pending or session.is_game_over():
		return
	if not ready_to_play or value == paused:
		return
	if value:
		_advance_to_now()
		_resume_capture = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif _resume_capture:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	paused = value
	$OriginalHud/Hud.pause_overlay = value
	$OriginalHud/Hud.queue_redraw()
	$Overlay/Panel.visible = false
	$Audio.set_paused(paused)
	if value:
		_create_pause_view()
	else:
		_close_pause_view()
		# The pause overlay consumes its own releases; require fresh gameplay
		# input after resume, rather than retaining a stale fire/use/axis state.
		native_controls.clear()
		# Flush the source latch too: paused presses never become gameplay edges.
		var held := int(_controls(0).held)
		if not _checkpoint_resume:
			server.release_controls(not _checkpoint_resume)
		_checkpoint_resume = false
		if cue:
			$Audio.play_source(0x2873c)
	_previous_usec = Time.get_ticks_usec()
	$Overlay/Panel/Content/Status.text = (
		"Paused · F12: development controls" if paused else "LEVEL%d · European CD" % level_number
	)
	_present()


func _close_pause_view() -> void:
	if is_instance_valid(_pause_view):
		_pause_history = _pause_view.history.duplicate()
		_pause_view._done = true
		_pause_view.queue_free()
	_pause_view = null
	$OriginalHud/Hud.pause_overlay = false


func _pause_state() -> Dictionary:
	return server.pause_state(_pause_history)


func _commit_pause_state(state: Dictionary, timers: bool = true) -> void:
	server.apply_pause_state(state, timers)


func _pause_finished(result: Dictionary) -> void:
	if not paused or not is_instance_valid(_pause_view):
		return
	_pause_history = result.history.duplicate()
	# Source callbacks remain in the pure rules/reference suite. The native pause
	# navigation cannot dispatch cheats before the separate cheat menu is added.
	_set_paused(false)


func _pause_main_menu() -> void:
	if not paused or not is_instance_valid(_pause_view):
		return
	_pause_view._done = true
	$Audio.stop_all()
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu/main_menu.tscn")


func _focus_lost() -> void:
	_advance_to_now()
	native_controls.clear()
	_set_paused(true)


func _exit_tree() -> void:
	if driver.recording.is_empty():
		driver.aim_rate = Callable()
	Input.mouse_mode = _previous_mouse_mode
	Input.use_accumulated_input = _previous_accumulation


## Backend for native controls preferences. Saving succeeds before live values change.
func configure_controls(patch: Dictionary, persist: bool = true) -> Error:
	_advance_to_now()
	var result := input_settings.apply(patch, persist)
	if result == OK:
		native_controls.configure(input_settings.values)
		mouse_degrees_per_pixel = float(input_settings.values.mouse_degrees_per_pixel)
		if ready_to_play:
			session.control_scheme = int(input_settings.values.diagonals)
			server.release_controls(true)
	return result


func _joy_connection_changed(_device: int, _connected: bool) -> void:
	_advance_to_now()
	var previous := native_controls.device
	native_controls.devices_changed(Input.get_connected_joypads())
	if previous >= 0 and previous != native_controls.device:
		_set_paused(true)


func _allow_mouse_actions() -> bool:
	return (
		Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		or get_viewport().gui_get_hovered_control() == null
	)


func _controls(_sample: int) -> Dictionary:
	return native_controls.packet(_allow_mouse_actions())


func _aim_rate() -> float:
	return native_controls.aim_units_per_second(_allow_mouse_actions())


func _updated() -> void:
	if not server._publishing:
		server.refresh_views(true)
	var view: RefCounted = client.session
	door_motion.synchronize(
		view.groups,
		driver.animation_frame_time(false),
		int(driver.timing_profile.samples_per_update),
		view.blocked_doors
	)
	actor_animations.synchronize(
		view.actor_system.actors,
		driver.animation_frame_time(false),
		view.actor_system.projectile_launches
	)
	presentation._segments = client.segments.duplicate(true)
	presentation._groups = view.groups.duplicate(true)
	_present(0.0)
	$Overlay/Panel/Content/Health.text = (
		"Health %d · Lives %d" % [view.fighter.health, maxi(int(view.fighter.lives), 0)]
	)
	var selected := int(view.weapon_state.selected)
	if selected < 0:
		$Overlay/Panel/Content/Weapon.text = "Weapon 0 · Ammo unlimited"
	else:
		var weapon: Dictionary = view.weapon_state.inventory[selected]
		@warning_ignore("integer_division")
		var percent := clampi(int(weapon.ammo) * 100 / Pickups.FULL_AMMO, 0, 100)
		$Overlay/Panel/Content/Weapon.text = "Weapon %d · Ammo %d%%" % [weapon.kind, percent]
	var held_keys: PackedStringArray = []
	for key: Dictionary in view.keys:
		if int(key.kind) != 0:
			held_keys.append(str(key.kind))
	$Overlay/Panel/Content/Keys.text = (
		"Keys: " + (", ".join(held_keys) if not held_keys.is_empty() else "none")
	)
	if int(view.fighter.state) == 2:
		$Overlay/Panel/Content/Status.text = (
			"You have died · Respawning…" if int(view.fighter.lives) > 0 else "No lives remaining…"
		)
	for event: Dictionary in view.last_events:
		if event.kind == "player_respawned":
			$Overlay/Panel/Content/Status.text = "Respawned · Health restored"
		elif event.kind == "core_shielded":
			$Overlay/Panel/Content/Status.text = "Core shielded · Destroy the surrounding satellite nodes"
		elif event.kind == "satellite_destroyed":
			$Overlay/Panel/Content/Status.text = (
				"Shield down · Core vulnerable"
				if int(event.remaining) == 0
				else "Satellite destroyed · %d remaining" % int(event.remaining)
			)
		elif event.kind == "core_destroyed":
			$Overlay/Panel/Content/Status.text = "Core destroyed · Return to the level entrance"
		elif event.kind == "item_collected":
			if event.category == "health":
				$Overlay/Panel/Content/Status.text = "Health restored"
			elif event.category == "ammo":
				$Overlay/Panel/Content/Status.text = "Ammunition refilled"
			else:
				$Overlay/Panel/Content/Status.text = (
					"Collected weapon %d" % (int(event.source_kind) - 28)
				)
		elif event.kind == "key_collected":
			$Overlay/Panel/Content/Status.text = "Collected key %d" % int(event.key)
		elif event.kind == "key_missing":
			$Overlay/Panel/Content/Status.text = "A key is required."
	_present_objective()


func _present(phase: float = -1.0) -> void:
	var view: RefCounted = client.session
	# Current events plus independent artwork and bounded forward movement.
	# Input-clock restoration cancels stale paths; the player always draws now.
	var state := presentation.sample(
		view.motion,
		view.actor_system.actors,
		view.groups,
		view.actor_system.projectile_launches,
		driver.world_phase() if phase < 0.0 else phase
	)
	$World.set_palette_bank(int(view.palette_state.bank))
	$World.palette.set_player_flash(int(view.fighter.get("flash_word", -1)))
	# HUD and camera share one collision-checked knockback sample for this frame.
	var pose: Dictionary = driver.player_pose()
	$OriginalHud/Hud.present(view, pose, driver.animation_frame_time())
	$Player.set_view_rect($OriginalHud/Hud.view_rect, $OriginalHud/Hud.widescreen)
	$Player.present(pose, $World)
	$World.set_door_states(
		view.groups, door_motion.sample(view.groups, driver.animation_frame_time())
	)
	$Actors.present(actor_animations.sample(state.actors, driver.animation_frame_time()), driver.animation_frame_time())
	$BillboardPass.sync_camera()


func _refresh_projection() -> void:
	if ready_to_play:
		$Player.set_view_rect($OriginalHud/Hud.view_rect, $OriginalHud/Hud.widescreen)
		$BillboardPass.sync_camera()


func set_widescreen(enabled: bool) -> void:
	DisplaySettings.set_widescreen(enabled)
	$Overlay/Panel/Content/DisplayOptions/Widescreen.set_pressed_no_signal(enabled)
	$OriginalHud/Hud.set_widescreen(enabled)
	if ready_to_play:
		_present()


func _present_objective() -> void:
	var view: RefCounted = client.session
	# The timer changes on the input clock; reading it here keeps the HUD current
	# without running AI, combat or countdown from a rendering callback.
	var encounter: Dictionary = view.actor_system.encounter
	var objective: Label = $Overlay/Panel/Content/Objective
	if view.is_game_over():
		objective.text = "Game over · No lives remaining"
	elif view.is_complete():
		objective.text = (
			"Campaign complete · Escaped"
			if level_number == 16
			else "LEVEL%d complete · Escaped" % level_number
		)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_resume_capture = false
	elif int(view.fighter.state) == 3:
		objective.text = "Escaped · Leaving level…"
	elif view.countdown_expired:
		objective.text = "Time expired · Core restored"
	elif int(encounter.countdown) > 0:
		var seconds := Progression.displayed_seconds(encounter, int(view.fighter.state))
		if seconds >= 0:
			@warning_ignore("integer_division")
			objective.text = "Return to the entrance · %02d:%02d" % [seconds / 60, seconds % 60]
		else:
			objective.text = "Core destroyed · Return to the level entrance"
	elif int(encounter.gate) > 0:
		objective.text = "Destroy the satellite nodes · %d remaining" % int(encounter.gate)
	else:
		objective.text = "Shield down · Destroy the central core"
	if int(view.fighter.state) == 2:
		$Overlay/Panel/Content/Status.text = (
			"You have died · Respawning…" if int(view.fighter.lives) > 0 else "No lives remaining…"
		)
		$Overlay/Panel/Content/Health.text = (
			"Health %d · Lives %d" % [view.fighter.health, maxi(int(view.fighter.lives), 0)]
		)


func capture_checkpoint() -> PackedByteArray:
	sync_cheat_policy()
	# Pause slots and research tools use the same complete checkpoint backend.
	if not ready_to_play or session.world._atomic_depth != 0:
		session.world.last_checkpoint_error = "Capture requires a ready campaign at a completed boundary"
		return PackedByteArray()
	_advance_to_now()
	var attachments := preload("res://scripts/persistence/checkpoint_attachments.gd").new()
	var state := attachments.capture(self)
	session.world.campaign_state = state.campaign
	server.campaign.restore(state.campaign)
	session.world.presentation_state = state.presentation
	return session.capture_checkpoint()


func restore_checkpoint(bytes: PackedByteArray) -> bool:
	if session.world._atomic_depth != 0:
		session.world.last_checkpoint_error = "Checkpoint restore requires a completed simulation boundary"
		return false
	var candidate := preload("res://scripts/game/world_state.gd").new()
	if not candidate.restore_checkpoint(bytes, $World.source):
		session.world.last_checkpoint_error = candidate.last_checkpoint_error
		return false
	if (
		candidate.players.size() != 1
		or candidate.campaign_state.is_empty()
		or candidate.presentation_state.is_empty()
	):
		session.world.last_checkpoint_error = "Campaign checkpoint requires one player and view/campaign continuity"
		return false
	var state := {
		"campaign": candidate.campaign_state, "presentation": candidate.presentation_state
	}
	# Save history is monotonic within the active campaign, even when loading
	# an earlier clean slot. The current preference never clears provenance.
	var ever: bool = (
		server.campaign.cheats_ever_enabled
		or bool(state.campaign.get("cheats_ever_enabled", state.campaign.get("cheated", false)))
		or preload("res://scripts/frontend/cd_cheat_settings.gd").enabled()
	)
	state.campaign.cheats_ever_enabled = ever
	state.campaign.score_eligible = bool(state.campaign.score_eligible) and score_eligible and not ever
	var number: int = state.campaign.level_number
	# Validation and media rebinding have completed before changing the live
	# scene. Rebuilding never ticks the candidate or emits historical effects.
	if candidate.level.source_path != "/LEVEL%d.LEV" % number:
		session.world.last_checkpoint_error = "Campaign/world level mismatch"
		return false
	_clear_campaign_transition()
	_close_pause_view()
	$Audio.stop_all()
	if not $World.load_original(candidate.level.source_path):
		session.world.last_checkpoint_error = $World.last_error
		return false
	actor_catalog = candidate.definition.catalog
	$Actors.configure($World, actor_catalog)
	if bytes.decode_u16(8) == 1:
		# Original scene checkpoints rebound this visibility callable on load;
		# schema 1 did not carry the later explicit authority policy flag.
		candidate.admission_state.source_visibility = true
	server.install_checkpoint(candidate)
	visibility.session = session
	server.bind_world()
	server.campaign.restore(state.campaign)
	client = server.attach_client(0)
	driver = Driver.new()
	driver.recording = session.world.demo_recording
	driver.attach(server, client, _controls)
	driver.updated.connect(_updated)
	if driver.recording.is_empty():
		driver.aim_rate = _aim_rate
	$OriginalHud/Hud.configure($World, client.session)
	$Audio.bind_session(client)
	$Audio.bind_listener($Player/Camera, $World.level.spawn)
	var attachments := preload("res://scripts/persistence/checkpoint_attachments.gd").new()
	attachments.restore_campaign(self, state.campaign)
	sync_cheat_policy()
	server.refresh_views(true)
	attachments.attach_views(self, state)
	# Rebase host time and release physical controls. Accepted semantic latch
	# windows, motor acceleration and already-admitted commands remain intact.
	native_controls.clear()
	_resume_capture = false
	Input.mouse_mode = (
		Input.MOUSE_MODE_VISIBLE if paused or _transition_pending else Input.MOUSE_MODE_CAPTURED
	)
	_previous_usec = Time.get_ticks_usec()
	ready_to_play = true
	_checkpoint_resume = true
	$OriginalHud/Hud.pause_overlay = paused
	if paused and not _transition_pending and not session.is_game_over():
		_create_pause_view()
	$Overlay/Panel.visible = false
	_present()
	return true


func _create_pause_view() -> void:
	_pause_view = preload("res://scenes/pause_menu/pause_menu.tscn").instantiate()
	_pause_view.campaign = self
	_pause_view.main_menu_requested.connect(_pause_main_menu)
	_pause_view.active = true
	_pause_view.history = _pause_history.duplicate()
	_pause_view.finished.connect(_pause_finished)
	$Overlay.add_child(_pause_view)
