extends "res://scripts/frontend/cd_small_menu_view.gd"
const ParticipantLabels = preload("res://scripts/presentation/participant_labels.gd")
## Local online menu. Only this client's input stops; the world and music run.
signal resumed
signal leave_requested
const Model = preload("res://scripts/frontend/network_session_menu_model.gd")
const SESSION_PAGES := ["session", "maps", "moderation", "save_slots", "load_slots", "overwrite", "bots", "unbans"]
var game: Node3D
var status := ""
var _actions: Array = []
var _map_page := 0
var _ban_page := 0
var _slot := 1
var slots := preload("res://scripts/persistence/save_slots.gd").new()
var _signature: Array = []
var _scores: Control
var _participant_icons: Array[Texture2D] = []


func _ready() -> void:
	texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	initial_menu = "session"
	allow_attract = false
	slots.directory = "user://network-saves"
	super._ready()
	if game!=null and game.has_node("OriginalHud/Hud"):
		var ui: RefCounted = game.get_node("OriginalHud/Hud").ui
		if ui!=null:
			for colour: int in range(4):
				_participant_icons.append(ImageTexture.create_from_image(preload("res://scripts/presentation/player_colours.gd").skull_image(ui.icon(4).get_image(),colour,true)))
	background.hide()
	if game != null and game.has_node("OriginalHud/Hud"):
		game.get_node("OriginalHud/Hud").layout_changed.connect(_layout_small_rows)
	get_viewport().size_changed.connect(_layout_small_rows)
	menu_state.selected = 1
	_resolve_row(0)


func open_menu(name: String) -> void:
	# Original Options/credits return to their retained online owner, never a
	# frontend root that can start a campaign or replace the running scene.
	super.open_menu("session" if name == "main" else name)
	if background != null:
		background.visible = not uses_small_font()
	if $Audio.music_track != 0:
		$Audio.stop_all()  # Online navigation keeps the gameplay music.


func uses_small_font() -> bool:
	return page in SESSION_PAGES


func session_settings() -> Dictionary:
	if game == null or game.endpoint == null:
		return {"mode": "coop", "lobby": false, "map": "level-1"}
	if game.host_endpoint != null:
		return game.host_endpoint.coop.session
	return game.endpoint.installed.get("party", {}).get(
		"session", {"mode": "coop", "lobby": false, "map": "level-1"}
	)


func menu_definition(name: String) -> Dictionary:
	var settings := session_settings()
	var host := game != null and game.host_endpoint != null
	var entries: Array = []
	match name:
		"bots":
			if host and (settings.lobby or settings.mode == "versus"):
				var world: RefCounted = game.host_endpoint.authority.world
				entries.append({"id":"bot_count","label":"Bot count: %d" % world.bots.count(world)})
				if settings.mode=="versus": entries.append({"id":"bot_difficulty","label":"Difficulty: "+["Easy","Normal","Hard"][world.bots.state.difficulty]})
				for player: RefCounted in world.players:
					entries.append({"id":"participant","label":ParticipantLabels.label(ParticipantLabels.roster(world), player.seat, world.bots.is_bot(player.player_ref()), player.player_ref()),"colour":player.seat})
			entries.append({"id":"back","label":"Back"})
		"session":
			var exhausted: bool = (
				game != null
				and game.endpoint != null
				and int(game.endpoint.client.session.fighter.get("state", 1)) == 0
				and (
					game.endpoint.installed.get("party", {}).get("phase", "playing")
					in ["playing", "continue"]
				)
			)
			entries = Model.entries(host, settings.mode, settings.lobby, exhausted)
			for entry: Dictionary in entries:
				if entry.id == "limit":
					entry.label = "Kill Limit: %d" % game.host_endpoint.coop.kill_limit
				if entry.id == "map" and not settings.lobby:
					entry.label = (
						"Map: "
						+ (
							"Arena " + str(settings.map).trim_prefix("arena-")
							if settings.mode == "versus"
							else "Level " + str(settings.map).trim_prefix("level-")
						)
					)
		"maps":
			var maps := Model.maps(settings.mode)
			for item: Dictionary in maps.slice(_map_page * 6, (_map_page + 1) * 6):
				entries.append({"id": "choose_map", "label": item.label, "value": item.id})
			if _map_page > 0:
				entries.append({"id": "previous", "label": "Previous maps"})
			if (_map_page + 1) * 6 < maps.size():
				entries.append({"id": "next", "label": "More maps"})
			entries.append({"id": "back", "label": "Back"})
		"moderation":
			if host:
				for player: RefCounted in game.host_endpoint.authority.world.players:
					if game.host_endpoint.authority.world.bots.is_bot(player.player_ref()):
						if settings.lobby or settings.mode == "versus": entries.append({"id":"bot_remove","label":"Remove Bot %d" % ParticipantLabels.ordinal(ParticipantLabels.roster(game.host_endpoint.authority.world), player.seat, true, player.player_ref()),"value":player.player_ref()})
						elif settings.mode=="coop" and int(player.fighter.state)==0: entries.append({"id":"revive_bot","label":"Revive Bot %d" % ParticipantLabels.ordinal(ParticipantLabels.roster(game.host_endpoint.authority.world), player.seat, true, player.player_ref()),"value":player.player_ref()})
						continue
					if player.player_ref() != game.endpoint.client.reference:
						var display_name: String = player.public_name if not player.public_name.is_empty() else "Player %d" % ParticipantLabels.ordinal(ParticipantLabels.roster(game.host_endpoint.authority.world), player.seat, false, player.player_ref())
						entries.append({"id": "kick", "label": "Kick " + display_name, "value": player.player_ref()})
						entries.append({"id": "ban", "label": "Ban " + display_name, "value": player.player_ref()})
				entries.append({"id": "unbans", "label": "Unban Players"})
			entries.append({"id": "back", "label": "Back"})
		"unbans":
			if host:
				var banned: Array = game.host_endpoint.transport.bans.rows()
				_ban_page = clampi(_ban_page, 0, maxi(0, ceili(banned.size() / 6.0) - 1))
				for entry: Dictionary in banned.slice(_ban_page * 6, (_ban_page + 1) * 6):
					var display_name: String = entry.name if not entry.name.is_empty() else "Player"
					entries.append({"id": "unban", "label": display_name + " [" + entry.key.left(8) + "]", "value": entry.key})
				if banned.is_empty(): entries.append({"id": "empty_bans", "label": "No banned players"})
				if _ban_page > 0: entries.append({"id": "previous_bans", "label": "Previous bans"})
				if (_ban_page + 1) * 6 < banned.size(): entries.append({"id": "next_bans", "label": "More bans"})
			entries.append({"id": "back", "label": "Back"})
		"save_slots", "load_slots":
			for number: int in range(1, slots.COUNT + 1):
				var info := slots.describe(number)
				var detail := (
					"Empty"
					if not info.exists
					else ("Level %d" % info.level if info.valid else "Invalid save")
				)
				entries.append(
					{
						"id": "save_slot" if name == "save_slots" else "load_slot",
						"label": "Slot %d - %s" % [number, detail],
						"value": number
					}
				)
			entries.append({"id": "back", "label": "Back"})
		"overwrite":
			entries = [
				{"id": "cancel_save", "label": "Cancel"},
				{"id": "confirm_save", "label": "Overwrite slot %d" % _slot}
			]
		_:
			return super.menu_definition(name)
	_actions = entries
	var items: Array = []
	for entry: Dictionary in entries:
		items.append({"native": entry.label, "choices": 0, "address": 0})
	return {"row": 3, "items": items}


func _tick() -> void:
	if is_instance_valid(_scores):
		return
	super._tick()


func _apply_menu_input() -> void:
	super._apply_menu_input()
	var selected := int(menu_state.get("selected", 0)) - 1
	if (
		page in ["session","bots"]
		and selected >= 0
		and selected < _actions.size()
		and _actions[selected].id in ["mode", "limit", "bot_count", "bot_difficulty"]
		and (int(menu_state.edge) & 12) != 12
	):
		_activate(selected + 1)


func _activate(row: int) -> void:
	if page not in SESSION_PAGES:
		if page == "options" and row == 4:
			menu_state.chosen = 0
			if not Flow.Scores.shared().rows.is_empty():
				_scores = load(Flow.SCORE_SCENE).instantiate()
				_scores.store = Flow.Scores.shared()
				_scores.phase = "writing"
				_scores.use_flow_request = false
				_scores.completed.connect(_scores_closed)
				add_child(_scores)
				_reset_controls_edges()
		else:
			super._activate(row)
		return
	if row < 1 or row > _actions.size():
		return
	var entry: Dictionary = _actions[row - 1]
	match entry.id:
		"bots":
			open_menu("bots")
		"bot_count":
			var world: RefCounted = game.host_endpoint.authority.world
			var humans: int = world.players.size()-world.bots.count(world)
			var direction := -1 if (int(menu_state.edge)&4)==0 else 1
			var next := posmod(world.bots.count(world)+direction,mini(3,4-humans)+1)
			game.request_admin("bot_count",next)
		"bot_remove":
			game.request_admin("bot_remove",entry.value)
		"bot_difficulty":
			var direction := -1 if (int(menu_state.edge)&4)==0 else 1
			game.request_admin("bot_difficulty",posmod(int(game.host_endpoint.authority.world.bots.state.difficulty)+direction,3))
		"revive_bot":
			game.request_admin("revive_bot",entry.value)
		"resume":
			resumed.emit.call_deferred()
		"continue":
			if game.endpoint.installed.party.credits <= 0:
				status = "No continue credits remain"
			else:
				game.endpoint.party_action("continue")
				resumed.emit.call_deferred()
		"mode":
			game.request_admin("mode", "versus" if session_settings().mode == "coop" else "coop")
		"limit":
			var limits: Array = preload("res://scripts/game/vs_match.gd").LIMITS
			var direction := -1 if (int(menu_state.edge) & 4) == 0 else 1
			var next := posmod(limits.find(game.host_endpoint.coop.kill_limit) + direction, limits.size())
			game.request_admin("limit", limits[next])
		"rematch":
			game.request_admin("rematch")
		"map":
			_map_page = 0
			open_menu("maps")
		"moderation":
			open_menu("moderation")
		"lobby":
			game.request_admin("lobby")
		"choose_map":
			game.request_admin("map", entry.value)
		"previous", "next":
			_map_page += -1 if entry.id == "previous" else 1
			open_menu("maps")
		"kick", "ban":
			game.request_admin(entry.id, entry.value)
		"unbans":
			_ban_page = 0
			open_menu("unbans")
		"unban":
			game.request_admin("unban", entry.value)
		"previous_bans", "next_bans":
			_ban_page += -1 if entry.id == "previous_bans" else 1
			open_menu("unbans")
		"save":
			if session_settings().lobby:
				status = "Start a co-op map before saving"
			else:
				open_menu("save_slots")
		"load":
			open_menu("load_slots")
		"save_slot":
			_slot = int(entry.value)
			if slots.describe(_slot).exists:
				open_menu("overwrite")
			else:
				game.request_admin("save", _slot)
		"confirm_save":
			game.request_admin("save", _slot)
		"cancel_save":
			open_menu("save_slots")
		"load_slot":
			game.request_admin("load", entry.value)
		"back":
			open_menu("moderation" if page == "unbans" else "session")
		"options":
			open_menu("options")
		"leave":
			leave_requested.emit.call_deferred()
	menu_state.chosen = 0


func open_controls() -> void:
	if is_instance_valid(_controls_menu):
		return
	_reset_controls_edges()
	_controls_menu = ControlsMenu.instantiate()
	if is_instance_valid(game):
		# Use the offline store and the active player's apply hook. The server's
		# simulation and other players never receive local device preferences.
		_controls_menu.input_settings = game.settings
		_controls_menu.save_handler = game.configure_controls
	_controls_menu.closed.connect(_controls_closed)
	add_child(_controls_menu)


func _scores_closed() -> void:
	if is_instance_valid(_scores):
		_scores.queue_free()
	_scores = null
	_reset_controls_edges()
	open_menu("options")


func admin_result(action: String, accepted: bool, error: String) -> void:
	status = (
		({"save": "Saved game", "ban": "Player banned", "unban": "Player unbanned"}.get(action, ""))
		if accepted
		else (error if not error.is_empty() else "Unable to complete operation")
	)
	open_menu("unbans" if action == "unban" else ("moderation" if action in ["kick", "ban", "revive_bot", "bot_remove"] else ("bots" if action in ["bot_count", "bot_difficulty"] else "session")))
	menu_state.selected = 1
	for index: int in range(_actions.size()):
		if _actions[index].id == action:
			menu_state.selected = index + 1
	_resolve_row(int(menu_state.selected) - 1)


func _process(delta: float) -> void:
	# Death, map changes and departures can occur while the menu is open.
	if game != null and game.endpoint != null and game.endpoint.phase == "live":
		var settings := session_settings()
		var signature := [
			settings.mode,
			settings.lobby,
			settings.map,
			game.host_endpoint.coop.kill_limit if game.host_endpoint != null else 0,
			game.host_endpoint.authority.world.bots.state.difficulty if game.host_endpoint != null else 0,
			game.endpoint.client.session.fighter.get("state", 1),
			game.endpoint.installed.party.phase,
			game.endpoint.installed.roster.map(func(row): return row.reference),
			status,
			game.host_endpoint.transport.bans.entries if game.host_endpoint != null else {}
		]
		if signature != _signature:
			_signature = signature.duplicate(true)
			if page in ["session", "moderation", "bots", "unbans"]:
				var selected: int = menu_state.get("selected", 1)
				open_menu(page)
				menu_state.selected = clampi(selected, 1, labels.size())
	super._process(delta)


func _go_back() -> void:
	if page not in SESSION_PAGES:
		super._go_back()
		return
	_reset_controls_edges()
	if page == "session":
		resumed.emit.call_deferred()
	elif page == "unbans":
		open_menu("moderation")
	elif page == "overwrite":
		open_menu("save_slots")
	else:
		open_menu("session")


func _input(event: InputEvent) -> void:
	if is_instance_valid(_scores) or is_instance_valid(_controls_menu):
		return
	if event is InputEventJoypadButton and event.button_index == JOY_BUTTON_START:
		if event.pressed:
			_go_back()
		get_viewport().set_input_as_handled()
		return
	super._input(event)


func small_menu_heading() -> String:
	return (
		{
			"maps": "Select Map",
			"moderation": "Player Moderation",
			"unbans": "Unban Players",
			"save_slots": "Save Game",
			"load_slots": "Load Game",
			"overwrite": "Replace saved game?"
		}
		. get(page, "")
	)


func small_menu_footer() -> String:
	return status


func _layout_small_rows() -> void:
	super._layout_small_rows()
	if (
		not uses_small_font()
		or _hint_font == null
		or game == null
		or not game.has_node("OriginalHud/Hud")
	):
		return
	var hud: Control = game.get_node("OriginalHud/Hud")
	var view: Rect2 = hud.view_rect
	var center := (view.get_center() - frame.position) / artwork_scale
	var top := (view.position.y - frame.position.y) / artwork_scale.y
	var bottom := (view.end.y - frame.position.y) / artwork_scale.y
	top += 20.0 if not small_menu_heading().is_empty() else 6.0
	bottom -= 24.0 if not status.is_empty() else 6.0
	center.y = (top + bottom) * 0.5
	var spacing := minf(18.0, (bottom - top - 12.0) / maxi(1, labels.size() - 1))
	var height := (labels.size() - 1) * spacing + 12.0
	for index: int in range(labels.size()):
		var width := (
			_hint_font
			. get_string_size(
				labels[index].get_string_from_ascii(), HORIZONTAL_ALIGNMENT_LEFT, -1, 12
			)
			. x
		)
		row_origins[index] = Vector2(
			center.x - width * 0.5, center.y - height * 0.5 + index * spacing
		)
		if index<_actions.size() and _actions[index].has("colour"):
			row_origins[index].x+=10


func _draw() -> void:
	super._draw()
	if page!="bots" or _participant_icons.size()!=4: return
	for index: int in range(mini(_actions.size(),row_origins.size())):
		if not _actions[index].has("colour"): continue
		draw_set_transform(frame.position+row_origins[index]*artwork_scale,0,artwork_scale)
		draw_texture_rect(_participant_icons[int(_actions[index].colour)],Rect2(-20,-2,16,16),false)
	draw_set_transform(Vector2.ZERO)


func row_at_position(position: Vector2) -> int:
	if not uses_small_font():
		return super.row_at_position(position)
	if _hint_font == null:
		return -1
	var point := (position - frame.position) / artwork_scale
	for index: int in range(labels.size()):
		var gap := 18.0
		if index + 1 < row_origins.size():
			gap = row_origins[index + 1].y - row_origins[index].y
		elif index > 0:
			gap = row_origins[index].y - row_origins[index - 1].y
		var width := (
			_hint_font
			. get_string_size(
				labels[index].get_string_from_ascii(), HORIZONTAL_ALIGNMENT_LEFT, -1, 12
			)
			. x
		)
		if Rect2(row_origins[index] - Vector2(8, 3), Vector2(width + 16, gap)).has_point(point):
			return index
	return -1


func _exit_tree() -> void:
	# Sound Test temporarily enables effects; restore the saved source mode
	# even when a map change or departure disposes the overlay on that page.
	preload("res://scripts/audio/cd_audio_settings.gd").set_source_mode(
		int(Settings.values().sound)
	)
