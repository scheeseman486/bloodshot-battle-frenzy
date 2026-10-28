extends RefCounted
## Authority actions shared by local controls and the validated admin service.
## Wire schemas/permissions belong to admin_service; a client-owned endpoint
## still cannot execute anything here. All calls require a completed boundary.
const Slots = preload("res://scripts/persistence/save_slots.gd")


static func execute(endpoint: Node, action: String, value: Variant = null,
		protected_player: Dictionary = {}) -> Dictionary:
	if endpoint == null or endpoint.authority == null or endpoint.authority.world._atomic_depth != 0:
		return {"ok": false, "error": "Only the local server can administer a session"}
	var coordinator: RefCounted = endpoint.coop
	coordinator.last_error = ""
	var accepted := false
	var error := ""
	if action == "bot_count" and int(value) > 0 and endpoint.peers.is_empty():
		return {"ok": false, "error": "Connect a human player before adding bots"}
	match action:
		"bot_count": accepted = coordinator.set_bot_count(int(value))
		"bot_difficulty": accepted = coordinator.set_bot_difficulty(int(value))
		"bot_remove": accepted = coordinator.remove_bot(value)
		"revive_bot": accepted = coordinator.revive_bot(value)
		"mode": accepted = coordinator.select_mode(str(value))
		"map": accepted = coordinator.select_map(str(value))
		"limit": accepted = coordinator.set_kill_limit(int(value))
		"rematch": accepted = coordinator.rematch()
		"lobby": accepted = coordinator.select_map("lobby")
		"save", "load":
			var slots := Slots.new()
			slots.directory = "user://network-saves"
			accepted = coordinator.save_game(int(value), slots) if action == "save" else coordinator.load_game(int(value), slots)
		"ban":
			if value != protected_player:
				accepted = endpoint.ban_player(value)
				error = endpoint.last_error
		"unban":
			accepted = endpoint.unban_player(str(value))
			error = endpoint.last_error
		"kick":
			if value != protected_player and value != endpoint.local_host_reference:
				for connection: int in endpoint.peers.keys():
					var row: Dictionary = endpoint.peers[connection]
					var reference: Dictionary = row.owner if not row.owner.is_empty() else row.reclaim
					if reference == value:
						endpoint.transport.reject_peer(connection, "Player kicked")
						accepted = true
		_:
			return {"ok": false, "error": "Unknown host action"}
	if not accepted and error.is_empty():
		error = coordinator.last_error if not coordinator.last_error.is_empty() else "Action unavailable in the current session or target is no longer present"
	return {"ok": accepted, "error": "" if accepted else error}
