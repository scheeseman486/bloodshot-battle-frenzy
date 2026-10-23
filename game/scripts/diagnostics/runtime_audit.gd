extends Node
## Opt-in standalone lifecycle/performance audit. Measurements use real runtime
## media, scene ownership and rendering. Temporary audit saves never publish
## player preferences or drive simulation.
var rows: Array[Dictionary] = []
var cycles := 3
var frames := 144
var _gpu := false
var _snapshot_dir := ""


func _ready() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--audit-cycles="):
			cycles = clampi(argument.get_slice("=", 1).to_int(), 1, 8)
		elif argument.begins_with("--audit-snapshot-dir="):
			_snapshot_dir = argument.trim_prefix("--audit-snapshot-dir=")
		elif argument.begins_with("--audit-frames="):
			frames = clampi(argument.get_slice("=", 1).to_int(), 30, 1440)
	_run.call_deferred()


func _frame() -> void:
	await get_tree().process_frame
	if _gpu:
		await RenderingServer.frame_post_draw


func _snapshot(label: String, cycle: int, load_usec: int = 0) -> Dictionary:
	var row := {
		"label": label,
		"cycle": cycle,
		"load_usec": load_usec,
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"static_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"video_bytes": int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)),
		"audio_players": get_tree().root.find_children("*", "AudioStreamPlayer", true, false).size()
	}
	rows.append(row)
	print("RUNTIME_AUDIT_SAMPLE ", JSON.stringify(row))
	return row


func _sample_process(row: Dictionary) -> void:
	if _snapshot_dir.is_empty():
		return
	# Release builds buffer stdout. Use a private file handshake so the host
	# samples this exact scene before the audit advances to another one.
	var path := _snapshot_dir.path_join("%d-%s.json" % [row.cycle, row.label])
	var output := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	output.store_string(JSON.stringify(row))
	output.close()
	DirAccess.rename_absolute(path + ".tmp", path)
	var deadline := Time.get_ticks_msec() + 1000
	while not FileAccess.file_exists(path + ".ack"):
		if Time.get_ticks_msec() >= deadline:
			push_error("Runtime audit process sampling timed out")
			preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)
			return
		await get_tree().process_frame


func _replace(path: String) -> int:
	var started := Time.get_ticks_usec()
	var error := get_tree().change_scene_to_file(path)
	if error != OK:
		push_error("Runtime audit could not open " + path)
		preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)
		return -1
	await _frame()
	await _frame()
	if get_tree().current_scene.name == "Startup":
		while get_tree().current_scene.preparing_assets:
			await _frame()
	return Time.get_ticks_usec() - started


func _measure(label: String, cycle: int, load_usec: int) -> void:
	# Let deferred scene frees and the normal audio stop/fade complete before
	# sampling retained resources. Warm-up frames are excluded from frame stats.
	for index: int in range(24):
		await _frame()
	var row := _snapshot(label, cycle, load_usec)
	var intervals: Array[int] = []
	var previous := Time.get_ticks_usec()
	for index: int in range(frames):
		await _frame()
		var now := Time.get_ticks_usec()
		intervals.append(now - previous)
		previous = now
	intervals.sort()
	row["frame_usec"] = {
		"count": intervals.size(),
		"p50": intervals[intervals.size() / 2],
		"p95": intervals[int(intervals.size() * 0.95)],
		"p99": intervals[int(intervals.size() * 0.99)],
		"max": intervals.back()
	}
	var scene: Node = get_tree().current_scene
	if scene.name == "Campaign":
		var music: AudioStreamPlayer = scene.get_node("Audio/CDMusic")
		if music.playing:
			var playback := music.get_stream_playback()
			row["cdda_buffered_frames"] = int(playback.call("buffered_frames"))
			row["cdda_underruns"] = int(playback.call("underruns"))
		row["simulation_updates"] = scene.session.update_count
		row["game_paused"] = scene.paused
	# The handshake is outside the reported rendered-frame samples.
	await _sample_process(row)
	print("RUNTIME_AUDIT_BOUNDARY ", JSON.stringify(row))


func _shutdown_case(name: String) -> void:
	var mode := (
		"campaign"
		if name in ["campaign", "paused", "seek", "fm"]
		else ("main_menu" if name in ["window", "transition"] else name)
	)
	await _replace("res://scenes/%s/%s.tscn" % [mode, mode])
	var scene: Node = get_tree().current_scene
	var audio: Node = scene.get_node_or_null("Audio")
	if name == "paused":
		scene._set_paused(true)
		if not await _pause_options_check(scene):
			preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)
			return
	elif name == "seek":
		audio._on_request({"kind": "music_seek", "track": 6})
	elif name == "fm":
		audio._on_request({"kind": "fm_write", "port": 0, "register": 0x22, "value": 0})
		audio.play_source(0x2873c)
	if name == "controls_menu" and not await _controls_save_check(scene):
		preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)
		return
	print("RUNTIME_AUDIT_SHUTDOWN ", name)
	if "--audit-force-exit" in OS.get_cmdline_user_args():
		# Deliberately bypass normal shutdown to check the native unload guard.
		get_tree().quit()
		return
	if name == "window":
		get_tree().root.close_requested.emit()
		get_tree().root.close_requested.emit()  # Repeated close requests are idempotent.
		return
	if name == "transition":
		get_tree().change_scene_to_file.call_deferred("res://scenes/campaign/campaign.tscn")
	if name == "development_menu":
		scene.get_node("Center/Content/Quit").pressed.emit()
		return
	preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree())


func _controls_save_check(scene: Control) -> bool:
	# Export templates cannot execute an external --script smoke. Exercise the
	# packaged font/scene/store through the existing opt-in audit instead.
	const Store = preload("res://scripts/input/cd_input_settings.gd")
	const PATH := "user://controls-menu-runtime-audit.json"
	DirAccess.remove_absolute(PATH)
	if scene.model == null:
		push_error("Runtime controls scene failed to mount original CD data")
		return false
	var font: Font = scene.get_node("Canvas").theme.default_font
	for code: int in range(32, 127):
		if not font.has_char(code):
			push_error("Runtime controls font lacks character " + str(code))
			return false
	# The audit owns a separate save file, even when launched from a normal profile.
	scene.model.store = Store.new(PATH)
	scene.model.draft = scene.model.store.values.duplicate(true)
	scene.show_page("settings")
	scene._sliders.mouse_degrees_per_pixel.value = 0.23
	if FileAccess.file_exists(PATH):
		push_error("Runtime controls draft wrote before Save")
		return false
	scene.save()
	await get_tree().process_frame
	await get_tree().process_frame
	var saved: RefCounted = Store.new(PATH)
	var valid := (
		FileAccess.file_exists(PATH)
		and is_equal_approx(float(saved.values.mouse_degrees_per_pixel), 0.23)
	)
	DirAccess.remove_absolute(PATH)
	if not valid:
		push_error("Runtime controls persistence check failed")
		return false
	print(
		"RUNTIME_AUDIT_CONTROLS ",
		JSON.stringify({"glyphs": 95, "mouse_sensitivity": 0.23, "persisted": true})
	)
	return true


func _run() -> void:
	_gpu = DisplayServer.get_name() != "headless"
	AudioServer.set_bus_mute(0, true)
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--audit-shutdown="):
			var name := argument.get_slice("=", 1)
			if (
				name
				not in [
					"startup",
					"title_screen",
					"main_menu",
					"controls_menu",
					"campaign",
					"paused",
					"seek",
					"fm",
					"window",
					"transition",
					"development_menu"
				]
			):
				push_error("Unknown shutdown audit case")
				preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(
					get_tree(), 1
				)
				return
			await _shutdown_case(name)
			return
	Engine.max_fps = 144
	if _gpu:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		get_tree().root.size = Vector2i(1280, 720)
	print(
		"RUNTIME_AUDIT_ENV ",
		JSON.stringify(
			{
				"engine": Engine.get_version_info().string,
				"renderer": RenderingServer.get_current_rendering_method(),
				"display": DisplayServer.get_name(),
				"audio_driver": AudioServer.get_driver_name(),
				"cycles": cycles,
				"frames_per_scene": frames,
				"fps_cap": Engine.max_fps,
				"viewport": [1280, 720],
				"gpu": RenderingServer.get_video_adapter_name()
			}
		)
	)
	for cycle: int in range(cycles):
		for name: String in ["startup", "title_screen", "main_menu"]:
			var elapsed := await _replace("res://scenes/%s/%s.tscn" % [name, name])
			await _measure(name, cycle, elapsed)
		get_tree().set_meta("campaign_level", 1)
		var elapsed := await _replace("res://scenes/campaign/campaign.tscn")
		var campaign: Node3D = get_tree().current_scene
		for level: int in range(1, 17):
			if level > 1:
				var started := Time.get_ticks_usec()
				if not campaign.load_level(level):
					push_error("Runtime audit level load failed")
					preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(
						get_tree(), 1
					)
					return
				elapsed = Time.get_ticks_usec() - started
			# The audit is stationary and independent of keyboard/focus activity
			# elsewhere on the desktop. Live application pause behaviour is unchanged.
			if get_tree().root.focus_exited.is_connected(campaign._focus_lost):
				get_tree().root.focus_exited.disconnect(campaign._focus_lost)
			campaign.driver._controls = _neutral_controls
			await _measure("level_%02d" % level, cycle, elapsed)
		elapsed = await _replace("res://scenes/main_menu/main_menu.tscn")
		await _measure("menu_after_campaign", cycle, elapsed)
	# Normal scene removal, then observe the settled tree with no game scene.
	get_tree().current_scene.queue_free()
	for index: int in range(24):
		await _frame()
	var settled := _snapshot("settled_empty", cycles)
	await _sample_process(settled)
	print("RUNTIME_AUDIT_COMPLETE ", JSON.stringify(rows))
	preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree())


func _neutral_controls(_sample: int) -> Dictionary:
	return {"held": 0xffffffff, "strafe": 0}


func _pause_options_check(scene: Node3D) -> bool:
	var session: RefCounted = scene.session
	var before := var_to_bytes(
		[
			session.motion,
			session.fighter,
			session.weapon_state,
			session.actor_system.actors,
			session.groups,
			session.palette_state,
			session.actor_system.movement_seed,
			scene.driver.clock.tick_count
		]
	)
	var menu: Control = scene._pause_view.navigation
	menu.set_process(false)
	menu._activate(4)
	await _frame()
	if menu.page != "options" or not menu.background.visible or not scene.paused:
		push_error("Standalone pause failed to retain its campaign in Options")
		return false
	menu.open_menu("preferences")
	menu.open_controls()
	await _frame()
	if menu._controls_menu == null or menu._controls_menu._font == null:
		push_error("Standalone paused controls/font failed to load")
		return false
	menu._controls_menu.close(false)
	await _frame()
	await _frame()
	menu.open_menu("options")
	menu._go_back()
	if menu.page != "pause" or menu.background.visible or scene.session != session:
		push_error("Standalone Options failed to return to frozen pause")
		return false
	var after := var_to_bytes(
		[
			session.motion,
			session.fighter,
			session.weapon_state,
			session.actor_system.actors,
			session.groups,
			session.palette_state,
			session.actor_system.movement_seed,
			scene.driver.clock.tick_count
		]
	)
	if before != after:
		push_error("Standalone Options advanced or changed gameplay")
		return false
	print("RUNTIME_AUDIT_PAUSE_OPTIONS retained campaign, controls and original background")
	return true
