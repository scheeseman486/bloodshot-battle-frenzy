extends Node
## Renderer-free composition root. It mounts rules/media but creates no audio,
## input adapter, camera or world geometry. A client probe is opt-in diagnostics.
var endpoint: Node
var source: RefCounted
var options: Dictionary = {}
var _previous := 0
var _started := 0
var _deadline := 0
var _closing := false
var _probed := false
var _peak_players := 0
var _maximum_debt := 0
var _maximum_frame_usec := 0
var _asset_load_usec := 0
var _console: RefCounted
var _console_input: RefCounted
var _input_closed := false


func _ready() -> void:
	var asset_started := Time.get_ticks_usec()
	for argument: String in OS.get_cmdline_user_args():
		var fields := argument.trim_prefix("--").split("=", true, 1)
		options[fields[0]] = fields[1] if fields.size() == 2 else "true"
	if (
		not str(options.get("port", "")).is_valid_int()
		or int(options.port) < 1
		or int(options.port) > 65535
	):
		_fail("An explicit --port in 1..65535 is required")
		return
	source = preload("res://scripts/assets/original_asset_source.gd").new()
	if not source.mount(source.configured_disc_path()):
		_fail(source.last_error)
		return
	var definition := preload("res://scripts/game/world_definition.gd").new()
	var versus: bool = options.get("mode", "coop") == "versus"
	var arena := str(options.get("map", "arena-1"))
	var limit := int(options.get("kill-limit", "15"))
	if options.get("mode", "coop") not in ["coop", "versus"] or (versus and (arena not in ["arena-1", "arena-2", "arena-3"] or limit not in preload("res://scripts/game/vs_match.gd").LIMITS)):
		_fail("Unsupported VS arena or kill limit")
		return
	var loaded: bool = definition.load_map(source, arena) if versus else definition.load_from_source(source, int(options.get("level", "1")))
	if not loaded:
		_fail("Cannot load original level")
		return
	definition.set_meta("session_flow", true)
	_asset_load_usec = Time.get_ticks_usec() - asset_started
	endpoint = preload("res://scripts/network/replication_peer.gd").new()
	add_child(endpoint)
	if not preload("res://scripts/network/network_settings.gd").configure(endpoint.transport):
		_fail(preload("res://scripts/network/network_settings.gd").last_error)
		return
	var success := false
	if options.has("probe-client"):
		endpoint.asset_loader = func(manifest):
			var content := preload("res://scripts/game/world_definition.gd").new()
			return content if content.load_manifest(source, manifest) else null
		success = endpoint.join(
			definition, str(options.get("address", "127.0.0.1")), int(options.port)
		)
	else:
		var server := preload("res://scripts/game/game_server.gd").new()
		server.configure(definition, false)
		success = endpoint.host(server, int(options.port), str(options.get("bind", "127.0.0.1")))
		if success:
			endpoint.coop.source = source
			endpoint.coop.session = {"enabled": true, "mode": "versus" if versus else "coop", "lobby": false,
				"map": arena if versus else "level-%d" % int(options.get("level", "1"))}
			endpoint.coop.kill_limit = limit
			if versus: server.world.vs_state.limit = limit
	if not success:
		_fail(endpoint.last_error)
		return
	_previous = Time.get_ticks_usec()
	_started = _previous
	_deadline = _started + int(float(options.get("seconds", "0")) * 1000000)
	if options.has("report"):
		var ready := FileAccess.open(str(options.report) + ".ready", FileAccess.WRITE)
		if ready != null:
			ready.store_string("ready")
			ready.close()
	print(
		"NETWORK_APPLICATION_READY ",
		"client probe" if options.has("probe-client") else "dedicated server",
		" UDP ",
		options.port
	)
	if not options.has("probe-client") and not options.has("no-console"):
		_console = preload("res://scripts/network/server_console.gd").new()
		_console.endpoint = endpoint
		_console.shutdown_requested.connect(_finish, CONNECT_DEFERRED)
		_console_input = ClassDB.instantiate("BloodshotConsoleInput")
		for line: String in _console.help_text(): print(line)


func _process(_delta: float) -> void:
	if endpoint == null or _previous == 0 or _closing:
		return
	var now := Time.get_ticks_usec()
	if endpoint.authority != null:
		endpoint.advance_authority_usec(now - _previous)
		_peak_players = maxi(_peak_players, endpoint.authority.world.players.size())
		var clock: RefCounted = endpoint.authority.world.clock
		_maximum_debt = maxi(_maximum_debt, int(clock._phase / clock._threshold))
	endpoint.pump(now / 1000, now)
	if options.has("probe-client") and endpoint.phase == "live" and not _probed:
		endpoint.client.command({"held": 0xffffffff, "strafe": 0}, 0.0, [32.0])
		_probed = true
	_previous = now
	_maximum_frame_usec = maxi(_maximum_frame_usec, Time.get_ticks_usec() - now)
	if _console != null:
		if not _input_closed:
			var input: Dictionary = _console_input.poll()
			_input_closed = input.eof
			if not str(input.error).is_empty(): print("Console: ", input.error)
			for line: String in _console.feed(input.bytes, input.eof): print(line)
		# All actions run after pump/advance, never inside a simulation update.
		for line: String in _console.drain(): print(line)
	if _closing: return
	if _deadline > _started and now >= _deadline:
		_finish()


func _finish() -> void:
	if _closing: return
	_closing = true
	var report := {
		"phase": endpoint.phase,
		"elapsed_usec": Time.get_ticks_usec() - _started,
		"sent_bytes": endpoint.transport.sent_bytes,
		"received_bytes": endpoint.transport.received_bytes,
		"largest_packet": endpoint.transport.largest_packet,
		"metrics": endpoint.metrics,
		"audio_catalog_loaded": source._audio_cache != null,
		"asset_load_usec": _asset_load_usec,
		"audio_services": get_tree().get_nodes_in_group("bloodshot_audio_services").size(),
		"peak_players": _peak_players,
		"maximum_clock_debt": _maximum_debt,
		"maximum_frame_usec": _maximum_frame_usec,
		"renderer": RenderingServer.get_current_rendering_method(),
		"display_driver": DisplayServer.get_name(),
		"camera_nodes": get_tree().root.find_children("*", "Camera3D", true, false).size()
	}
	if endpoint.authority != null:
		report.world_updates = endpoint.authority.world.update_count
		report.players = endpoint.authority.world.players.size()
	else:
		report.finalized = endpoint.finalized_command
		report.owner = endpoint.client.reference
	var versus_state: Dictionary = endpoint.authority.world.vs_state if endpoint.authority != null else endpoint.installed.get("versus", {})
	if not versus_state.is_empty():
		report.versus = {"phase": versus_state.phase, "limit": versus_state.limit, "rows": versus_state.rows.size()}
	var success: bool = (
		endpoint.phase != "rejected" and endpoint.transport.last_error.is_empty()
		and (endpoint.authority != null or (_probed and endpoint.finalized_command > 0))
	)
	if options.has("report"):
		var file := FileAccess.open(str(options.report), FileAccess.WRITE)
		if file == null:
			success = false
		else:
			file.store_string(JSON.stringify(report, "\t") + "\n")
			file.close()
	print("NETWORK_APPLICATION_RESULT ", JSON.stringify(report))
	endpoint.close()
	preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(
		get_tree(), 0 if success else 1
	)


func _fail(message: String) -> void:
	_closing = true
	push_error(message)
	preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree(), 1)


func _exit_tree() -> void:
	if is_instance_valid(endpoint):
		endpoint.close()
