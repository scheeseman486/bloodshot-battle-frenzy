extends RefCounted
## Local terminal grammar only. Execute at a completed authority boundary.
signal shutdown_requested
const Admin = preload("res://scripts/network/host_administration.gd")
const Labels = preload("res://scripts/presentation/participant_labels.gd")
const Model = preload("res://scripts/frontend/network_session_menu_model.gd")
const LINE_LIMIT := 256
const QUEUE_LIMIT := 32
const PER_FRAME := 4
var endpoint: Node
var _line := ""
var _discard := false
var _queue: Array[String] = []
var _closed := false
var _bot_ids: Dictionary = {}
var _next_bot := 1


func feed(bytes: PackedByteArray, eof: bool = false) -> PackedStringArray:
	var messages := PackedStringArray()
	for byte: int in bytes:
		if byte == 13: continue # Accept Windows CRLF and Unix LF identically.
		if byte == 10:
			if not _discard and not _line.strip_edges().is_empty():
				if _queue.size() < QUEUE_LIMIT: _queue.append(_line)
				else: messages.append("ERROR: Console queue full; command discarded")
			_line = ""
			_discard = false
		elif byte in [8, 127]:
			_line = _line.left(maxi(0, _line.length() - 1))
		elif not _discard:
			if (byte < 32 and byte != 9) or byte > 126:
				_discard = true
				messages.append("ERROR: Commands must use printable ASCII")
			elif _line.length() >= LINE_LIMIT:
				_discard = true
				messages.append("ERROR: Command too long; discarded through newline")
			else: _line += char(byte)
	if eof and not _closed:
		_closed = true
		if not _discard and not _line.strip_edges().is_empty() and _queue.size() < QUEUE_LIMIT:
			_queue.append(_line)
		_line = ""
		messages.append("Console input closed; server continues running")
	# A pasted flood must not turn thousands of discarded lines into a long
	# synchronous terminal write. Input/queue bounds also apply to diagnostics.
	if messages.size() > 8:
		var suppressed := messages.size() - 8
		messages.resize(8)
		messages.append("ERROR: %d additional input errors suppressed" % suppressed)
	return messages


func drain() -> PackedStringArray:
	var messages := PackedStringArray()
	var count := 0
	while count < PER_FRAME and not _queue.is_empty():
		messages.append_array(execute(_queue.pop_front()))
		count += 1
	return messages


static func help_text() -> PackedStringArray:
	return PackedStringArray([
		"Dedicated server commands (local terminal only):",
		"  help | status | players | maps | bans | slots",
		"  kick <connection-id>       Disconnect a human; allows rejoin",
		"  ban <connection-id>        Persist key ban, then disconnect",
		"  unban <full-key>           Remove a key listed by bans",
		"  mode coop|versus          Change mode and enter its lobby",
		"  map level-1..level-16|arena-1..arena-3 | lobby",
		"  limit 5|10|15|20|30|50     VS kill limit; restarts active match",
		"  rematch                   Restart the current VS arena",
		"  bots 0..3                 Bot count, in lobby or VS play",
		"                            A human must be connected first",
		"  difficulty easy|normal|hard  VS bot difficulty",
		"  remove-bot <bot-id>       Remove a bot, in lobby or VS play",
		"  revive-bot <bot-id>       Spend a co-op continue on an exhausted bot",
		"  save 1..5 | load 1..5     Host co-op save slots",
		"  admins                    List authorized public fingerprints",
		"  admin grant <connection-id> | admin add <full-key>",
		"  admin revoke <full-key> | admin reload",
		"  profile <public-hostname>  Write public user://server-profile.json",
		"  quit                      Disconnect everyone and stop server",
		"Use players for stable connection/bot IDs; keys are public fingerprints.",
		"Mode/map/lobby/rematch reset the match as in the in-game host menu."
	])


func execute(line: String) -> PackedStringArray:
	var words := line.strip_edges().replace("\t", " ").split(" ", false)
	if words.is_empty(): return PackedStringArray()
	if line.length() > LINE_LIMIT: return PackedStringArray(["ERROR: Command too long"])
	var command := words[0].to_lower()
	if command == "help" and words.size() == 1: return help_text()
	if endpoint == null or endpoint.authority == null:
		return PackedStringArray(["ERROR: Console requires a local server"])
	if command == "admins" and words.size() == 1:
		var output := PackedStringArray(["ADMINS (public key fingerprints):"])
		var acl: RefCounted = endpoint.transport.admin_acl
		if not acl.healthy: output.append("  DISABLED: " + acl.last_error)
		for key: String in acl.entries: output.append("  " + key + "  " + str(acl.entries[key]))
		if acl.entries.is_empty(): output.append("  None")
		return output
	if command == "admin": return _admin(words)
	if command == "profile" and words.size() == 2:
		if not preload("res://scripts/network/admin_profile.gd").export_server(endpoint.transport, words[1]):
			return PackedStringArray(["ERROR: Cannot export public profile; use a valid hostname/IP"])
		return PackedStringArray(["OK: Public profile saved to " + ProjectSettings.globalize_path("user://server-profile.json"),
			"Certificate SHA-256 (PEM text): " + endpoint.transport._certificate_text.sha256_text()])
	if command in ["status", "players", "maps", "bans", "slots", "lobby", "rematch", "quit"]:
		if words.size() != 1: return _usage()
		match command:
			"status":
				var session: Dictionary = endpoint.coop.session
				var bots: RefCounted = endpoint.authority.world.bots
				return PackedStringArray(["STATUS mode=%s map=%s phase=%s humans=%d bots=%d limit=%d difficulty=%s tick=%d secure_admin=%s" % [
					session.mode, session.map, endpoint.authority.world.vs_state.get("phase", "playing"),
					endpoint.peers.size(), bots.count(endpoint.authority.world), endpoint.coop.kill_limit,
					["easy", "normal", "hard"][int(bots.state.difficulty)], endpoint.authority.world.clock.tick_count, "yes" if endpoint.transport.admin_secure else "no"
				]])
			"players": return _players()
			"maps":
				var output := PackedStringArray(["MAPS for " + str(endpoint.coop.session.mode) + ": lobby"])
				for row: Dictionary in Model.maps(endpoint.coop.session.mode): output.append("  " + row.id + "  " + row.label)
				return output
			"bans":
				var output := PackedStringArray(["BANS (public key fingerprints):"])
				for row: Dictionary in endpoint.transport.bans.rows(): output.append("  %s  %s" % [row.key, row.name])
				if output.size() == 1: output.append("  None")
				return output
			"slots":
				var slots := preload("res://scripts/persistence/save_slots.gd").new()
				slots.directory = "user://network-saves"
				var output := PackedStringArray(["CO-OP SAVE SLOTS:"])
				for slot: int in range(1, slots.COUNT + 1):
					var row := slots.describe(slot)
					output.append("  %d  %s" % [slot, ("Level %d" % row.level if row.valid else row.error) if row.exists else "Empty"])
				return output
			"quit":
				_queue.clear()
				shutdown_requested.emit()
				return PackedStringArray(["OK: Stopping server"])
			_: return _action(command)
	if words.size() != 2: return _usage()
	var value := words[1]
	match command:
		"kick", "ban":
			if value.is_valid_int() and endpoint.transport.identities.get(int(value), {}).get("purpose") == "manage":
				var id := int(value)
				var principal: Dictionary = endpoint.transport.identities[id]
				if principal.key == preload("res://scripts/network/network_auth.gd").fingerprint(endpoint.transport.identity_key): return PackedStringArray(["ERROR: Cannot moderate the local owner identity"])
				if command == "ban":
					if not endpoint.transport.bans.ban(principal.key, principal.name): return PackedStringArray(["ERROR: " + endpoint.transport.bans.last_error])
					for connection: int in endpoint.transport.identities.keys():
						if endpoint.transport.identities[connection].key == principal.key: endpoint.transport.reject_peer(connection, "Player banned")
				else: endpoint.transport.reject_peer(id, "Player kicked")
				return PackedStringArray(["OK: " + command])
			if not value.is_valid_int() or not endpoint.peers.has(int(value)):
				return PackedStringArray(["ERROR: Unknown connection ID; use players"])
			var row: Dictionary = endpoint.peers[int(value)]
			var reference: Dictionary = row.owner if not row.owner.is_empty() else row.reclaim
			if reference.is_empty(): return PackedStringArray(["ERROR: Player has not finished joining"])
			return _action(command, reference)
		"unban": return _action("unban", value)
		"mode":
			if value not in ["coop", "versus"]: return _usage()
			return _action("mode", value)
		"map": return _action("map", value)
		"limit", "bots", "save", "load":
			if not value.is_valid_int(): return _usage()
			var number := int(value)
			if command in ["save", "load"] and number not in range(1, 6): return _usage()
			if command == "bots" and number > 0 and endpoint.peers.is_empty():
				return PackedStringArray(["ERROR: Connect a human player before adding bots"])
			return _action("bot_count" if command == "bots" else command, number)
		"difficulty":
			var level := ["easy", "normal", "hard"].find(value)
			if level < 0: return _usage()
			return _action("bot_difficulty", level)
		"remove-bot", "revive-bot":
			for row: Dictionary in player_rows():
				if row.id == value and row.bot:
					return _action("bot_remove" if command == "remove-bot" else "revive_bot", row.reference)
			return PackedStringArray(["ERROR: Unknown bot ID; use players"])
	return PackedStringArray(["ERROR: Unknown command; type help"])


func _action(action: String, value: Variant = null) -> PackedStringArray:
	var result := Admin.execute(endpoint, action, value)
	return PackedStringArray(["OK: " + action if result.ok else "ERROR: " + str(result.error)])


func _admin(words: PackedStringArray) -> PackedStringArray:
	var acl: RefCounted = endpoint.transport.admin_acl
	var accepted := false
	if words.size() == 2 and words[1] == "reload":
		accepted = acl.reload()
		if accepted and endpoint.admin_service != null:
			endpoint.admin_service.configure(endpoint) # Recheck repaired audit storage too.
			accepted = endpoint.admin_service.healthy
	elif words.size() == 3:
		match words[1]:
			"add": accepted = acl.grant(words[2])
			"revoke": accepted = acl.revoke(words[2])
			"grant":
				if words[2].is_valid_int() and endpoint.transport.identities.has(int(words[2])):
					var principal: Dictionary = endpoint.transport.identities[int(words[2])]
					accepted = acl.grant(principal.key, principal.name)
				else: return PackedStringArray(["ERROR: Unknown verified connection ID; use players"])
	else: return _usage()
	return PackedStringArray(["OK: admin " + words[1] if accepted else "ERROR: " + (acl.last_error if not acl.last_error.is_empty() else "Admin/audit storage requires local repair")])


static func _usage() -> PackedStringArray:
	return PackedStringArray(["ERROR: Invalid arguments; type help"])


func player_rows() -> Array:
	var world: RefCounted = endpoint.authority.world
	var roster := Labels.roster(world)
	var output := []
	var current_bots := {}
	for connection: int in endpoint.peers:
		var row: Dictionary = endpoint.peers[connection]
		var reference: Dictionary = row.owner if not row.owner.is_empty() else row.reclaim
		var player: RefCounted = world.resolve_player(reference)
		var address: Dictionary = endpoint.transport.remote_endpoint(connection)
		output.append({"id": str(connection), "bot": false, "reference": reference,
			"name": str(row.get("principal", {}).get("name", "")), "seat": player.seat + 1 if player != null else 0,
			"ip": address.get("address", "?"), "port": address.get("port", 0),
			"key": str(row.get("principal", {}).get("key", "")), "phase": row.phase})
	for player: RefCounted in world.players:
		var reference: Dictionary = player.player_ref()
		if not world.bots.is_bot(reference): continue
		var identity := "%s:%d:%d" % [str(world.actor_system.epoch), int(reference.id), int(reference.generation)]
		if not _bot_ids.has(identity):
			_bot_ids[identity] = "B%d" % _next_bot
			_next_bot += 1
		current_bots[identity] = _bot_ids[identity]
		output.append({"id": _bot_ids[identity], "bot": true, "reference": reference,
			"name": Labels.label(roster, player.seat, true, reference), "seat": player.seat + 1,
			"ip": "local", "port": 0, "key": "none", "phase": "bot"})
	for connection: int in endpoint.transport.identities:
		var principal: Dictionary = endpoint.transport.identities[connection]
		if principal.get("purpose") != "manage": continue
		var address: Dictionary = endpoint.transport.remote_endpoint(connection)
		output.append({"id": str(connection), "bot": false, "reference": {},
			"name": principal.name, "seat": 0, "ip": address.get("address", "?"),
			"port": address.get("port", 0), "key": principal.key, "phase": "management"})
	_bot_ids = current_bots
	return output


func _players() -> PackedStringArray:
	var rows := player_rows()
	var output := PackedStringArray(["PLAYERS (ID / name / seat / address / public key / state):"])
	for row: Dictionary in rows:
		output.append("  %s  %s  seat=%d  [%s]:%d  key=%s  %s" % [
			row.id, row.name if not row.name.is_empty() else "PLAYER", row.seat, row.ip, row.port, row.key, row.phase])
	if rows.is_empty(): output.append("  None")
	return output
