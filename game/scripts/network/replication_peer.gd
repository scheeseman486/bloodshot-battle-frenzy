class_name CdReplicationPeer
extends Node
## Explicit single-threaded network application endpoint. poll() only collects
## packets; pump() validates/stages transactions at a completed authority boundary.
## Gameplay clock time is exclusively supplied by the host, never the network.
signal joined
signal rejected(reason: String)
const Transport = preload("res://scripts/network/enet_transport.gd")
const Codec = preload("res://scripts/network/snapshot_codec.gd")
const Wire = preload("res://scripts/network/value_codec.gd")
const Transfer = preload("res://scripts/network/transfer.gd")
const ControlFrame = preload("res://scripts/network/control_codec.gd")
const Commands = preload("res://scripts/network/command_codec.gd")
const LiveTally = preload("res://scripts/game/live_score_tally.gd")
const Admission = preload("res://scripts/game/input_admission.gd")
const HOLD_MS := 250
const GAP_MS := 100
const TRANSFER_MS := 2000
const CONNECT_MS := 12000
const SEND_MS := 20
const MAX_BASELINES := 32
var transport := Transport.new()
var authority: RefCounted
var definition: RefCounted
var client := preload("res://scripts/game/game_client.gd").new()
# Application roster/snapshot is separate from owned HUD/camera state.
var installed: Dictionary = {}
var phase := "disconnected"
var last_error := ""
var peers: Dictionary = {}
var codec := Codec.new()
var token := 0
var epoch := 0
var clock_ms := 0
var _last_send := -SEND_MS
var _next_transfer := 1
var _assembly := Transfer.new()
# A few interleaved live updates can complete independently under reordering.
# Publication is still atomic and monotonic; staging is count/byte bounded.
var _assemblies: Dictionary = {}
var _processing_inbox := false
var _last_transfer := 0
var _baselines: Dictionary = {}
# A small expanded hot cache, separate from the 32 canonical wire baselines.
# Frozen copy-on-write branches share unchanged actor/path records.
var _baseline_views: Dictionary = {}
# At most four independent immutable encode jobs, one per current peer. Old
# epochs/tokens can finish safely but cannot publish into a replacement world.
var _publication_jobs: Array = []
var _commands: Array = []
var _next_command := 1
var _command_cursor := 0
var finalized_command := 0
var _events: Array = []
var _orphans: Array = []
var _assets_ready := true
var _hello_tokens: Array = []
var _join_started := 0
var _connect_started := -1
var _recovery_started := -1
var prediction := preload("res://scripts/network/client_prediction.gd").new()
var _last_pump_ms := -1
var _last_ping_ms := -1000
var _rtt_samples: Array = []
var rtt_ms := 0.0
var _clock_stamp := 0.0
var _clock_received := 0
var _last_visual_usec := -1
var _visual_fraction_usec := 0
var _weapon_context: Dictionary = {}
var presentation := preload("res://scripts/network/remote_presentation.gd").new()
var _party_request := ""
var _party_sent := -1000
var coop: RefCounted
var live_scores := LiveTally.new()
var local_host_reference: Dictionary = {}
var returning := preload("res://scripts/network/returning_players.gd").new()
# Replaceable UI telemetry is epoch/token scoped, outside world continuations.
var live_tally: Dictionary = {}
var _tally_sequence := 0
var _tally_received := -10000
var _last_tally_publish := -500
var _score_system: RefCounted
var asset_loader: Callable
var metrics := {
	"key_bytes": 0,
	"delta_bytes": 0,
	"max_assembly": 0,
	"joins": 0,
	"resyncs": 0,
	"rejected": 0,
	"verified": 0
}


func _init() -> void:
	add_child(transport)
	transport.connected.connect(_connected)
	transport.disconnected.connect(_disconnected)
	transport.failed.connect(_fail)
	prediction.feedback.cue.connect(_local_cue)


func host(server: RefCounted, port: int, address: String = "127.0.0.1") -> bool:
	if (
		server.world.timing_profile.profile_id != "europe-cd-logical-six-v1"
		or not server.world.demo_state.is_empty()
	):
		last_error = "Network play requires the native six-sample policy and live input"
		return false
	authority = server
	definition = server.world.definition
	epoch = server.world.actor_system.epoch
	returning.world_changed(server.world)
	if not transport.listen(port, address):
		last_error = transport.last_error
		return false
	authority.effect.connect(_effect)
	_bind_feedback()
	coop = preload("res://scripts/game/coop_campaign.gd").new()
	coop.configure(self)
	phase = "host"
	return true


func join(content: RefCounted, address: String, port: int, assets_ready: bool = true) -> bool:
	definition = content
	_assets_ready = assets_ready
	if not transport.connect_to(address, port):
		last_error = transport.last_error
		return false
	_connect_started = -1
	_recovery_started = -1
	phase = "connecting"
	return true


func mark_assets_ready() -> void:
	_assets_ready = true
	if phase == "loading":
		_join_started = clock_ms
		metrics.join_ms = -1
		_send(1, {"type": "ready", "manifest": codec.manifest(definition)})
		phase = "bootstrap"


func _connected(id: int) -> void:
	if authority == null:
		return
	if peers.size() >= 4:
		transport.disconnect_peer(id)
		return
	peers[id] = {
		"principal": transport.identities.get(id, {}).duplicate(),
		"token": ResourceUID.create_id(),
		"phase": "hello",
		"owner": {},
		"base": {},
		"base_id": 0,
		"publish_at": 0,
		"encoding": -1,
		"chunks_at": 0,
		"out": {},
		"states": {},
		"commands": {},
		"finalized": 0,
		"gap": -1,
		"last_input": clock_ms,
		"neutral": true,
		"next_input": 0,
		"started": clock_ms,
		"events": [],
		"verified": 0,
		"last_resync": -100000,
		"receipts": [],
		"shot_counts": {},
		"sent_controls": {"held": 0xffffffff, "strafe": 0},
		"reclaim": {},
		"ping_received": -10000
	}
	_hello(id)


func _hello(id: int) -> void:
	var row: Dictionary = peers[id]
	_send(
		id,
		{"type": "hello", "manifest": codec.manifest(authority.world.definition), "epoch": epoch},
		0,
		true
	)


func _disconnected(id: int) -> void:
	if authority != null:
		if peers.has(id):
			var departed: Dictionary = peers[id]
			returning.remember(authority.world, departed.owner if not departed.owner.is_empty() else departed.reclaim, departed.get("principal", {}), authority.campaign.describe().get("card", {}).get("result", {}).get("players", []))
			peers.erase(id)
			# Key transfer can emit source audio; detach the departing endpoint
			# before publishing any effects produced by participant removal.
			authority.world.remove_player(
				departed.owner if not departed.owner.is_empty() else departed.reclaim
			)
			roster_changed()
	else:
		live_tally.clear()
		phase = "disconnected"
		_commands.clear()
		_assembly = Transfer.new()
		_assemblies.clear()


func _send(id: int, value: Dictionary, channel: int = 0, reliable: bool = true) -> void:
	var payload := value.duplicate(true)
	payload.token = peers[id].token if authority != null and peers.has(id) else token
	var bytes := ControlFrame.new().encode(payload)
	if bytes.is_empty():
		bytes = Wire.new().encode(payload)
	transport.send_to(id, channel, bytes, reliable)


## Local prediction/presentation time only. High-rate look must never poll ENet,
## decode snapshots, reconcile authority state or run a listen host's simulation.
## Sharing this timestamp with pump prevents counting an input interval twice.
func advance_local_view(visual_usec: int) -> void:
	if visual_usec < 0: return
	var previous := _last_visual_usec
	_last_visual_usec = maxi(_last_visual_usec, visual_usec)
	var visual_elapsed := _last_visual_usec - previous if previous >= 0 else 0
	@warning_ignore("integer_division")
	var now_ms: int = _last_visual_usec / 1000
	_visual_fraction_usec = clampi(_last_visual_usec - now_ms * 1000, 0, 999)
	if authority == null and previous >= 0 and phase == "live":
		prediction.advance_usec(visual_elapsed)
		presentation.advance_usec(visual_elapsed, _presentation_tick(now_ms))


## A new credential's scene attachment may block on original assets/audio.
## That loading interval precedes control handoff, so sample time starts after
## it without advancing or rewinding either canonical motor or network clocks.
func reanchor_local_view(visual_usec: int) -> void:
	_last_visual_usec = maxi(_last_visual_usec, visual_usec)
	_visual_fraction_usec = posmod(_last_visual_usec, 1000)


func pump(now_ms: int, visual_usec: int = -1) -> void:
	# The wire/admission clock remains milliseconds. Local mouse sampling can
	# advance the view independently, without servicing this network boundary.
	advance_local_view(now_ms * 1000 if visual_usec < 0 else visual_usec)
	_last_pump_ms = now_ms
	clock_ms = now_ms
	_collect_publications()
	transport.poll()
	# No simulation/rules are called from ENet signals or receive callbacks.
	if authority != null and authority.world._atomic_depth != 0:
		return
	if authority != null and epoch != authority.world.actor_system.epoch:
		_world_changed()
	var inbox := transport.received
	transport.received = []
	_processing_inbox = true
	for packet: Dictionary in inbox:
		_handle(packet)
	_processing_inbox = false
	# Live snapshots are replaceable views. A received burst may contain several
	# complete deltas against retained ACKed baselines; validate/install the newest
	# once. Commands, reliable events and bootstrap transactions still run in order.
	if authority == null and phase == "live":
		var newest := _last_transfer
		for transfer: int in _assemblies:
			var assembly: RefCounted = _assemblies[transfer]
			if transfer > newest and assembly.complete() and assembly.metadata.kind == "delta":
				newest = transfer
		if newest > _last_transfer:
			_finish(_assemblies[newest])
	if authority == null and phase == "connecting":
		if _connect_started < 0:
			_connect_started = now_ms
		elif now_ms - _connect_started >= CONNECT_MS:
			transport.close()
			_fail(
				"Connection timed out. The server may be unreachable or the four-player party full."
			)
			return
	if authority != null:
		for id: int in peers.keys():
			_service_commands(id)
			_service_transfer(id)
			if peers.has(id) and peers[id].phase == "live" and now_ms >= int(peers[id].publish_at):
				_publish(id)
		if now_ms - _last_tally_publish >= 500:
			_publish_tally()
	else:
		for transfer: int in _assemblies.keys():
			if now_ms - _assemblies[transfer].started > TRANSFER_MS:
				_assemblies.erase(transfer)
		if not _assembly.metadata.is_empty() and now_ms - _assembly.started > TRANSFER_MS:
			_resync("assembly_timeout")
		if phase == "live" and now_ms - _last_send >= SEND_MS:
			_send_commands()
		if token != 0 and phase == "live" and now_ms - _last_ping_ms >= 250:
			_send(1, {"type": "ping", "echo": now_ms}, 1, false)
			_last_ping_ms = now_ms
		if prediction.needs_resync and now_ms - int(metrics.get("prediction_resync", -1000)) >= 250:
			metrics.prediction_resync = now_ms
			_resync("prediction_window")
		if phase == "live" and not _party_request.is_empty() and now_ms - _party_sent >= 100:
			_send(1, {"type": "party_action", "action": _party_request})
			_party_sent = now_ms
		_drain_events()
	if now_ms - _last_send >= SEND_MS:
		_last_send = now_ms


func _presentation_tick(now_ms: int) -> float:
	return (
		(
			_clock_stamp
			+ (
				(float(now_ms - _clock_received) * 1000.0 + rtt_ms * 500.0 + _visual_fraction_usec)
				/ prediction.STEP_USEC
			)
		)
		if _clock_received > 0
		else -1.0
	)


## Participant deltas retain the live epoch, peer credentials and view clocks.
## Refresh only public views and schedule the roster/score table next pump.
func roster_changed() -> void:
	if authority == null:
		return
	authority.bind_world()
	authority.refresh_views(true)
	_last_tally_publish = clock_ms - 500


func _world_changed() -> void:
	epoch = authority.world.actor_system.epoch
	definition = authority.world.definition
	returning.world_changed(authority.world)
	live_scores.reset()
	local_host_reference.clear()
	_last_tally_publish = -500
	_bind_feedback()
	for id: int in peers:
		_reset_peer(id)


func _reset_peer(id: int) -> void:
	var row: Dictionary = peers[id]
	row.encoding = -1
	row.token = ResourceUID.create_id()
	row.phase = "hello"
	row.owner = {}
	row.base = {}
	row.out = {}
	row.states.clear()
	row.commands.clear()
	row.events.clear()
	row.receipts.clear()
	row.shot_counts.clear()
	row.sent_controls = {"held": 0xffffffff, "strafe": 0}
	row.finalized = 0
	row.next_input = 0
	row.gap = -1
	row.neutral = true
	row.started = clock_ms
	_hello(id)


func _handle(packet: Dictionary) -> void:
	if authority != null and not peers.has(packet.peer):
		return
	if authority == null and packet.peer != 1:
		return
	var bytes: PackedByteArray = packet.bytes
	if (
		packet.channel == 1
		and bytes.size() >= 4
		and bytes.decode_u32(0) in [Commands.MAGIC, Commands.COMPRESSED_MAGIC]
	):
		var message: Dictionary = Commands.new().decode(bytes)
		if authority == null or message.is_empty() or message.token != peers[packet.peer].token:
			metrics.rejected += 1
			return
		_server_message(packet.peer, message, 1)
		return
	if packet.channel in [2, 3] and bytes.size() >= 4 and bytes.decode_u32(0) == 0x314e5342:
		if authority == null:
			_chunk(bytes)
		return
	var message: Dictionary = (
		ControlFrame.new().decode(bytes)
		if bytes.size() >= 4 and bytes.decode_u32(0) == ControlFrame.MAGIC
		else Wire.new().decode(bytes)
	)
	if (
		message.is_empty()
		or not message.get("type") is String
		or not message.get("token") is int
		or message.get("type") == "commands"
	):
		metrics.rejected += 1
		return
	if authority != null:
		if message.token == peers[packet.peer].token:
			_server_message(packet.peer, message, packet.channel)
		else:
			metrics.rejected += 1
	elif message.type == "hello" and packet.channel == 0:
		_client_hello(message)
	elif message.token == token:
		_client_message(message, packet.channel)


func _client_hello(message: Dictionary) -> void:
	if message.token in _hello_tokens:
		return
	if not message.get("manifest") is Dictionary or not message.get("epoch") is int:
		return
	if codec.manifest(definition) != message.manifest and asset_loader.is_valid():
		var loaded: Variant = asset_loader.call(message.manifest)
		if loaded != null:
			definition = loaded
	if codec.manifest(definition) != message.manifest:
		_fail("Protocol, rules or original European CD content mismatch")
		return
	_party_request = ""
	_recovery_started = -1
	client._last_controls.clear()
	token = message.token
	_hello_tokens.append(token)
	if _hello_tokens.size() > 8:
		_hello_tokens.pop_front()
	epoch = message.epoch
	prediction = preload("res://scripts/network/client_prediction.gd").new()
	prediction.feedback.cue.connect(_local_cue)
	client.prediction = prediction
	_rtt_samples.clear()
	rtt_ms = 0.0
	_clock_stamp = 0.0
	_clock_received = 0
	_last_ping_ms = -1000
	presentation = preload("res://scripts/network/remote_presentation.gd").new()
	installed = {}
	live_tally.clear()
	_baselines.clear()
	_baseline_views.clear()
	_commands.clear()
	_events.clear()
	_orphans.clear()
	_next_command = 1
	_command_cursor = 0
	finalized_command = 0
	_last_transfer = 0
	_assembly = Transfer.new()
	_assemblies.clear()
	phase = "loading"
	if _assets_ready:
		mark_assets_ready()


func _server_message(id: int, message: Dictionary, channel: int) -> void:
	var row: Dictionary = peers[id]
	match message.type:
		"ping":
			if channel == 1 and message.get("echo") is int:
				row.ping_received = clock_ms
				_send(
					id,
					{
						"type": "pong",
						"echo": message.echo,
						"tick":
						(
							float(authority.world.clock.tick_count)
							+ authority.world.clock.subtick_fraction()
						)
					},
					1,
					false
				)
		"ready":
			if (
				channel == 0
				and row.phase == "hello"
				and message.get("manifest") == codec.manifest(definition)
			):
				_keyframe(id)
		"ack":
			if channel == 0:
				_ack(id, message)
		"resync":
			if channel == 0 and row.phase != "hello" and clock_ms - int(row.last_resync) >= 100:
				row.last_resync = clock_ms
				metrics.resyncs += 1
				_keyframe(id)
		"party_action":
			if (
				channel == 0
				and coop != null
				and message.get("action") in ["next", "continue", "finished", "scores"]
			):
				var accepted: bool = coop.action(id, message.action)
				_send(
					id,
					{
						"type": "party_result",
						"action": message.action,
						"accepted": accepted,
						"retry": row.phase == "attach"
					}
				)
		"commands":
			if channel == 1 and row.phase == "live":
				_accept_commands(row, message)


func _client_message(message: Dictionary, channel: int) -> void:
	match message.type:
		"tally":
			if (
				channel == 1 and message.get("epoch") is int and message.epoch == epoch
				and message.get("sequence") is int
				and message.sequence > int(live_tally.get("sequence", -1))
				and message.get("mode") in ["coop", "versus"]
				and LiveTally.valid_rows(message.get("rows"))
				and (message.mode != "versus" or message.rows.all(func(row): return row[4] >= 0))
			):
				live_tally = message.duplicate(true)
				_tally_received = clock_ms
		"party_result":
			if (
				channel == 0
				and message.get("action") == _party_request
				and message.get("accepted") is bool
				and message.get("retry") is bool
			):
				if message.accepted or not message.retry:
					_party_request = ""
					last_error = "" if message.accepted else "Party action unavailable"

		"pong":
			if (
				channel == 1
				and phase == "live"
				and message.get("echo") is int
				and message.get("tick") is float
				and message.echo <= clock_ms
				and clock_ms - message.echo <= 1000
			):
				_rtt_samples.append(clock_ms - message.echo)
				if _rtt_samples.size() > 8:
					_rtt_samples.pop_front()
				rtt_ms = float(_rtt_samples.min())
				_clock_stamp = message.tick
				_clock_received = clock_ms
				prediction.observe_clock(_clock_stamp, rtt_ms)
		"weapon":
			if (
				channel == 0
				and _valid_shot(message.get("identity"))
				and message.identity.player == client.reference
				and message.get("weapon") is int
				and message.weapon >= 0
				and message.weapon <= 10
				and message.get("ordinal") is int
				and message.ordinal >= 0
				and _valid_entities(message.get("entities"))
				and message.entities.size() <= 6
			):
				prediction.feedback.confirm(
					message.identity,
					message.weapon,
					message.entities,
					int(message.get("ordinal", 0))
				)
		"begin":
			if channel not in [2, 3] or not message.get("meta") is Dictionary:
				return
			var meta: Dictionary = message.meta
			if (
				meta.get("epoch") != epoch
				or not meta.get("transfer") is int
				or meta.transfer <= _last_transfer
			):
				return
			if _assemblies.has(meta.transfer):
				return
			var candidate := Transfer.new()
			if candidate.begin(meta, clock_ms):
				_assemblies[meta.transfer] = candidate
				while _assemblies.size() > 4 or _staged_bytes() > 2 * 1024 * 1024:
					_assemblies.erase(_assemblies.keys().min())
				if not _assemblies.has(meta.transfer):
					return
				_assembly = candidate
				var remaining: Array = []
				for bytes: PackedByteArray in _orphans:
					if bytes.decode_s64(4) == meta.transfer:
						if not candidate.fragment(bytes):
							_resync("chunk_integrity")
							return
					elif bytes.decode_s64(4) > _last_transfer:
						remaining.append(bytes)
				_orphans = remaining
				metrics.max_staging = maxi(int(metrics.get("max_staging", 0)), _staged_bytes())
				_finish(candidate)
		"finalized":
			if (
				channel == 0
				and message.get("sequence") is int
				and message.sequence >= finalized_command
				and message.sequence < _next_command
			):
				finalized_command = message.sequence
				_commands = _commands.filter(
					func(command): return command.sequence > finalized_command
				)
		"events":
			if channel == 4 and message.get("events") is Array and message.events.size() <= 8:
				for event: Variant in message.events:
					if (
						_events.size() < 128
						and event is Dictionary
						and event.get("epoch") == epoch
						and event.get("ordinal") is int
						and event.get("sequence") is int
						and event.get("category") in ["audio", "gameplay"]
						and event.get("payload") is Dictionary
						and (not event.has("audience") or codec._reference(event.audience))
					):
						_events.append(event.duplicate(true))


func _chunk(bytes: PackedByteArray) -> void:
	if (
		bytes.size() >= Transfer.HEADER
		and bytes.decode_s64(12) == epoch
		and bytes.decode_s64(4) > _last_transfer
	):
		var assembly: RefCounted = _assemblies.get(bytes.decode_s64(4))
		if assembly != null:
			if not assembly.fragment(bytes):
				_resync("chunk_integrity")
			else:
				_finish(assembly)
		elif _orphans.size() < 64:
			_orphans.append(bytes.duplicate())


func _finish(assembly: RefCounted = null) -> void:
	if assembly == null:
		assembly = _assembly  # Explicit single-assembly diagnostic/validation entry.
	if not assembly.complete():
		return
	var meta: Dictionary = assembly.metadata
	if _processing_inbox and phase == "live" and meta.kind == "delta":
		return
	if int(meta.transfer) <= _last_transfer:
		_assemblies.erase(meta.transfer)
		return
	var payload: Dictionary = assembly.finish()
	# An empty patch is a valid unchanged revision (e.g. a frozen party card).
	# Transfer errors are explicit; an empty keyframe still fails validation.
	if not assembly.last_error.is_empty():
		_resync("payload_integrity")
		return
	var candidate: Variant = payload
	if meta.base != 0:
		if not _baselines.has(meta.base):
			_resync("missing_baseline")
			return
		var baseline: Dictionary = _baseline_views.get(meta.base, {})
		if baseline.is_empty():
			baseline = codec.unpack(_baselines[meta.base])
			preload("res://scripts/game/game_server.gd").freeze(baseline)
		candidate = codec.apply_frozen(baseline, payload)
	if (
		not candidate is Dictionary
		or not codec.validate(candidate, definition)
		or candidate.epoch != epoch
		or candidate.revision != meta.revision
		or (not installed.is_empty() and candidate.revision < installed.revision)
	):
		_resync("invalid_state")
		return
	# A fresh validated snapshot supplies geometry again. A later gap can now
	# request its own recovery without waiting on an already completed transfer.
	_recovery_started = -1
	# Validate/stage before publishing any fields, roster, HUD or animation state.
	preload("res://scripts/game/game_server.gd").freeze(candidate)
	installed = candidate
	_retain_baseline(meta.transfer, candidate)
	_last_transfer = meta.transfer
	client.reference = candidate.owner.duplicate()
	client.session.level = definition.level
	client.session.tables = definition.tables
	if not candidate.owner.is_empty():
		var server_tick := -1.0
		if _clock_received > 0:
			server_tick = (
				_clock_stamp + float(clock_ms - _clock_received) * 1000.0 / prediction.STEP_USEC
			)
		prediction.install(candidate, definition, server_tick, rtt_ms)
		# A packet gap can safely neutralize authority input after the last
		# command was applied. Reassert current physical intent on the next view
		# update, without replaying old aim or duplicating still-pending commands.
		if (
			_commands.is_empty()
			and int(candidate.prediction.applied) >= _next_command - 1
			and not client._last_controls.is_empty()
			and (
				client._last_controls != candidate.prediction.controls
				or not is_equal_approx(client._last_rate, float(candidate.prediction.rate))
			)
		):
			client._last_controls.clear()
		presentation.install(candidate, definition, _presentation_tick(clock_ms))
		client.prediction = prediction
		client.receive(candidate)
		if meta.kind == "attach":
			client._event_watermark = maxi(client._event_watermark, candidate.watermark)
	_send(
		1,
		{
			"type": "ack",
			"transfer": meta.transfer,
			"hash": meta.hash,
			"state_hash": Wire._sha(_baselines[meta.transfer]).hex_encode()
		}
	)
	if meta.kind == "attach":
		phase = "live"
		# Do not send a clock probe from the pump that performs synchronous scene
		# attachment. Its timestamp predates loading, and the authority may still
		# be paused at the admission barrier until our ACK reaches it.
		_last_ping_ms = clock_ms
		var link := preload("res://scripts/network/command_link.gd").new()
		link.endpoint = weakref(self)
		client.link = link
		metrics.joins += 1
		metrics.last_attach_ms = clock_ms - _join_started
		if int(metrics.get("join_ms", -1)) < 0:
			metrics.join_ms = clock_ms - _join_started
		joined.emit()
	metrics.max_assembly = maxi(metrics.max_assembly, int(meta.raw) + int(meta.size))
	for transfer: int in _assemblies.keys():
		if transfer <= _last_transfer:
			_assemblies.erase(transfer)
	if not _assembly.metadata.is_empty() and int(_assembly.metadata.transfer) <= _last_transfer:
		_assembly = Transfer.new()
	_orphans = _orphans.filter(func(bytes): return bytes.decode_s64(4) > _last_transfer)


func _keyframe(id: int) -> void:
	var row: Dictionary = peers[id]
	if (
		row.phase == "live"
		and not row.owner.is_empty()
		and not row.neutral
		and authority.world.clock.tick_count >= int(row.next_input)
	):
		Admission.admit(authority.world, row.owner, {"held": 0xffffffff, "strafe": 0}, 0.0, [])
		row.neutral = true
	row.phase = "bootstrap" if row.owner.is_empty() else "attach"
	row.states.clear()
	row.base = {}
	row.base_id = 0
	_start(id, _state(row), "key" if row.owner.is_empty() else "attach", true)


func _start(id: int, state: Dictionary, kind: String, reliable: bool) -> void:
	var row: Dictionary = peers[id]
	row.encoding = -1
	var transfer := _next_transfer
	_next_transfer += 1
	var base: int = int(row.base_id) if not row.base.is_empty() else 0
	preload("res://scripts/game/game_server.gd").freeze(state)
	preload("res://scripts/game/game_server.gd").freeze(row.base)
	var job := preload("res://scripts/network/snapshot_publish_job.gd").new()
	job.configure(row.base, state, transfer, base, kind, reliable)
	if kind == "delta" and transport.supports_background_encoding():
		assert(_publication_jobs.size() < 4)
		var task := WorkerThreadPool.add_task(job.run)
		row.encoding = task
		_publication_jobs.append(
			{"task": task, "peer": id, "token": row.token, "epoch": epoch, "job": job}
		)
		metrics.max_publication_jobs = maxi(
			int(metrics.get("max_publication_jobs", 0)), _publication_jobs.size()
		)
		return
	job.run()
	_install_publication(row, job)


func _collect_publications() -> void:
	for index: int in range(_publication_jobs.size() - 1, -1, -1):
		var pending: Dictionary = _publication_jobs[index]
		if not WorkerThreadPool.is_task_completed(pending.task):
			continue
		WorkerThreadPool.wait_for_task_completion(pending.task)
		_publication_jobs.remove_at(index)
		var row: Dictionary = peers.get(pending.peer, {})
		if (
			row.is_empty()
			or row.token != pending.token
			or epoch != pending.epoch
			or authority == null
			or authority.world.actor_system.epoch != pending.epoch
			or row.encoding != pending.task
			or row.phase != "live"
		):
			metrics.discarded_publication_jobs = (
				int(metrics.get("discarded_publication_jobs", 0)) + 1
			)
			continue
		row.encoding = -1
		_install_publication(row, pending.job)


func _install_publication(row: Dictionary, job: RefCounted) -> void:
	if not job.last_error.is_empty():
		_fail(job.last_error)
		return
	var meta: Dictionary = job.result.meta
	var compressed: PackedByteArray = job.result.compressed
	metrics.max_publication_job_usec = maxi(
		int(metrics.get("max_publication_job_usec", 0)), job.elapsed_usec
	)
	metrics.max_publication_wait_usec = maxi(
		int(metrics.get("max_publication_wait_usec", 0)), Time.get_ticks_usec() - job.queued_usec
	)
	row.out = {
		"meta": meta,
		"chunks": Transfer.split(compressed, meta.transfer, meta.epoch),
		"cursor": 0,
		"reliable": job.reliable,
		"begin": false
	}
	# Retain 32 canonical baselines and at most eight shared immutable hot views.
	# Encoded coverage also bounds the hot cache; measured heap is tracked in
	# acceptance because Variant tree size is not its canonical byte size.
	row.states[meta.transfer] = {
		"state": job.result.state_bytes,
		"hash": meta.hash,
		"at": clock_ms,
		"kind": job.kind,
		"view": job.state
	}
	var views := 0
	var view_bytes := 0
	var ids: Array = row.states.keys()
	ids.reverse()
	for saved_id: int in ids:
		var saved: Dictionary = row.states[saved_id]
		if not saved.has("view"):
			continue
		views += 1
		view_bytes += saved.state.size()
		if views > 8 or view_bytes > 512 * 1024:
			saved.erase("view")
	while row.states.size() > MAX_BASELINES or _retained_bytes(row.states, true) > 2 * 1024 * 1024:
		row.states.erase(row.states.keys().front())
	row.started = clock_ms
	metrics["delta_bytes" if meta.base != 0 else "key_bytes"] += compressed.size()


func _service_transfer(id: int) -> void:
	var row: Dictionary = peers[id]
	if row.phase == "hello":
		if clock_ms - int(row.started) > 10000:
			transport.disconnect_peer(id)
		return
	if row.out.is_empty():
		return
	if clock_ms - int(row.started) > TRANSFER_MS:
		_keyframe(id)
	var out: Dictionary = row.out
	if not out.begin:
		_send(id, {"type": "begin", "meta": out.meta}, 3 if out.reliable else 2, out.reliable)
		out.begin = true
	# Pace bulk below live commands/events. Never enqueue a whole keyframe at once.
	if int(out.cursor) >= out.chunks.size() or clock_ms < int(row.chunks_at):
		return
	row.chunks_at = clock_ms + SEND_MS
	for i: int in range(2):
		if int(out.cursor) >= out.chunks.size():
			break
		transport.send_to(id, 3 if out.reliable else 2, out.chunks[out.cursor], out.reliable)
		out.cursor += 1


func _ack(id: int, message: Dictionary) -> void:
	var row: Dictionary = peers[id]
	if not message.get("transfer") is int or not row.states.has(message.transfer):
		return
	var saved: Dictionary = row.states[message.transfer]
	if (
		message.get("hash") != saved.hash
		or message.get("state_hash") != Wire._sha(saved.state).hex_encode()
	):
		metrics.rejected += 1
		return
	if message.transfer <= int(row.base_id):
		return
	if clock_ms - int(saved.at) > TRANSFER_MS:
		_keyframe(id)
		return
	row.base = saved.view if saved.has("view") else codec.unpack(saved.state)
	row.base_id = message.transfer
	row.verified += 1
	metrics.verified += 1
	if not row.out.is_empty() and int(row.out.meta.transfer) <= int(message.transfer):
		row.out = {}
	for transfer: int in row.states.keys():
		if transfer <= int(message.transfer):
			row.states.erase(transfer)
	if row.phase == "bootstrap":
		if not row.reclaim.is_empty() and authority.world.resolve_player(row.reclaim) != null:
			row.owner = row.reclaim.duplicate()
		else:
			row.owner = authority.world.bots.admit_human(authority.world)
		if row.owner.is_empty():
			transport.disconnect_peer(id)
			return
		returning.attach(authority.world, authority.world.resolve_player(row.owner), row.get("principal", {}), row.reclaim.is_empty())
		if authority.world.players.size() == 1:
			authority.session.player = authority.world.resolve_player(row.owner)
		roster_changed()
		row.phase = "attach"
		_start(id, _state(row), "attach", true)
	elif row.phase == "attach":
		row.reclaim = {}
		row.phase = "live"
		# Keep each peer's 20-ms target, spreading the four serialization and
		# fragment pulses by seat instead of one four-client work burst.
		var player: RefCounted = authority.world.resolve_player(row.owner)
		row.publish_at = clock_ms + posmod(int(player.seat) * (SEND_MS / 4) - clock_ms, SEND_MS)
		row.last_input = clock_ms
		metrics.joins += 1
		_last_tally_publish = clock_ms - 500


func _publish(id: int) -> void:
	var row: Dictionary = peers[id]
	if int(row.get("encoding", -1)) >= 0 or _publication_jobs.size() >= 4:
		return  # Bounded replaceable views, never a queue of stale snapshots.
	if not row.out.is_empty() and int(row.out.cursor) < row.out.chunks.size():
		return  # Finish an atomic multipart send; never wait a round trip to send live state.
	_start(id, _state(row), "delta", false)
	# Keep the original phase after a late frame. Scheduling from "now" makes
	# overdue peers converge on one deadline and perpetuates serialization spikes.
	# Missed replaceable views are not replayed; the next deadline is within 20 ms.
	@warning_ignore("integer_division")
	row.publish_at += (maxi(0, clock_ms - int(row.publish_at)) / SEND_MS + 1) * SEND_MS


func submit(controls: Dictionary, rate: float, aim: Array) -> bool:
	if (
		phase != "live"
		or not Admission.valid_controls(controls)
		or not is_finite(rate)
		or absf(rate) > 65536.0
		or aim.size() > 48
	):
		return false
	var fixed: Array = []
	for delta: Variant in aim:
		if not (delta is int or delta is float) or not is_finite(float(delta)):
			return false
		fixed.append(roundi(fmod(float(delta), 16384.0) * 65536.0))
	# Merge only an unsent packet with unchanged held state/rate. The predictor
	# sees each rounded event now; sent sequences are immutable for deduplication.
	var sequence := _next_command
	var merge: bool = (
		not _commands.is_empty()
		and not bool(_commands.back().get("sent", false))
		and _commands.back().controls == controls
		and _commands.back().rate == rate
	)
	if merge:
		sequence = int(_commands.back().sequence)
		preload("res://scripts/network/rounded_aim.gd").append(_commands.back().aim, fixed)
	else:
		if _commands.size() >= 64:
			return false
		_commands.append(
			{
				"sequence": sequence,
				"controls": controls.duplicate(),
				"rate": rate,
				"aim": fixed.duplicate(),
				"sent": false
			}
		)
		_next_command += 1
	prediction.input(
		{"sequence": sequence, "controls": controls.duplicate(), "rate": rate, "aim": fixed}
	)
	return true


func _send_commands() -> void:
	# Cycle through the bounded outstanding window rather than waiting an RTT
	# for the first four commands before newer mouse samples can enter flight.
	# Every full batch fits one checked datagram, including 48 samples/command.
	var ordered: Array = []
	for command: Dictionary in _commands:
		if int(command.sequence) > _command_cursor:
			ordered.append(command)
	for command: Dictionary in _commands:
		if int(command.sequence) <= _command_cursor:
			ordered.append(command)
	var bundle: Array = []
	for command: Dictionary in ordered.slice(0, 4):
		var packet := command.duplicate()
		packet.erase("sent")
		bundle.append(packet)
		command.sent = true
		_command_cursor = int(command.sequence)
	# An empty checked batch remains the held-state heartbeat.
	transport.send_to(1, 1, Commands.new().encode(token, bundle), false)


func _accept_commands(row: Dictionary, message: Dictionary) -> void:
	if message.size() != 3 or not message.get("items") is Array or message.items.size() > 4:
		metrics.rejected += 1
		return
	var staged := {}
	for command: Variant in message.items:
		if (
			not command is Dictionary
			or command.size() != 4
			or not command.has_all(["sequence", "controls", "rate", "aim"])
			or not command.sequence is int
			or command.sequence <= 0
			or command.sequence > int(row.finalized) + 64
			or not command.controls is Dictionary
			or not Admission.valid_controls(command.controls)
			or not command.rate is float
			or not is_finite(command.rate)
			or absf(command.rate) > 65536
			or not command.aim is Array
			or command.aim.size() > 48
		):
			metrics.rejected += 1
			return
		for delta: Variant in command.aim:
			if not delta is int or delta <= -0x40000000 or delta >= 0x40000000:
				return
		if command.sequence > int(row.finalized):
			if row.commands.has(command.sequence) and row.commands[command.sequence] != command:
				return
			if staged.has(command.sequence) and staged[command.sequence] != command:
				return
			staged[command.sequence] = command.duplicate(true)
	row.commands.merge(staged)
	row.last_input = clock_ms


func _service_commands(id: int) -> void:
	var row: Dictionary = peers[id]
	if row.phase != "live":
		if (
			row.phase == "attach"
			and not row.owner.is_empty()
			and not row.neutral
			and authority.world.clock.tick_count >= int(row.next_input)
		):
			Admission.admit(authority.world, row.owner, {"held": 0xffffffff, "strafe": 0}, 0.0, [])
			row.neutral = true
		return
	var previous: int = row.finalized
	var budget := 4
	while budget > 0 and not row.commands.is_empty():
		var next: int = row.finalized + 1
		if not row.commands.has(next):
			if row.gap < 0:
				row.gap = clock_ms
			if clock_ms - int(row.gap) < GAP_MS:
				break
			var ordered: Array = row.commands.keys()
			ordered.sort()
			row.finalized = int(ordered.front()) - 1
			row.gap = -1
			continue
		var command: Dictionary = row.commands[next]
		if (
			command.controls != row.sent_controls
			and authority.world.clock.tick_count < int(row.next_input)
		):
			break
		var semantic_sequence: int = authority.world.admission_state.next_sequence
		var deltas: Array = command.aim.map(func(value): return float(value) / 65536.0)
		if (
			authority.campaign.paused
			or not Admission.admit(
				authority.world, row.owner, command.controls, command.rate, deltas
			)
		):
			break
		row.commands.erase(next)
		row.finalized = next
		# Each held/release command sees an original input opportunity before
		# the next one. Packet bundling cannot collapse a brief fire/use edge.
		@warning_ignore("integer_division")
		var accepted_ordinal: int = (
			authority.world.clock.tick_count
			+ authority.world.clock._phase / authority.world.clock._threshold
		)
		var previous_action: int = (
			int(row.receipts.back().action) if not row.receipts.is_empty() else 0
		)
		if (int(command.controls.held) & 16) == 0 and (int(row.sent_controls.held) & 16) != 0:
			previous_action = int(command.sequence)
		row.receipts.append(
			{
				"sequence": next,
				"ordinal": accepted_ordinal,
				"semantic": semantic_sequence,
				"action": previous_action
			}
		)
		while row.receipts.size() > 64:
			row.receipts.pop_front()
		if command.controls != row.sent_controls:
			row.next_input = accepted_ordinal + 4
		row.sent_controls = command.controls.duplicate()
		row.neutral = false
		row.gap = -1
		budget -= 1
	if (
		clock_ms - int(row.last_input) > HOLD_MS
		and not row.neutral
		and authority.world.clock.tick_count >= int(row.next_input)
	):
		Admission.admit(authority.world, row.owner, {"held": 0xffffffff, "strafe": 0}, 0.0, [])
		row.neutral = true
	if row.finalized != previous:
		_send(id, {"type": "finalized", "sequence": row.finalized})


func _effect(event: Dictionary) -> void:
	var weapon_id: Dictionary = {}
	if (
		event.category == "audio"
		and event.payload.get("cue") == "weapon"
		and event.payload.get("emitter", {}) == _weapon_context.get("identity", {}).get("player", {})
		and not _weapon_context.is_empty()
		and _weapon_context.ordinal == event.ordinal
		and event.payload.get("source_id", -1) in _weapon_context.sounds
	):
		weapon_id = _weapon_context.identity.duplicate(true)
		_weapon_context.sounds.erase(event.payload.source_id)
		if _weapon_context.sounds.is_empty():
			_weapon_context = {}
	for id: int in peers:
		var row: Dictionary = peers[id]
		if row.phase == "live" and row.events.size() < 128:
			var outgoing := event.duplicate(true)
			if not weapon_id.is_empty():
				outgoing.weapon_id = weapon_id.duplicate(true)
			row.events.append(outgoing)
		# Transient effects never serve as the only record of a durable outcome.
		while not row.events.is_empty():
			var item: Dictionary = row.events.pop_front()
			var bytes := Wire.new().encode({"type": "events", "token": row.token, "events": [item]})
			if bytes.size() <= 1000:
				transport.send_to(id, 4, bytes, false)


func _drain_events() -> void:
	if phase != "live" or installed.is_empty():
		return
	_events.sort_custom(func(a, b): return int(a.sequence) < int(b.sequence))
	var future: Array = []
	for event: Dictionary in _events:
		if event.ordinal <= installed.revision:
			if (
				event.has("weapon_id")
				and _valid_shot(event.weapon_id)
				and event.category == "audio"
				and prediction.feedback.suppress_audio(
					event.weapon_id, int(event.payload.get("source_id", -1))
				)
			):
				client._event_watermark = maxi(client._event_watermark, int(event.sequence))
				continue
			if (
				event.has("weapon_id")
				and _valid_shot(event.weapon_id)
				and event.weapon_id.player == client.reference
				and event.category == "audio"
				and int(event.sequence) > client._event_watermark
			):
				prediction.feedback.authority_audio(
					event.weapon_id, int(event.payload.get("source_id", -1))
				)
			client.receive_event(event)
		elif future.size() < 128:
			future.append(event)
	_events = future


func _resync(reason: String = "requested") -> void:
	# Do not cancel our own reliable recovery before its bounded assembly window.
	# Keep the live input/aim path available; translation already freezes safely
	# when committed collision history is missing. Integrity failures cannot
	# publish partial state while this request is pending.
	if _recovery_started >= 0 and clock_ms - _recovery_started < TRANSFER_MS:
		return
	_recovery_started = clock_ms
	if (
		reason
		not in [
			"requested",
			"assembly_timeout",
			"prediction_window",
			"chunk_integrity",
			"payload_integrity",
			"missing_baseline",
			"invalid_state"
		]
	):
		reason = "requested"
	if not metrics.has("recovery_reasons"):
		metrics.recovery_reasons = {}
	metrics.recovery_reasons[reason] = int(metrics.recovery_reasons.get(reason, 0)) + 1
	metrics.resyncs += 1
	_assembly = Transfer.new()
	_assemblies.clear()
	_orphans.clear()
	_send(1, {"type": "resync"})


func _staged_bytes() -> int:
	var total := 0
	for assembly: RefCounted in _assemblies.values():
		total += int(assembly.metadata.raw) + int(assembly.metadata.size)
	return total


func _fail(reason: String) -> void:
	last_error = reason
	phase = "rejected"
	rejected.emit(reason)


func _retain_baseline(transfer: int, state: Dictionary) -> void:
	_baselines[transfer] = codec.pack(state)
	if state.is_read_only():
		_baseline_views[transfer] = state
	# Recovery can invalidate canonical bytes independently of expanded views.
	# The derived cache must never outlive the canonical baseline it represents.
	for id: int in _baseline_views.keys():
		if not _baselines.has(id):
			_baseline_views.erase(id)
	while _baselines.size() > MAX_BASELINES or _retained_bytes(_baselines, false) > 2 * 1024 * 1024:
		var oldest: int = _baselines.keys().front()
		_baselines.erase(oldest)
		_baseline_views.erase(oldest)
	while _baseline_views.size() > 8:
		_baseline_views.erase(_baseline_views.keys().front())
	var hot_bytes := 0
	var hot_ids: Array = _baseline_views.keys()
	hot_ids.reverse()
	for id: int in hot_ids:
		hot_bytes += _baselines[id].size()
		if hot_bytes > 512 * 1024:
			_baseline_views.erase(id)


func _retained_bytes(states: Dictionary, wrapped: bool) -> int:
	var total := 0
	for value: Variant in states.values():
		var bytes: PackedByteArray = value.state if wrapped else value
		total += bytes.size()
	return total


## Local authority capability only. No administration message is accepted on wire.
func ban_player(reference: Dictionary) -> bool:
	last_error = ""
	if authority == null or authority.world._atomic_depth != 0:
		last_error = "Only the host can ban players"
		return false
	var world: RefCounted = authority.world
	if reference == local_host_reference or world.resolve_player(reference) == null or world.bots.is_bot(reference):
		last_error = "Select a connected remote player"
		return false
	for id: int in peers:
		var row: Dictionary = peers[id]
		if reference != (row.owner if not row.owner.is_empty() else row.reclaim): continue
		var principal: Dictionary = row.get("principal", {})
		if principal.is_empty(): break
		if transport.identity_key != null and principal.key == preload("res://scripts/network/network_auth.gd").fingerprint(transport.identity_key):
			break
		var player: RefCounted = world.resolve_player(reference)
		var labels := preload("res://scripts/presentation/participant_labels.gd")
		var name: String = principal.name if not str(principal.name).is_empty() else "Player %d" % labels.ordinal(labels.roster(world), player.seat, false, reference)
		if not transport.bans.ban(principal.key, name):
			last_error = transport.bans.last_error
			return false
		# Persist first. The normal departure path retains earned score, allowing
		# an explicitly unbanned player to resume within this same host session.
		transport.reject_peer(id, "Player banned")
		return true
	last_error = "Player is no longer connected or has no verified identity"
	return false


func unban_player(key: String) -> bool:
	last_error = ""
	if authority == null or authority.world._atomic_depth != 0:
		last_error = "Only the host can unban players"
		return false
	if not transport.bans.unban(key):
		last_error = transport.bans.last_error
		return false
	return true


func close() -> void:
	# Drain only this endpoint's owned wire tasks before releasing their frozen
	# input references. Shutdown never leaves a worker using a freed script.
	for pending: Dictionary in _publication_jobs:
		WorkerThreadPool.wait_for_task_completion(pending.task)
	_publication_jobs.clear()
	if authority != null:
		for row: Dictionary in peers.values():
			authority.world.remove_player(row.owner)
		if authority.world.weapon_feedback.is_connected(_weapon_feedback):
			authority.world.weapon_feedback.disconnect(_weapon_feedback)
		if authority.effect.is_connected(_effect):
			authority.effect.disconnect(_effect)
	transport.close()
	if _score_system != null and _score_system.opponent_killed.is_connected(_opponent_killed):
		_score_system.opponent_killed.disconnect(_opponent_killed)
	_score_system = null
	live_tally.clear()
	live_scores.reset()
	returning.reset_campaign()
	peers.clear()
	_baseline_views.clear()
	phase = "disconnected"


func _exit_tree() -> void:
	close()


func _state(row: Dictionary) -> Dictionary:
	var state: Dictionary = codec.project(authority, row.owner, true)
	if coop != null and coop.session.enabled:
		state.party.session = {
			"mode": coop.session.mode, "lobby": coop.session.lobby, "map": coop.session.map
		}
	var active := {"sequence": 0, "action": 0}
	for receipt: Dictionary in row.receipts:
		if (
			receipt.semantic <= authority.world.admission_state.applied
			and receipt.ordinal <= state.revision
		):
			active = receipt
	state.prediction.applied = int(active.sequence)
	state.prediction.finalized = int(row.finalized)
	state.prediction.action = int(active.action)
	state.prediction.shot_index = int(row.shot_counts.get(int(active.action), 0))
	state.prediction.receipts = []
	for receipt: Dictionary in row.receipts:
		state.prediction.receipts.append({"sequence": receipt.sequence, "ordinal": receipt.ordinal})
	return state


func _bind_feedback() -> void:
	if not authority.world.weapon_feedback.is_connected(_weapon_feedback):
		authority.world.weapon_feedback.connect(_weapon_feedback)
	if _score_system != authority.world.actor_system:
		if _score_system != null and _score_system.opponent_killed.is_connected(_opponent_killed):
			_score_system.opponent_killed.disconnect(_opponent_killed)
		_score_system = authority.world.actor_system
		_score_system.opponent_killed.connect(_opponent_killed)


func _opponent_killed(shooter: int, victim: int) -> void:
	var attacker: RefCounted
	var target: RefCounted
	for player: RefCounted in authority.world.players:
		if player.handle == shooter:
			attacker = player
		if player.handle == victim:
			target = player
	if attacker != null and target != null:
		live_scores.record_kill(attacker.player_ref(), target.player_ref())


func _publish_tally() -> void:
	_last_tally_publish = clock_ms
	_tally_sequence += 1
	var pings := {}
	for id: int in peers:
		var row: Dictionary = peers[id]
		var player: RefCounted = authority.world.resolve_player(row.owner)
		if player != null and clock_ms - int(row.ping_received) <= 2000:
			pings[player.seat] = transport.latency_ms(id) if transport.has_method("latency_ms") else -1
	var versus: bool = authority.world.level.get_meta("battle_mode", false)
	var connected: Array = authority.world.players.filter(func(player):
		return authority.world.bots.is_bot(player.player_ref()) or peers.values().any(func(peer): return peer.owner == player.player_ref()))
	var rows := live_scores.project(connected, versus, pings, local_host_reference)
	if not authority.world.vs_state.is_empty():
		for projected: Array in rows:
			var entry: Dictionary = preload("res://scripts/game/vs_match.gd").row(authority.world, int(projected[0]) - 1)
			projected[4] = int(entry.get("kills", 0))
	for id: int in peers:
		if peers[id].phase == "live":
			_send(id, {"type": "tally", "epoch": epoch, "sequence": _tally_sequence,
				"mode": "versus" if versus else "coop", "rows": rows}, 1, false)


## Expose only members of the installed public roster. Recycled seats cannot
## display the departed owner's score/colour while snapshots cross in flight.
func score_rows() -> Array:
	if phase != "live" or installed.is_empty() or live_tally.is_empty():
		return []
	var versus: bool = definition.level.get_meta("battle_mode", false)
	if live_tally.mode != ("versus" if versus else "coop"):
		return []
	var result := []
	for row: Array in live_tally.rows:
		if not installed.roster.any(func(member):
			return member.reference == {"id": row[0], "generation": row[1]} and member.seat == row[2]):
			continue
		var displayed := row.duplicate()
		var member: Dictionary = installed.roster.filter(func(candidate): return candidate.reference=={"id":row[0],"generation":row[1]})[0]
		if member.get("controller","human")=="bot": displayed[5]=-3
		elif displayed[5]==-3: continue
		if clock_ms - _tally_received > 2000 and displayed[5] not in [-2,-3]:
			displayed[5] = -1
		if member.has("name"): displayed.append(member.name)
		result.append(displayed)
	result.sort_custom(func(a, b): return a[4] > b[4] if a[4] != b[4] else a[2] < b[2])
	return result


func _weapon_feedback(value: Dictionary) -> void:
	var firing: Dictionary = {}
	for row: Dictionary in peers.values():
		if row.owner == value.player:
			firing = row
			break
	if firing.is_empty():
		_weapon_context = {}
		return
	var state := _state(firing)
	var action: int = state.prediction.action
	var index: int = int(firing.shot_counts.get(action, 0)) + 1
	firing.shot_counts[action] = index
	while firing.shot_counts.size() > 64:
		firing.shot_counts.erase(firing.shot_counts.keys().front())
	var identity := {
		"epoch": epoch, "player": value.player.duplicate(), "action": action, "index": index
	}
	_weapon_context = {
		"identity": identity, "ordinal": value.ordinal, "sounds": value.sounds.duplicate()
	}
	for id: int in peers:
		if peers[id].phase == "live":
			_send(
				id,
				{
					"type": "weapon",
					"identity": identity,
					"weapon": value.weapon,
					"entities": value.entities,
					"ordinal": value.ordinal
				}
			)


func _valid_shot(value: Variant) -> bool:
	return (
		value is Dictionary
		and value.size() == 4
		and value.get("epoch") == epoch
		and codec._reference(value.get("player"))
		and value.get("action") is int
		and value.action >= 0
		and value.get("index") is int
		and value.index > 0
	)


func _local_cue(request: Dictionary) -> void:
	client.audio_requested.emit(request.duplicate(true))


func render_state() -> Dictionary:
	var shown: Dictionary = presentation.sample(
		prediction.presentation_pose(),
		prediction.feedback.sample(
			float(prediction.tick) + float(prediction.phase) / prediction.T, installed
		)
	)
	if not shown.is_empty():
		prediction.feedback.attach_confirmed(
			shown.actors,
			installed,
			definition,
			float(prediction.tick) + float(prediction.phase) / prediction.T
		)
	return shown


func _valid_entities(value: Variant) -> bool:
	if not value is Array or value.size() > 6:
		return false
	for item: Variant in value:
		if (
			not item is Array
			or item.size() != 2
			or not item[0] is int
			or item[0] < 0
			or item[0] >= 180
			or not item[1] is int
			or item[1] < 1
			or item[1] > 0xffffffff
		):
			return false
	return true


func advance_authority_usec(elapsed: int) -> int:
	return coop.advance_usec(elapsed) if coop != null else authority.advance_usec(elapsed)


func party_action(action: String) -> void:
	if (
		authority == null
		and phase == "live"
		and action in ["next", "continue", "finished", "scores"]
	):
		_party_request = action
		_party_sent = -1000
