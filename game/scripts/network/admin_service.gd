extends RefCounted
## Server-owned, directed administration, serviced only at authority boundaries.
## Every execution rechecks the proven identity, current ACL, ban and world epoch.
const Protocol = preload("res://scripts/network/admin_protocol.gd")
const Host = preload("res://scripts/network/host_administration.gd")
const Auth = preload("res://scripts/network/network_auth.gd")
const Labels = preload("res://scripts/presentation/participant_labels.gd")
const Slots = preload("res://scripts/persistence/save_slots.gd")
const MAX_QUEUE := 4
const MAX_CACHE := 16
const MAX_AUDIT := 128
const CONNECTION_RATE := 8
const PRINCIPAL_RATE := 16  # One play plus one management connection per key.
const GLOBAL_RATE := 32
var endpoint: Node
var rows: Dictionary = {}
var audit: Array = []
var audit_path := ""
var healthy := true
var _global := {"at": 0, "count": 0}
var _budgets: Dictionary = {}
var _cursor := 0


func configure(owner: Node) -> void:
	endpoint = owner
	healthy = true
	audit.clear()
	if not endpoint.transport.admin_acl.path.is_empty():
		audit_path = "user://network-private/admin-audit.json"
	if not audit_path.is_empty() and FileAccess.file_exists(audit_path):
		var file := FileAccess.open(audit_path, FileAccess.READ)
		if file == null or file.get_length() > 65536:
			healthy = false
		else:
			var value: Variant = preload("res://scripts/network/bounded_json.gd").decode(
				file.get_buffer(file.get_length()), 65536, 6, true
			)
			if (
				not value is Dictionary
				or value.size() != 2
				or not Protocol.whole(value.get("version"), 1, 1)
				or not value.get("entries") is Array
				or value.entries.size() > MAX_AUDIT
			):
				healthy = false
			else:
				# Retain only the documented primitive audit shape.
				for entry: Variant in value.entries:
					if (
						not entry is Dictionary
						or entry.size() != 6
						or not entry.has_all(["at", "key", "action", "id", "result", "target"])
						or not Protocol.text(entry.target, 64)
						or not Protocol.Bans.valid_key(entry.key)
						or not entry.action is String
						or entry.action not in Protocol.ACTIONS
						or not Protocol.whole(entry.id, 1)
						or not entry.at is String
						or entry.at.length() > 32
						or not entry.result is String
						or entry.result not in ["pending", "ok", "denied"]
					):
						healthy = false
						break
				if healthy:
					audit = value.entries


func _authorized(id: int) -> bool:
	var transport: Node = endpoint.transport
	var principal: Dictionary = transport.identities.get(id, {})
	return (
		healthy
		and transport.admin_secure
		and transport._connections.has(id)
		and principal.get("admin", false)
		and transport.admin_acl.allows(principal.get("key", ""))
		and not transport.bans.contains(principal.get("key", ""))
	)


func poll() -> void:
	# At most six proven live identities, independently of unauthenticated peers.
	var keys: Array = endpoint.transport.identities.values().map(
		func(principal): return principal.key
	)
	for key: String in _budgets.keys():
		if key not in keys:
			_budgets.erase(key)
	for id: int in rows.keys():
		if not _authorized(id) or int(rows[id].revision) != endpoint.transport.admin_acl.revision:
			_send(id, {"v": 1, "type": "revoked"})
			rows.erase(id)
			if (
				not _authorized(id)
				and endpoint.transport.identities.get(id, {}).get("purpose") == "manage"
			):
				endpoint.transport.disconnect_peer(id)
	for id: int in endpoint.transport._connections.keys():
		if not _authorized(id):
			continue
		if not rows.has(id):
			rows[id] = {
				"session": Crypto.new().generate_random_bytes(32).hex_encode(),
				"revision": endpoint.transport.admin_acl.revision,
				"high": 0,
				"queue": [],
				"cache": {},
				"at": 0,
				"count": 0,
				"sent": -1000,
				"epoch": ""
			}
		var row: Dictionary = rows[id]
		var world_epoch := str(endpoint.authority.world.actor_system.epoch)
		if row.epoch != world_epoch or Time.get_ticks_msec() - int(row.sent) >= 500:
			row.epoch = world_epoch
			row.sent = Time.get_ticks_msec()
			_send(
				id,
				{
					"v": 1,
					"type": "capability",
					"session": row.session,
					"epoch": world_epoch,
					"state": _status()
				}
			)


func receive(id: int, bytes: PackedByteArray) -> void:
	if not _authorized(id) or not rows.has(id):
		return
	var row: Dictionary = rows[id]
	var now := Time.get_ticks_msec()
	var key: String = endpoint.transport.identities[id].key
	var budget: Dictionary = _budgets.get(key, {"at": now, "count": 0})
	if now - int(budget.at) >= 1000:
		budget = {"at": now, "count": 0}
	budget.count += 1
	_budgets[key] = budget
	if now - int(row.at) >= 1000:
		row.at = now
		row.count = 0
	if now - int(_global.at) >= 1000:
		_global = {"at": now, "count": 0}
	row.count += 1
	_global.count += 1
	if row.count > CONNECTION_RATE or budget.count > PRINCIPAL_RATE or _global.count > GLOBAL_RATE:
		return
	var message := Protocol.unpack(bytes)
	if not Protocol.request(message) or message.session != row.session:
		return
	var number := int(message.id)
	var hash := bytes.hex_encode().sha256_text()
	if row.cache.has(number):
		if row.cache[number].hash == hash:
			_send(id, row.cache[number].reply)
		return
	if number <= int(row.high):
		return  # Includes queued and evicted requests.
	row.high = number  # Never roll back, even for full queues or failed actions.
	if row.queue.size() >= MAX_QUEUE:
		return
	row.queue.append(
		{
			"message": message,
			"hash": hash,
			"key": endpoint.transport.identities[id].key,
			"revision": endpoint.transport.admin_acl.revision
		}
	)


func execute_pending() -> void:
	if endpoint.authority.world._atomic_depth != 0:
		return
	# One operation per connection per pump, at most four globally, round robin.
	var ids := rows.keys()
	for offset: int in range(mini(4, ids.size())):
		var id: int = ids[posmod(_cursor + offset, ids.size())]
		if not rows.has(id) or rows[id].queue.is_empty():
			continue
		var row: Dictionary = rows[id]
		var pending: Dictionary = row.queue.pop_front()
		var message: Dictionary = pending.message
		if (
			not _authorized(id)
			or endpoint.transport.identities[id].key != pending.key
			or pending.revision != endpoint.transport.admin_acl.revision
		):
			continue
		var result := {"ok": false, "error": "Session changed; refresh and retry"}
		if message.epoch == str(endpoint.authority.world.actor_system.epoch):
			if message.action in ["status", "players", "bans", "slots"]:
				result = {
					"ok": true, "error": "", "data": _query(id, message.action, int(message.value))
				}
			elif _record(pending.key, message, "pending"):
				result = _action(id, message.action, message.value)
				if not _record(pending.key, message, "ok" if result.ok else "denied"):
					result.error = (
						("Action completed" if result.ok else "Action rejected")
						+ "; audit write failed. Administration disabled."
					)
			else:
				result = {"ok": false, "error": "Audit unavailable; remote administration disabled"}
		var reply := {
			"v": 1,
			"type": "result",
			"session": row.session,
			"id": int(message.id),
			"action": message.action,
			"ok": result.ok,
			"error": str(result.get("error", "")).left(120),
			"epoch": str(endpoint.authority.world.actor_system.epoch),
			"data": result.get("data", _status())
		}
		row.cache[int(message.id)] = {"hash": pending.hash, "reply": reply}
		while row.cache.size() > MAX_CACHE:
			row.cache.erase(row.cache.keys()[0])
		_send(id, reply)
	_cursor = posmod(_cursor + 1, 6)


func _action(id: int, action: String, value: Variant) -> Dictionary:
	var key: String = endpoint.transport.identities[id].key
	var protected := {}
	if Protocol.valid_reference(value):
		value = {"id": int(value.id), "generation": int(value.generation)}
		if endpoint.authority.world.resolve_player(value) == null:
			return {"ok": false, "error": "Target changed; refresh the player list"}
	for peer: Dictionary in endpoint.peers.values():
		var reference: Dictionary = peer.owner if not peer.owner.is_empty() else peer.reclaim
		if peer.principal.get("key") == key:
			protected = reference
		if (
			action in ["kick", "ban"]
			and reference == value
			and (
				peer.principal.get("key") == key
				or peer.principal.get("key") == Auth.fingerprint(endpoint.transport.identity_key)
			)
		):
			return {"ok": false, "error": "Cannot moderate yourself or the local owner"}
	return Host.execute(endpoint, action, value, protected)


func _status() -> Dictionary:
	var world: RefCounted = endpoint.authority.world
	return {
		"session": endpoint.coop.session.duplicate(true),
		"limit": endpoint.coop.kill_limit,
		"difficulty": world.bots.state.difficulty,
		"bots": world.bots.count(world),
		"humans": world.players.size() - world.bots.count(world),
		"phase": world.vs_state.get("phase", "playing"),
		"tick": str(world.clock.tick_count)
	}


func _query(requester: int, action: String, page: int) -> Dictionary:
	match action:
		"status":
			return _status()
		"players":
			var players := []
			var world: RefCounted = endpoint.authority.world
			var roster := Labels.roster(world)
			for player: RefCounted in world.players:
				var reference: Dictionary = player.player_ref()
				var entry := {
					"reference": reference,
					"name":
					Labels.label(roster, player.seat, world.bots.is_bot(reference), reference),
					"seat": player.seat,
					"bot": world.bots.is_bot(reference),
					"state": int(player.fighter.state),
					"owner": reference == endpoint.local_host_reference,
					"self": false,
					"ip": "local",
					"key": ""
				}
				for connection: int in endpoint.peers:
					var peer: Dictionary = endpoint.peers[connection]
					if peer.owner != reference and peer.reclaim != reference:
						continue
					entry.key = peer.principal.get("key", "")
					entry.self = entry.key == endpoint.transport.identities[requester].key
					entry.owner = (
						entry.owner
						or entry.key == Auth.fingerprint(endpoint.transport.identity_key)
					)
					entry.ip = endpoint.transport.remote_endpoint(connection).get("address", "")
				players.append(entry)
			return {"page": page, "total": players.size(), "rows": players.slice(page, page + 1)}
		"bans":
			var banned: Array = endpoint.transport.bans.rows()
			return {
				"page": page, "total": banned.size(), "rows": banned.slice(page * 6, page * 6 + 6)
			}
		"slots":
			var slots := Slots.new()
			slots.directory = "user://network-saves"
			var entries := []
			for number: int in range(1, 6):
				var info := slots.describe(number)
				entries.append(
					{
						"slot": number,
						"exists": info.exists,
						"valid": info.valid,
						"level": info.get("level", 0)
					}
				)
			return {"rows": entries}
	return {}


func _record(key: String, message: Dictionary, result: String) -> bool:
	var target := "" if message.value == null else str(message.value)
	if Protocol.valid_reference(message.value):
		target = "player:%d:%d" % [int(message.value.id), int(message.value.generation)]
	var entry := {
		"at": str(int(Time.get_unix_time_from_system())),
		"key": key,
		"action": message.action,
		"id": int(message.id),
		"result": result,
		"target": target
	}
	audit.append(entry)
	while audit.size() > MAX_AUDIT:
		audit.pop_front()
	if audit_path.is_empty():
		return true
	var file := FileAccess.open(audit_path + ".tmp", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"version": 1, "entries": audit}))
		file.flush()
		var error := file.get_error()
		file.close()
		if (
			error == OK
			and Protocol.Bans.Settings.protect(audit_path + ".tmp", false)
			and DirAccess.rename_absolute(audit_path + ".tmp", audit_path) == OK
		):
			return true
	healthy = false
	return false


func _send(id: int, value: Dictionary) -> void:
	var bytes := Protocol.pack(value)
	if not bytes.is_empty():
		endpoint.transport.send_to(id, Protocol.CHANNEL, bytes, true)
