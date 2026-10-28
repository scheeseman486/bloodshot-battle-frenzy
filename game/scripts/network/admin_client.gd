extends RefCounted
## Client convenience only; the server owns all permissions and state changes.
signal changed
signal completed(action: String, accepted: bool, error: String)
const Protocol = preload("res://scripts/network/admin_protocol.gd")
var transport: Node
var available := false
var session := ""
var epoch := ""
var state: Dictionary = {}
var players: Array = []
var banned: Dictionary = {}
var slots: Array = []
var last_error := ""
var _next := 1
var _pending: Dictionary = {}
var _sent := 0
var _refresh := -1
var _last_request := -1000
var _queries: Array = []
var _player_staging: Array = []


func clear() -> void:
	available = false
	session = ""
	epoch = ""
	state.clear()
	players.clear()
	_player_staging.clear()
	banned.clear()
	slots.clear()
	_pending.clear()
	_queries.clear()
	_refresh = -1
	changed.emit()


func request(action: String, value: Variant = null) -> bool:
	if (
		not available
		or not _pending.is_empty()
		or not Protocol.argument(action, value)
		or action not in Protocol.ACTIONS
	):
		return false
	if Time.get_ticks_msec() - _last_request < 150 or _next >= 2147483647:
		return false
	var message := {
		"v": 1,
		"type": "request",
		"session": session,
		"epoch": epoch,
		"id": _next,
		"action": action,
		"value": value
	}
	if not transport.send_to(1, Protocol.CHANNEL, Protocol.pack(message), true):
		return false
	_next += 1
	_pending = message
	_sent = Time.get_ticks_msec()
	_last_request = _sent
	return true


func refresh_players() -> void:
	if _refresh < 0:
		_refresh = 0


func query(action: String, value: int = 0) -> void:
	if action not in ["bans", "slots", "status"] or not Protocol.argument(action, value):
		return
	var item := {"action": action, "value": value}
	if _queries.size() < 4 and item not in _queries:
		_queries.append(item)


func poll() -> void:
	if not _pending.is_empty() and Time.get_ticks_msec() - _sent > 5000:
		var action: String = _pending.action
		_pending.clear()
		_refresh = -1
		last_error = "No reply; check server state before retrying"
		completed.emit(action, false, last_error)
	if available and _pending.is_empty():
		if not _queries.is_empty():
			if request(_queries[0].action, _queries[0].value):
				_queries.pop_front()
		elif _refresh >= 0:
			request("players", _refresh)


func receive(bytes: PackedByteArray) -> void:
	# A first-contact TOFU/game link never enables a legitimate admin UI/proof.
	if not transport.admin_enabled or not transport._connections.has(1):
		return
	var message := Protocol.unpack(bytes)
	if not Protocol.whole(message.get("v"), 1, 1) or not message.get("type") is String:
		return
	if message.type == "revoked" and message.size() == 2:
		clear()
		last_error = "Administration access revoked"
		return
	if message.type == "capability":
		if (
			message.size() != 5
			or not Protocol.Bans.valid_key(message.get("session"))
			or not Protocol.epoch(message.get("epoch"))
			or not _valid_status(message.get("state"))
		):
			return
		if session != message.session:
			clear()
			session = message.session
			_next = 1
		available = true
		epoch = message.epoch
		state = message.state
		changed.emit()
		return
	if (
		message.type != "result"
		or message.size() != 9
		or not message.has_all(["session", "id", "action", "ok", "error", "epoch", "data"])
	):
		return
	if (
		_pending.is_empty()
		or not message.session is String
		or message.session != session
		or not Protocol.whole(message.id, int(_pending.id), int(_pending.id))
	):
		return
	if (
		not message.action is String
		or message.action != _pending.action
		or not message.ok is bool
		or not message.error is String
		or message.error.length() > 120
		or not Protocol.epoch(message.epoch)
		or not message.data is Dictionary
	):
		return
	var action: String = _pending.action
	var argument: Variant = _pending.value
	_pending.clear()
	epoch = message.epoch
	last_error = message.error
	if message.ok:
		match action:
			"status":
				if _valid_status(message.data):
					state = message.data
			"players":
				if _valid_players(message.data) and int(message.data.page) == int(argument):
					if int(argument) == 0:
						_player_staging.clear()
					for player: Dictionary in message.data.rows:
						player.reference = {
							"id": int(player.reference.id),
							"generation": int(player.reference.generation)
						}
						if _player_staging.size() < 4:
							_player_staging.append(player)
					_refresh = (
						int(argument) + 1 if int(argument) + 1 < int(message.data.total) else -1
					)
					if _refresh < 0:
						players = _player_staging.duplicate(true)
				else:
					_refresh = -1
			"bans":
				if _valid_bans(message.data) and int(message.data.page) == int(argument):
					banned = message.data
			"slots":
				if _valid_slots(message.data):
					slots = message.data.rows
			_:
				if _valid_status(message.data):
					state = message.data
				refresh_players()
	else:
		if _valid_status(message.data):
			state = message.data
		_refresh = -1
	changed.emit()
	if action not in ["players", "status", "bans", "slots"]:
		completed.emit(action, message.ok, message.error)


static func _valid_status(value: Variant) -> bool:
	if (
		not value is Dictionary
		or value.size() != 7
		or not value.has_all(["session", "limit", "difficulty", "bots", "humans", "phase", "tick"])
	):
		return false
	var settings: Variant = value.session
	if (
		not settings is Dictionary
		or settings.size() != 4
		or not settings.has_all(["enabled", "mode", "lobby", "map"])
	):
		return false
	return (
		settings.enabled is bool
		and settings.enabled
		and settings.mode is String
		and settings.mode in ["coop", "versus"]
		and settings.lobby is bool
		and Protocol.argument("map", settings.map)
		and Protocol.argument("limit", value.limit)
		and Protocol.whole(value.difficulty, 0, 2)
		and Protocol.whole(value.bots, 0, 3)
		and Protocol.whole(value.humans, 0, 4)
		and value.phase is String
		and value.phase in ["waiting", "playing", "results", "finished"]
		and value.tick is String
		and value.tick.length() <= 19
		and value.tick.is_valid_int()
	)


static func _valid_players(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 3 or not value.has_all(["page", "total", "rows"]):
		return false
	if (
		not Protocol.whole(value.page, 0, 4)
		or not Protocol.whole(value.total, 0, 4)
		or not value.rows is Array
		or value.rows.size() > 1
	):
		return false
	for row: Variant in value.rows:
		if (
			not row is Dictionary
			or row.size() != 9
			or not row.has_all(
				["reference", "name", "seat", "bot", "state", "owner", "self", "ip", "key"]
			)
		):
			return false
		if (
			not Protocol.valid_reference(row.reference)
			or not row.name is String
			or row.name.length() > 32
			or not Protocol.whole(row.seat, 0, 3)
			or not row.bot is bool
			or not Protocol.whole(row.state, 0, 65535)
			or not row.owner is bool
			or not row.self is bool
			or not row.ip is String
			or row.ip.length() > 64
			or not row.key is String
			or (not row.key.is_empty() and not Protocol.Bans.valid_key(row.key))
		):
			return false
	return true


static func _valid_bans(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 3 or not value.has_all(["page", "total", "rows"]):
		return false
	if (
		not Protocol.whole(value.page, 0, 171)
		or not Protocol.whole(value.total, 0, 1024)
		or not value.rows is Array
		or value.rows.size() > 6
	):
		return false
	for row: Variant in value.rows:
		if (
			not row is Dictionary
			or row.size() != 2
			or not Protocol.Bans.valid_key(row.get("key"))
			or not Protocol.Bans.Settings.valid_name(row.get("name"))
		):
			return false
	return true


static func _valid_slots(value: Variant) -> bool:
	if (
		not value is Dictionary
		or value.size() != 1
		or not value.get("rows") is Array
		or value.rows.size() != 5
	):
		return false
	for index: int in range(5):
		var row: Variant = value.rows[index]
		if (
			not row is Dictionary
			or row.size() != 4
			or not row.has_all(["slot", "exists", "valid", "level"])
			or not Protocol.whole(row.slot, index + 1, index + 1)
			or not row.exists is bool
			or not row.valid is bool
			or not Protocol.whole(row.level, 0, 16)
		):
			return false
	return true
