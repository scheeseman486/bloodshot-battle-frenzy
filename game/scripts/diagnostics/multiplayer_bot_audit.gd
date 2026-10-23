extends Node
## Real listen-host scene, internal bots and a genuine joining human. Captures
## are ignored local evidence; this script never changes source gameplay data.
var directory := "user://multiplayer-bot-audit"
var relay_port := 29470
var join_probe := {}
var participant_changes: Array = []
var root: Window:
	get: return get_tree().root
var game: Node3D
var remote: Node
var source: RefCounted
var frames: Array[int] = []
var look_cpu: Array[int] = []


func _check(condition: bool, message: String = "Bot smoke check") -> bool:
	if not condition:
		var file := FileAccess.open(directory.path_join("bot-smoke-failure.txt"),FileAccess.WRITE)
		if file!=null: file.store_string(message)
		push_error(message)
		get_tree().quit(1)
	return condition


func _ready() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--audit-bot-output="): directory=argument.trim_prefix("--audit-bot-output=")
		if argument.begins_with("--audit-bot-relay-port="): relay_port=argument.trim_prefix("--audit-bot-relay-port=").to_int()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	Engine.max_fps=120
	root.size=Vector2i(1280,960)
	get_tree().create_timer(90.0).timeout.connect(func(): push_error("Bot scene smoke timeout"); get_tree().quit(1))
	_run.call_deferred()


func _wait(predicate: Callable) -> void:
	var deadline := Time.get_ticks_msec()+12000
	while not predicate.call() and Time.get_ticks_msec()<deadline:
		if remote!=null: remote.pump(Time.get_ticks_msec())
		await get_tree().process_frame
	_check(predicate.call(),"Bot scene convergence")


func _live() -> bool:
	return game.ready_to_play and game.endpoint.phase=="live" and game.endpoint.epoch==game.host_endpoint.epoch


func _admin(action: String, value: Variant = null) -> void:
	var epoch: int = game.host_endpoint.epoch
	var world: RefCounted = game.host_endpoint.authority.world
	var reference: Dictionary = game.endpoint.client.reference.duplicate()
	var stream: AudioStream = game.get_node("Audio")._music.stream
	var stamp := Time.get_ticks_usec()
	_check(game.request_admin(action,value))
	if action == "bot_count":
		await _wait(func(): return game._admin_commands.is_empty() and _live() and world.bots.count(world)==int(value) and game.endpoint.score_rows().size()==world.players.size())
		_check(game.host_endpoint.epoch==epoch,"Bot edit preserves epoch")
		_check(game.endpoint.client.reference==reference,"Bot edit preserves human identity")
		_check(game.get_node("Audio")._music.stream==stream,"Bot edit preserves playing CD music")
		participant_changes.append({"action":action,"count":int(value),"converged_usec":Time.get_ticks_usec()-stamp,"epoch_preserved":true,"music_preserved":true})
	else:
		await _wait(func(): return game.host_endpoint.epoch!=epoch and _live())


func _capture(name: String) -> void:
	if DisplayServer.get_name()=="headless": return
	if is_instance_valid(game._menu):
		for index: int in range(game._menu.labels.size()): game._menu._resolve_row(index)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory.path_join(name+".png"))


func _run() -> void:
	_check(ProjectSettings.get_setting("application/config/name")=="bloodshot-battle-frenzy")
	if DisplayServer.get_name()!="headless": _check(RenderingServer.get_current_rendering_method()=="forward_plus")
	source=preload("res://scripts/assets/original_asset_source.gd").new()
	_check(source.mount(source.configured_disc_path()))
	_check(await source.prepare_asset_cache())
	_check(await preload("res://scripts/presentation/cd_runtime_preparation.gd").prepare(source))
	# Explicit test-owned port; occupied is a failure, never a fallback.
	get_tree().set_meta("network_request",{"host":true,"address":"127.0.0.1","port":"29470","lobby":true})
	game=preload("res://scenes/network_gameplay/network_gameplay.tscn").instantiate()
	root.add_child(game)
	await _wait(_live)
	for count: int in [1,2,3,1,3]:
		await _admin("bot_count",count)
	var world: RefCounted = game.host_endpoint.authority.world
	_check(world.bots.count(world)==3)
	game._menu.open_menu("bots")
	_check(not game._menu._actions.any(func(item): return item.id=="bot_difficulty"))
	await _capture("coop-bots-lobby")
	await _admin("mode","versus")
	game._menu.open_menu("bots")
	_check(game._menu._actions.any(func(item): return item.id=="bot_difficulty"))
	_check(game.request_admin("bot_difficulty",2))
	await _wait(func(): return world.bots.state.difficulty==2)
	_check(game._menu._actions.filter(func(item): return item.id=="participant").map(func(item): return item.label)==["PLAYER 1","BOT 1","BOT 2","BOT 3"],"Independent lobby numbering")
	await _capture("vs-bots-lobby")
	await _admin("map","arena-1")
	await _wait(func(): return game.endpoint.score_rows().size()==4)
	_check(game.host_endpoint.peers.size()==1)
	_check(game.endpoint.score_rows().filter(func(row): return row[5]==-3).size()==3)
	for mode: String in ["versus","coop"]:
		if mode=="coop":
			await _admin("mode","coop")
			await _admin("bot_count",3)
			await _admin("map","level-1")
		await _wait(func(): return game.endpoint.score_rows().size()==4)
		var overlay: Control = game.get_node("OriginalHud/LiveScores")
		for size: Vector2i in [Vector2i(1280,960),Vector2i(1920,1080)]:
			root.size=size
			preload("res://scripts/presentation/cd_display_settings.gd").set_widescreen(size.x*3>size.y*4)
			game.get_node("OriginalHud/Hud").set_widescreen(size.x*3>size.y*4)
			await get_tree().process_frame
			game.set_process(false)
			game._present()
			overlay.present(game.endpoint.score_rows(),mode,game.endpoint.client.reference)
			overlay.show()
			_check(overlay._rows.filter(func(row): return row.user.text.begins_with("BOT ")).map(func(row): return row.user.text)==["BOT 1","BOT 2","BOT 3"],"Independent Tab numbering")
			await _capture("%s-bot-scores-%dx%d"%[mode,size.x,size.y])
			overlay.hide()
			game.set_process(true)
		game._open_menu()
		_check(not overlay.visible)
		game._close_menu()
		# A real additional human must replace a bot, not create a fifth body.
		if mode=="versus":
			var retained_music: AudioStream = game.get_node("Audio")._music.stream
			var retained_epoch: int = game.host_endpoint.epoch
			var retained_reference: Dictionary = game.endpoint.client.reference.duplicate()
			remote=preload("res://scripts/network/replication_peer.gd").new()
			root.add_child(remote)
			remote.asset_loader=func(manifest):
				var loaded := preload("res://scripts/game/world_definition.gd").new()
				return loaded if loaded.load_manifest(source,manifest) else null
			_check(remote.join(game.host_endpoint.definition,"127.0.0.1",relay_port))
			await _wait(func(): return remote.phase=="live")
			_check(world.bots.count(world)==2 and world.players.size()==4)
			await _wait(func(): return remote.score_rows().size()==4)
			_check(remote.installed.roster.filter(func(row): return row.get("controller","human")=="bot").size()==2)
			remote.client.command({"held":0xfffffffe,"strafe":0})
			var move_until := Time.get_ticks_msec()+1000
			while Time.get_ticks_msec()<move_until:
				remote.pump(Time.get_ticks_msec())
				await get_tree().process_frame
			remote.client.command({"held":0xffffffff,"strafe":0})
			await _wait(func(): return remote.finalized_command>0)
			join_probe={"rtt_ms":remote.rtt_ms,"finalized_command":remote.finalized_command,"bot_rows":2,"wire_sent":remote.transport.sent_bytes,"wire_received":remote.transport.received_bytes}
			remote.close()
			remote.queue_free()
			remote=null
			await _wait(func(): return world.players.size()==3)
			_check(game.host_endpoint.epoch==retained_epoch,"Human join/departure preserves epoch")
			_check(game.endpoint.client.reference==retained_reference,"Human join/departure preserves survivor")
			_check(game.get_node("Audio")._music.stream==retained_music,"Human join/departure preserves music")
	# Final native run checks high-rate look with internal bots on the host.
	root.size=Vector2i(1280,960)
	preload("res://scripts/presentation/cd_display_settings.gd").set_widescreen(false)
	game._close_menu()
	var age := 0.0
	var previous := Time.get_ticks_usec()
	while age<12.0:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var delta := float(now-previous)/1000000.0
		previous=now
		age+=delta
		if age>=2.0: frames.append(roundi(delta*1000000.0))
		if DisplayServer.get_name()!="headless":
			for sample: int in range(8):
				var stamp := Time.get_ticks_usec()
				var motion := InputEventMouseMotion.new()
				motion.relative=Vector2(0.25,0)
				game._input(motion)
				if age>=2.0: look_cpu.append(Time.get_ticks_usec()-stamp)
	frames.sort()
	look_cpu.sort()
	var report := {"renderer":RenderingServer.get_current_rendering_method(),"display":DisplayServer.get_name(),
		"players":world.players.size(),"bots":world.bots.count(world),"network_peers":game.host_endpoint.peers.size(),
		"phase":game.host_endpoint.phase,"ai":world.bots.metrics.duplicate(),"frames":frames.size(),
		"human_probe":join_probe.duplicate(),"participant_changes":participant_changes.duplicate(true),
		"p50_usec":frames[int((frames.size()-1)*0.5)],"p95_usec":frames[int((frames.size()-1)*0.95)],
		"p99_usec":frames[int((frames.size()-1)*0.99)],"max_usec":frames.back()}
	if not look_cpu.is_empty(): report.look_cpu={"count":look_cpu.size(),"p50_usec":look_cpu[int((look_cpu.size()-1)*0.5)],"p99_usec":look_cpu[int((look_cpu.size()-1)*0.99)],"max_usec":look_cpu.back()}
	var file := FileAccess.open(directory.path_join("native-smoke.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	print("INTEGRATED BOT SMOKE PASS ",JSON.stringify(report))
	game.queue_free()
	await get_tree().process_frame
	await get_tree().create_timer(0.25).timeout
	preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree())
