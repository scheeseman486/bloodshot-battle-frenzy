extends Node3D
## Native remote client view. It owns no World, AI, combat clock or server.
## A separate authority process keeps running while this scene loads or loses focus.
const Controls = preload("res://scripts/input/cd_native_controls.gd")
var host_endpoint: Node
var _host_time := 0
var _configured_epoch := -1
var _configured_token := 0
var _menu: Control
var _card: Control
var _card_phase := ""
var _leaving := false
var endpoint: Node
var controls := Controls.new()
var settings := preload("res://scripts/input/cd_input_settings.gd").new()
var ready_to_play := false
var last_error := ""
var _owned_endpoint := false
var _previous_mouse := Input.MOUSE_MODE_VISIBLE
var _previous_accumulation := true
var _configured_level := ""
var _host_menu_pending := false
var _admin_commands: Array = []
var _pending_mouse_aim := 0


func _ready() -> void:
	controls.configure(settings.values)
	controls.devices_changed(Input.get_connected_joypads())
	Input.joy_connection_changed.connect(_devices_changed)
	_previous_mouse = Input.mouse_mode
	_previous_accumulation = Input.use_accumulated_input
	Input.use_accumulated_input = true
	# A lobby starts with a visible menu. Background/unfocused windows must not
	# steal pointer capture from another game/editor instance.
	var opening: Dictionary = get_tree().get_meta("network_request", {})
	Input.mouse_mode = (
		Input.MOUSE_MODE_CAPTURED
		if (
			get_window().has_focus()
			and not (opening.get("host", false) and opening.get("lobby", false))
		)
		else Input.MOUSE_MODE_VISIBLE
	)
	$BillboardPass.configure($Player/Camera)
	$OriginalHud/Hud.layout_changed.connect(_projection_changed)
	if endpoint == null:
		var options: Dictionary = get_tree().get_meta("network_request", {})
		if get_tree().has_meta("network_request"):
			get_tree().remove_meta("network_request")
		for argument: String in OS.get_cmdline_user_args():
			var parts := argument.trim_prefix("--").split("=", true, 1)
			if parts.size() == 2:
				options[parts[0]] = parts[1]
		if (
			not str(options.get("port", "")).is_valid_int()
			or int(options.port) < 1
			or int(options.port) > 65535
		):
			_fail("An explicit --port=N is required")
			return
		var source := preload("res://scripts/assets/original_asset_source.gd").new()
		if not source.mount(source.configured_disc_path()):
			_fail(source.last_error)
			return
		var definition := preload("res://scripts/game/world_definition.gd").new()
		if not definition.load_map(
			source,
			(
				"lobby"
				if bool(options.get("host", false)) and bool(options.get("lobby", false))
				else "level-1"
			)
		):
			_fail(source.last_error)
			return
		if bool(options.get("host", false)):
			definition.set_meta("session_flow", bool(options.get("lobby", false)))
			var authority := preload("res://scripts/game/game_server.gd").new()
			authority.configure(definition, false)
			host_endpoint = preload("res://scripts/network/replication_peer.gd").new()
			add_child(host_endpoint)
			if not preload("res://scripts/network/network_settings.gd").configure(host_endpoint.transport):
				_fail(preload("res://scripts/network/network_settings.gd").last_error)
				return
			if not host_endpoint.host(authority, int(options.port), "0.0.0.0"):
				_fail(host_endpoint.last_error)
				return
			if bool(options.get("lobby", false)):
				host_endpoint.coop.session = {
					"enabled": true, "mode": "coop", "lobby": true, "map": "lobby"
				}
				_host_menu_pending = true
			_host_time = Time.get_ticks_usec()
			options.address = "127.0.0.1"
		endpoint = preload("res://scripts/network/replication_peer.gd").new()
		add_child(endpoint)
		if not preload("res://scripts/network/network_settings.gd").configure(endpoint.transport):
			_fail(preload("res://scripts/network/network_settings.gd").last_error)
			return
		if host_endpoint != null:
			endpoint.transport.trusted_servers["127.0.0.1:%d" % int(options.port)] = host_endpoint.transport._certificate_text
		_owned_endpoint = true
		endpoint.asset_loader = func(manifest: Dictionary) -> RefCounted:
			var loaded := preload("res://scripts/game/world_definition.gd").new()
			return loaded if loaded.load_manifest(source, manifest) else null
		if not endpoint.join(
			definition, str(options.get("address", "127.0.0.1")), int(options.port), false
		):
			_fail(endpoint.last_error)
			return
	endpoint.joined.connect(_joined)
	endpoint.rejected.connect(_fail)
	endpoint.admin.completed.connect(_remote_admin_result)
	if endpoint.phase == "live":
		_joined()


func _prepare() -> bool:
	var path: String = endpoint.definition.level.source_path
	if path == _configured_level:
		return true
	ready_to_play = false
	$Audio.stop_all()
	if not $World.load_original(path):
		_fail($World.last_error)
		return false
	$Actors.configure($World, endpoint.definition.catalog)
	$NativeInventory.configure($World, endpoint.definition.catalog)
	_configured_level = path
	return true


func _joined() -> void:
	var resume_host := false
	var new_credential := _configured_token != int(endpoint.token)
	if not _prepare():
		return
	if host_endpoint != null:
		host_endpoint.local_host_reference = endpoint.client.reference.duplicate()
	if not ready_to_play:
		if (
			not $OriginalHud/Hud.configure($World, endpoint.client.session)
			or not $Audio.configure($World.source)
		):
			_fail($World.source.last_error)
			return
		$Audio.bind_session(endpoint.client)
		$Audio.bind_listener($Player/Camera, $World.level.spawn)
		$Audio.start_campaign($World.level, _entry_audio_allowed())
		$OriginalHud/LiveScores.configure(
			$OriginalHud/Hud.ui, $World.source.load_cd_small_font().native_font()
		)
	if _configured_epoch != int(endpoint.epoch):
		_pending_mouse_aim = 0
		# Open only the listen host's menu on a new lobby world. A same-epoch
		# recovery must not reopen a menu the host has already resumed from.
		if _configured_epoch >= 0 and host_endpoint != null:
			if bool(endpoint.installed.party.get("session", {}).get("lobby", false)):
				_host_menu_pending = true
			else:
				resume_host = true
		_configured_epoch = int(endpoint.epoch)
		if ready_to_play:
			$Audio.start_campaign($World.level, _entry_audio_allowed())
	if _configured_token != int(endpoint.token):
		_pending_mouse_aim = 0
		_configured_token = int(endpoint.token)
		_close_card()
		controls.clear()  # A new seat or map requires fresh physical input.
		$OriginalHud/LiveScores.hide()
	# Same-credential recovery retains held keys and reasserts current intent after
	# the authority neutralizes the old admitted command during synchronization.
	endpoint.client._last_controls.clear()
	ready_to_play = true
	last_error = ""
	$OriginalHud/Status.visible = false
	if _host_menu_pending:
		_host_menu_pending = false
		_open_menu()
	elif resume_host:
		# A successful playable-map attachment is the control handoff. Failed
		# selections and same-world recovery leave the current menu alone.
		_close_menu()
	elif (
		not is_instance_valid(_menu)
		and not is_instance_valid(_card)
		and (get_window().has_focus() or DisplayServer.get_name() == "headless")
	):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Bootstrap/rejoin can miss the transient escape event. Recover selection
	# from current semantic state without replaying Welcome or restarting 14.
	if int(endpoint.client.session.actor_system.encounter.exit_delay) > 0 or endpoint.client.session.is_complete():
		$Audio.ensure_completion_music()
	if new_credential:
		endpoint.reanchor_local_view(Time.get_ticks_usec())


func _entry_audio_allowed() -> bool:
	return (
		endpoint.installed.party.phase == "playing"
		and not bool(endpoint.installed.party.get("session", {}).get("lobby", false))
		and int(endpoint.client.session.actor_system.encounter.exit_delay) == 0
	)


func _process(_delta: float) -> void:
	if endpoint == null or _leaving:
		return
	_advance_host()
	var now := Time.get_ticks_usec()
	endpoint.advance_local_view(now)
	_flush_mouse_look()
	endpoint.pump(now / 1000, now)
	if endpoint.phase != "live":
		$OriginalHud/LiveScores.hide()
	if endpoint.phase == "loading" and _prepare():
		endpoint.mark_assets_ready()
	if ready_to_play and endpoint.phase == "live":
		var accepting := (
			not is_instance_valid(_menu)
			and not is_instance_valid(_card)
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		)
		endpoint.client.command(
			controls.packet(accepting), controls.aim_units_per_second(accepting)
		)
		$OriginalHud/Hud.set_widescreen(
			preload("res://scripts/presentation/cd_display_settings.gd").widescreen()
		)
		_present_party()
		_present_scores()
		_present()
	elif endpoint.phase not in ["live", "bootstrap", "loading", "connecting"]:
		var reason: String = endpoint.last_error if not endpoint.last_error.is_empty() else "Disconnected"
		if ready_to_play or last_error != reason:
			_fail(reason)



func _present() -> void:
	var shown: Dictionary = endpoint.render_state()
	if shown.is_empty():
		return
	var view: RefCounted = endpoint.client.session
	$World.set_palette_bank(int(view.palette_state.bank))
	$World.palette.set_player_flash(int(view.fighter.get("flash_word", -1)))
	$World.set_door_states(view.groups, shown.groups)
	for row: Dictionary in endpoint.installed.roster:
		if row.reference == endpoint.client.reference:
			$OriginalHud/Hud.set_player_colour(int(row.seat))
			break
	var versus_rows: Array = view.vs_state.get("rows", [])
	var local_vs := {}
	for entry: Dictionary in versus_rows:
		if entry.reference == endpoint.client.reference:
			local_vs = entry
			break
	$OriginalHud/Hud.pause_overlay = is_instance_valid(_menu) or is_instance_valid(_card)
	$OriginalHud/Hud.set_versus_player(local_vs, str(view.vs_state.get("phase", "")), int(view.vs_state.get("tick", 0)))
	$OriginalHud/Hud.present(view, shown.motion, shown.animation_time)
	$Player.set_view_rect($OriginalHud/Hud.view_rect, $OriginalHud/Hud.widescreen)
	$Player.present(shown.motion, $World)
	$Actors.present(shown.actors, float(shown.animation_time))
	$NativeInventory.present(shown.get("loot", {}))
	$BillboardPass.sync_camera()


func _present_scores() -> void:
	var tally: Control = $OriginalHud/LiveScores
	var allowed: bool = (
		ready_to_play and endpoint.phase == "live"
		and not is_instance_valid(_menu) and not is_instance_valid(_card)
		and _score_pointer_captured()
		and endpoint.installed.get("party", {}).get("phase", "") == "playing"
		and not endpoint.installed.get("party", {}).get("session", {}).get("lobby", false)
	)
	tally.visible = allowed and controls.strength("scores", true, true) > 0.0
	if tally.visible:
		tally.present(endpoint.score_rows(),
			"versus" if $World.level.get_meta("battle_mode", false) else "coop",
			endpoint.client.reference)


func _score_pointer_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _look_pointer_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if _leaving:
		return
	if (
		event is InputEventKey
		and event.pressed
		and event.physical_keycode == KEY_ESCAPE
		and (
			not ready_to_play or endpoint == null or endpoint.phase in ["disconnected", "rejected"]
		)
	):
		leave_game()
		return
	# Network navigation remains available during campaign/continue cards. The
	# retained card is local presentation; opening this menu never pauses authority.
	var menu_button: bool = (
		(event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE)
		or (
			event is InputEventJoypadButton
			and event.pressed
			and event.button_index == JOY_BUTTON_START
		)
	)
	if ready_to_play and is_instance_valid(_card) and not is_instance_valid(_menu) and menu_button:
		_open_menu()
		get_viewport().set_input_as_handled()
		return
	if (
		endpoint == null
		or not ready_to_play
		or is_instance_valid(_menu)
		or is_instance_valid(_card)
	):
		return
	if event is InputEventMouseMotion:
		if _look_pointer_captured():
			# Raw reports rotate both views only. Clock stepping, prediction input,
			# collision and packet construction belong to frame/button boundaries.
			var aim: float = (
				event.screen_relative.x
				* float(settings.values.mouse_degrees_per_pixel)
				* 16384.0 / 360.0
			)
			if int(endpoint.prediction.player_pose().get("state", 0)) not in [1, 3]:
				return
			_pending_mouse_aim = (_pending_mouse_aim + roundi(fmod(aim, 16384.0) * 65536.0)) % 1073741824
			var angle: float = float(endpoint.prediction.player_pose().angle) + float(_pending_mouse_aim) / 65536.0
			$Player.rotation.y = -fposmod(angle, 16384.0) * TAU / 16384.0
			$BillboardPass/View/Camera.global_transform = $Player/Camera.global_transform
		return
	_advance_host()
	var now := Time.get_ticks_usec()
	endpoint.advance_local_view(now)
	_flush_mouse_look()
	endpoint.pump(now / 1000, now)  # Elapsed movement always uses the old event.
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
		controls.clear()
		endpoint.client.command({"held": 0xffffffff, "strafe": 0})
		_open_menu()
		return
	if (
		event is InputEventMouseButton
		and event.pressed
		and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	if (
		event is InputEventKey
		or event is InputEventMouseButton
		or event is InputEventJoypadButton
		or event is InputEventJoypadMotion
	):
		if controls.ingest(event, true, int(endpoint.client.session.fighter.state) == 1):
			_open_menu()
			return
		endpoint.client.command(controls.packet(true), controls.aim_units_per_second(true))
		_present_scores()


func _flush_mouse_look() -> void:
	if _pending_mouse_aim == 0:
		return
	if endpoint.phase != "live" or not ready_to_play or is_instance_valid(_menu) or is_instance_valid(_card):
		_pending_mouse_aim = 0
		return
	if endpoint.client.command(controls.packet(true), controls.aim_units_per_second(true), [float(_pending_mouse_aim) / 65536.0]):
		_pending_mouse_aim = 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and ready_to_play:
		_pending_mouse_aim = 0
		$OriginalHud/LiveScores.hide()
		controls.clear()
		endpoint.client.command({"held": 0xffffffff, "strafe": 0})
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _projection_changed() -> void:
	if ready_to_play:
		$Player.set_view_rect($OriginalHud/Hud.view_rect, $OriginalHud/Hud.widescreen)
		$BillboardPass.sync_camera()


func _fail(reason: String) -> void:
	_pending_mouse_aim = 0
	last_error = reason
	ready_to_play = false
	controls.clear()
	$Audio.stop_all()
	_retire_overlays()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	$OriginalHud/Status.show_message(reason)


func _exit_tree() -> void:
	$Audio.stop_all()
	Input.mouse_mode = _previous_mouse
	Input.use_accumulated_input = _previous_accumulation
	if _owned_endpoint and endpoint != null:
		endpoint.close()
	if host_endpoint != null:
		host_endpoint.close()


func _advance_host() -> void:
	if host_endpoint != null:
		var now := Time.get_ticks_usec()
		host_endpoint.advance_authority_usec(now - _host_time)
		host_endpoint.pump(now / 1000)
		_host_time = now
		while not _admin_commands.is_empty():
			_execute_admin(_admin_commands.pop_front())


func _open_menu() -> void:
	if is_instance_valid(_menu):
		return
	controls.clear()
	$OriginalHud/LiveScores.hide()
	endpoint.client.command({"held": 0xffffffff, "strafe": 0})
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if is_instance_valid(_card):
		_card.hide()
		_card.process_mode = Node.PROCESS_MODE_DISABLED
	_menu = preload("res://scenes/network_menu/session_menu.tscn").instantiate()
	_menu.game = self
	if endpoint.admin.available: endpoint.admin.refresh_players()
	_menu.resumed.connect(_close_menu)
	_menu.leave_requested.connect(leave_game)
	$OriginalHud.add_child(_menu)


func _close_menu() -> void:
	if is_instance_valid(_menu):
		_menu.queue_free()
	_menu = null
	controls.clear()
	if is_instance_valid(_card):
		_card.show()
		_card.process_mode = Node.PROCESS_MODE_INHERIT
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	Input.mouse_mode = (
		Input.MOUSE_MODE_CAPTURED
		if get_window().has_focus() or DisplayServer.get_name() == "headless"
		else Input.MOUSE_MODE_VISIBLE
	)


func configure_controls(patch: Dictionary, persist: bool = true) -> Error:
	var result: Error = settings.apply(patch, persist)
	if result == OK:
		controls.configure(settings.values)
		$OriginalHud/LiveScores.hide()
	return result


func _present_party() -> void:
	if endpoint.installed.is_empty():
		return
	var party: Dictionary = endpoint.installed.party
	var versus: Dictionary = endpoint.installed.get("versus", {})
	if versus.get("phase", "") == "results":
		if is_instance_valid(_card) and _card_phase == "vs_results":
			_card.set_host_controls(host_endpoint != null or endpoint.admin.available)
		if not is_instance_valid(_card):
			_close_menu()
			_card_phase = "vs_results"
			_card = preload("res://scenes/vs_results/vs_results.tscn").instantiate()
			_card.result = versus.result.duplicate(true)
			_card.local_reference = endpoint.client.reference.duplicate()
			_card.host = host_endpoint != null or endpoint.admin.available
			_card.completed.connect(func(action): request_admin(action))
			_card.menu_requested.connect(_open_menu)
			$OriginalHud.add_child(_card)
			_card.configure($OriginalHud/Hud.ui, $World.source.load_cd_small_font().native_font())
			controls.clear()
			endpoint.client.command({"held": 0xffffffff, "strafe": 0})
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	if party.phase == "playing":
		_close_card()
		return
	if not is_instance_valid(_card) and party.phase != "finished":
		_close_menu()
		_card_phase = party.phase
		var tally: bool = party.phase == "clear" and party.result.has("players")
		var path := (
			"res://scenes/coop_tally/coop_tally.tscn"
			if tally
			else (
				"res://scenes/campaign_ending/campaign_ending.tscn"
				if party.level == 16 or party.phase != "clear"
				else "res://scenes/campaign_interlevel/campaign_interlevel.tscn"
			)
		)
		_card = load(path).instantiate()
		if tally:
			_card.local_reference = endpoint.client.reference.duplicate()
			_card.final_result = party.level == 16
			_card.completion_action = "ending" if party.level == 16 else "next"
		_card.result = party.result.duplicate(true)
		if party.level == 16:
			_card.result.credits = 0
		_card.phase = party.phase
		_card.completed.connect(_card_done)
		if party.phase == "clear":
			$Audio.stop_effects()
			$Audio.ensure_completion_music()
		else:
			$Audio.stop_all()
		$OriginalHud.add_child(_card)
		controls.clear()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif is_instance_valid(_card) and party.phase == "summary" and _card_phase != "summary":
		_card_phase = "summary"
		if _card.has_method("_begin_summary"):
			_card._begin_summary()
	if party.phase == "finished":
		leave_game()


func _card_done(action: String) -> void:
	var party: Dictionary = endpoint.installed.party
	if (
		action in ["finished", "scores"]
		and party.phase != "clear"
		and party.result.has("players")
		and _card.get_script().resource_path != "res://scenes/coop_tally/coop_tally.gd"
	):
		_close_card()
		_card_phase = party.phase
		_card = load("res://scenes/coop_tally/coop_tally.tscn").instantiate()
		_card.result = party.result.duplicate(true)
		_card.phase = party.phase
		_card.final_result = true
		_card.completion_action = action
		_card.local_reference = endpoint.client.reference.duplicate()
		_card.completed.connect(_card_done)
		$OriginalHud.add_child(_card)
		return
	if action == "ending" and party.phase == "clear" and party.level == 16:
		# Final standings precede the original congratulations/summary pages.
		# Keep the same authority card until those pages finish normally.
		_close_card()
		_card_phase = "clear"
		_card = load("res://scenes/campaign_ending/campaign_ending.tscn").instantiate()
		_card.result = endpoint.installed.party.result.duplicate(true)
		_card.result.credits = 0
		_card.phase = "clear"
		_card.completed.connect(_card_done)
		$OriginalHud.add_child(_card)
		return
	endpoint.party_action(action)
	# Retain the completed card until the authority changes epoch/status.


func _close_card() -> void:
	if is_instance_valid(_card):
		if _card.has_node("Audio"):
			_card.get_node("Audio").stop_all()
		_card.queue_free()
	_card = null
	_card_phase = ""


## Closing/disconnection must retire both the active page and nested Options
## controls immediately; deferred scene replacement cannot own their lifetime.
func _retire_overlays() -> void:
	$OriginalHud/LiveScores.hide()
	if is_instance_valid(_card):
		_card.hide()
		_card.process_mode = Node.PROCESS_MODE_DISABLED
	_close_card()
	if is_instance_valid(_menu):
		_menu.get_node("Audio").stop_all()
		_menu.hide()
		_menu.process_mode = Node.PROCESS_MODE_DISABLED
		_menu.queue_free()
		_menu = null


func leave_game() -> void:
	if _leaving:
		return
	_leaving = true
	ready_to_play = false
	controls.clear()
	set_process_input(false)
	$Audio.stop_all()
	_retire_overlays()
	if endpoint != null:
		endpoint.close()
	if host_endpoint != null:
		host_endpoint.close()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await get_tree().create_timer(0.25).timeout
	var tree := get_tree()
	tree.change_scene_to_file("res://scenes/main_menu/main_menu.tscn")
	# Normal scene changes detach the current scene immediately. A development
	# harness can instead have attached this view below an unrelated/root node;
	# explicitly retire that owner too, or its HUD/menu remains over the frontend.
	if is_inside_tree():
		queue_free()


func _devices_changed(_device: int, _connected: bool) -> void:
	controls.devices_changed(Input.get_connected_joypads())
	controls.clear()
	if endpoint != null and endpoint.phase == "live":
		endpoint.client.command({"held": 0xffffffff, "strafe": 0})


## Local actions use the host boundary queue; remote actions use the separately
## authorized typed protocol. UI capabilities never grant authority themselves.
func request_admin(action: String, value: Variant = null) -> bool:
	if endpoint == null: return false
	if host_endpoint == null and not _leaving:
		var accepted: bool = endpoint.admin.request(action, value)
		if not accepted and is_instance_valid(_menu): _menu.status = "Wait for the current server request"
		return accepted
	if (
		host_endpoint == null
		or _leaving
		or action not in ["mode", "map", "lobby", "kick", "ban", "unban", "save", "load", "limit", "rematch", "bot_count", "bot_difficulty", "bot_remove", "revive_bot"]
	):
		return false
	if _admin_commands.size() >= 8:
		return false
	_admin_commands.append({"action": action, "value": value})
	return true


func _remote_admin_result(action: String, accepted: bool, error: String) -> void:
	if is_instance_valid(_menu): _menu.admin_result(action, accepted, error)


func _execute_admin(command: Dictionary) -> void:
	var result := preload("res://scripts/network/host_administration.gd").execute(
		host_endpoint, command.action, command.value, endpoint.client.reference
	)
	if is_instance_valid(_menu):
		_menu.admin_result(command.action, result.ok, result.error)
