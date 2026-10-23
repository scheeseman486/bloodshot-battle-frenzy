extends RefCounted
## Pure visibility policy. Actions still require the local server capability.


static func entries(host: bool, mode: String, lobby: bool, exhausted: bool) -> Array:
	var result := [{"id": "resume", "label": "Resume Game"}]
	if exhausted and mode == "coop" and not lobby:
		result.append({"id": "continue", "label": "Continue"})
	if host:
		result.append(
			{"id": "mode", "label": "Game Mode: " + ("Co-op" if mode == "coop" else "VS Battle")}
		)
		result.append({"id": "map", "label": "Map: " + ("Lobby" if lobby else "Select map")})
		if lobby or mode == "versus": result.append({"id":"bots","label":"Bots"})
		if mode == "versus":
			result.append({"id": "limit", "label": "Kill Limit: 15"})
			if not lobby:
				result.append({"id": "rematch", "label": "Restart Match"})
		result.append({"id": "moderation", "label": "Player Moderation"})
		result.append({"id": "lobby", "label": "Go to lobby"})
		if mode == "coop":
			result.append({"id": "save", "label": "Save Game"})
			result.append({"id": "load", "label": "Load Game"})
	result.append({"id": "options", "label": "Options"})
	result.append({"id": "leave", "label": "Close server" if host else "Exit server"})
	return result


static func maps(mode: String) -> Array:
	if mode == "versus":
		return [
			{"id": "arena-1", "label": "Arena 1"},
			{"id": "arena-2", "label": "Arena 2"},
			{"id": "arena-3", "label": "Arena 3"}
		]
	var result := []
	for number: int in range(1, 17):
		result.append({"id": "level-%d" % number, "label": "Level %d" % number})
	return result
