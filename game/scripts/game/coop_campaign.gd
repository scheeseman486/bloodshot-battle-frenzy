extends RefCounted
## Native four-seat campaign coordinator. CD gameplay rules stay in World;
## this service owns authenticated party actions and the between-map barrier.
const Carry = preload("res://scripts/simulation/cd_campaign_carry.gd")
const Session = preload("res://scripts/simulation/cd_gameplay_session.gd")
var _peer: WeakRef
var source: RefCounted
var last_error := ""
var kill_limit := 15
# Native session UI metadata; transport identities never enter checkpoints.
var session := {"enabled": false, "mode": "coop", "lobby": false, "map": "level-1"}


func configure(endpoint: Node) -> void:
	_peer = weakref(endpoint)
	endpoint.authority.campaign.score_eligible = false


func advance_usec(elapsed: int) -> int:
	var peer: Node = _peer.get_ref()
	var server: RefCounted = peer.authority
	var world: RefCounted = server.world
	world.stop_when_exhausted = (
		not world.players.is_empty() and not session.lobby and session.mode == "coop"
	)
	if server.campaign.paused:
		if peer.peers.values().any(func(row): return not row.reclaim.is_empty()):
			return 0
		server.campaign.paused = false
	var count: int = server.advance_usec(elapsed)
	if world.players.is_empty():
		return count
	if session.enabled and session.mode == "versus" and not session.lobby:
		return count  # Dedicated native match service owns consistent VS returns.
	if session.enabled and session.lobby:
		# Competitive lives are unlimited; the original death animation/timer and
		# respawn phases still run. An exhausted seat returns without continue UI.
		for player: RefCounted in world.players:
			if int(player.fighter.state) == 0:
				_revive(server, player)
		return count
	if not server.campaign._transition_pending and (world.is_complete() or world.is_game_over()):
		server.campaign._transition_pending = true
		server.campaign._transition_carry = {}
		server.campaign._state.card = _card(server, "continue" if world.is_game_over() else "clear")
	var card: Dictionary = server.campaign._state.card
	if not card.is_empty() and not card._done:
		card._clock += float(maxi(elapsed, 0)) / 1000000.0
		var period := 1070460.0 / 53203424.0
		while card._clock >= period:
			card._clock -= period
			card.age += 1
			card.ticks += 1
		if card.phase == "continue" and (card.age >= 1000 or server.campaign.continue_credits <= 0):
			card.phase = "summary"
			card._summary = true
	return count


func action(connection: int, name: String) -> bool:
	var peer: Node = _peer.get_ref()
	if not peer.peers.has(connection) or peer.peers[connection].phase != "live":
		return false
	var server: RefCounted = peer.authority
	var row: Dictionary = peer.peers[connection]
	var player: RefCounted = server.world.resolve_player(row.owner)
	if player == null:
		return false
	var card: Dictionary = server.campaign._state.card
	if card.is_empty():
		if (
			not session.lobby
			and session.mode == "coop"
			and name == "continue"
			and int(player.fighter.state) == 0
			and server.campaign.continue_credits > 0
		):
			if not _revive(server, player):
				return false
			server.campaign.continue_credits -= 1
			row.reclaim = player.player_ref()
			peer._reset_peer(connection)
			return true
		return false
	if name == "next" and card.phase == "clear" and server.campaign.level_number < 16:
		return _load(server.campaign.level_number + 1, false)
	if name == "continue" and card.phase == "continue" and server.campaign.continue_credits > 0:
		if not _load(server.campaign.level_number, true):
			return false
		server.campaign.continue_credits -= 1
		return true
	if (
		name in ["finished", "scores"]
		and (card.phase == "summary" or server.campaign.level_number == 16)
	):
		if session.enabled and session.mode == "coop":
			# A completed online party keeps its connections. Validate/build the
			# lobby before replacing the world; never publish a disconnect phase.
			return start_lobby()
		card._done = true
		return true
	return false


func _revive(server: RefCounted, player: RefCounted) -> bool:
	var spawn: Dictionary = preload("res://scripts/game/coop_spawns.gd").select(
		server.world, player.seat
	)
	if spawn.is_empty():
		return false
	var system: RefCounted = server.world.actor_system
	var slot: int = system.restore_player_proxy(player.handle)
	if slot < 0:
		return false
	var retained_stats: Dictionary = player.level_stats
	player.configure(server.world, player.id, player.generation, player.seat)
	player.level_stats = retained_stats
	player.wall_cursor = 0
	player._query_remainder = 0
	player._door_remainder = 0
	player._sightings.clear()
	for field: String in ["x", "y", "angle"]:
		if spawn.has(field):
			player.motion[field] = spawn[field]
	player.fighter.proxy = slot
	player.fighter.grace = 20
	player.fighter.checkpoint_x = player.motion.x
	player.fighter.checkpoint_y = player.motion.y
	player.fighter.checkpoint_angle = player.motion.angle
	player.world_origin = Vector2i(player.motion.x, player.motion.y)
	server.world.admission_state.queue = server.world.admission_state.queue.filter(
		func(event): return event.player != player.player_ref()
	)
	server.world.admission_state.controls.erase(player.handle)
	server.world.admission_state.rates.erase(player.handle)
	system.bind_player(player.handle, player.combat_state())
	system._update_player_proxy()
	server.bind_world()
	server.refresh_views(true)
	return true


func _load(number: int, fresh: bool) -> bool:
	var peer: Node = _peer.get_ref()
	var server: RefCounted = peer.authority
	if source == null:
		source = preload("res://scripts/assets/original_asset_source.gd").new()
		if not source.mount(source.configured_disc_path()):
			last_error = source.last_error
			return false
	var definition := preload("res://scripts/game/world_definition.gd").new()
	if not definition.load_from_source(source, number):
		last_error = "Cannot load original campaign level"
		return false
	definition.set_meta("session_flow", session.enabled)
	var party := []
	for player: RefCounted in server.world.players:
		var facade := Session.new()
		facade.world = server.world
		facade.player = player
		party.append(
			{
				"seat": player.seat,
				"reference": player.player_ref(),
				"carry": {} if fresh else Carry.capture(facade),
				"state": player.fighter.state,
				"campaign_deaths": int(player.level_stats.get("campaign_deaths", 0)),
				"banked": _banked_score(server, player, fresh)
			}
		)
	var candidate := preload("res://scripts/game/world_state.gd").new()
	candidate.configure_definition(definition)
	candidate.bots.state.difficulty=server.world.bots.state.difficulty
	candidate.admission_state.source_visibility = true
	candidate.campaign_state = server.campaign.describe()
	candidate.campaign_state.level_number = number
	candidate.campaign_state._transition_pending = false
	candidate.campaign_state._transition_carry = {}
	candidate.campaign_state.card = {}
	candidate.campaign_state.paused = true
	candidate.campaign_state.score_eligible = false
	candidate.stop_when_exhausted = true
	var replacements := []
	for member: Dictionary in party:
		var reference: Dictionary = candidate.spawn_player(int(member.seat))
		if reference.is_empty():
			last_error = "No valid party spawn in original map"
			return false
		var player: RefCounted = candidate.resolve_player(reference)
		var facade := Session.new()
		facade.world = candidate
		facade.player = player
		Carry.apply_to(facade, member.carry)
		if not player.level_stats.is_empty():
			player.level_stats.campaign_deaths = member.campaign_deaths
			player.level_stats.banked = member.banked
		if not fresh and int(member.state) == 0:
			player.fighter.state = 0
			player.motion.state = 0
			candidate.actor_system.exhaust_player_proxy(player.handle)
			player.fighter.proxy = -1
		replacements.append({"old": member.reference, "new": reference})
		if server.world.bots.is_bot(member.reference): candidate.bots.mark(candidate,reference)
	# Construct and validate all spawns/media before changing the live authority.
	if fresh: peer.returning.retry(candidate)
	server.install_checkpoint(candidate)
	for replacement: Dictionary in replacements:
		for row: Dictionary in peer.peers.values():
			if row.owner == replacement.old:
				row.reclaim = replacement.new

	if session.enabled:
		session.map = "level-%d" % number
		session.lobby = false
	peer._world_changed()
	return true


static func _card(server: RefCounted, phase: String) -> Dictionary:
	var result := {
		"level": server.campaign.level_number,
		"kills": int(server.world.actor_system.encounter.kills),
		"bonuses": int(server.world.actor_system.encounter.bonuses),
		"tally": int(server.world.actor_system.encounter.damage_total),
		"credits": server.campaign.continue_credits
	}
	var scores: Array = preload("res://scripts/game/coop_score.gd").rows(
		server.world.players, server.campaign.level_number == 16 or phase != "clear"
	)
	if not scores.is_empty():
		result.players = scores
	var card := {
		"result": result,
		"phase": phase,
		"_clock": 0.0,
		"_done": false,
		"_summary": false,
		"_continuation_exit": ""
	}
	for field: String in preload("res://scripts/persistence/checkpoint_attachments.gd").CARD_FIELDS:
		if not card.has(field):
			card[field] = 0xffffffff if field in ["_pending", "_held", "_previous"] else 0
	card.deadline = 250
	return card


static func describe(server: RefCounted) -> Dictionary:
	var card: Dictionary = server.campaign._state.card
	return {
		"level": server.campaign.level_number,
		"credits": server.campaign.continue_credits,
		"phase": "playing" if card.is_empty() else ("finished" if card._done else card.phase),
		"result": {} if card.is_empty() else card.result.duplicate(true)
	}


static func valid(state: Variant) -> bool:
	if (
		not state is Dictionary
		or state.size() not in [4, 5]
		or not state.has_all(["level", "credits", "phase", "result"])
	):
		return false
	if (
		not state.level is int
		or state.level < 0
		or state.level > 16
		or not state.credits is int
		or state.credits < 0
		or state.credits > 32767
		or state.phase not in ["playing", "clear", "continue", "summary", "finished"]
		or not state.result is Dictionary
	):
		return false
	if state.has("session"):
		var settings: Variant = state.session
		if (
			not settings is Dictionary
			or settings.size() != 3
			or not settings.has_all(["mode", "lobby", "map"])
		):
			return false
		if (
			settings.mode not in ["coop", "versus"]
			or not settings.lobby is bool
			or not settings.map is String
		):
			return false
		if settings.lobby != (settings.map == "lobby"):
			return false
		if (settings.lobby or settings.mode == "versus") != (state.level == 0):
			return false
		if (
			not settings.lobby
			and (
				settings.map
				not in preload("res://scripts/frontend/network_session_menu_model.gd").maps(settings.mode).map(
					func(row): return row.id
				)
			)
		):
			return false
	elif state.level == 0 or state.size() != 4:
		return false
	if state.result.is_empty():
		return state.phase == "playing"
	if (
		state.result.size() != (6 if state.result.has("players") else 5)
		or not state.result.has_all(["level", "credits", "kills", "bonuses", "tally"])
	):
		return false
	if (
		state.result.has("players")
		and not preload("res://scripts/game/coop_score.gd").valid_rows(
			state.result.players, state.level == 16 or state.phase != "clear"
		)
	):
		return false
	for key: String in state.result:
		if key == "players":
			continue
		var value: Variant = state.result[key]
		if not value is int or value < -2147483648 or value > 0xffffffff:
			return false
	return state.result.level == state.level


## Local host capability only: no administration RPC is accepted from clients.
func start_lobby() -> bool:
	session.enabled = true
	return select_map("lobby")


func select_mode(mode: String) -> bool:
	if mode not in ["coop", "versus"]:
		return false
	var previous: String = session.mode
	session.mode = mode
	if select_map("lobby"):
		return true
	session.mode = previous
	return false


func select_map(identifier: String) -> bool:
	last_error = ""
	var peer: Node = _peer.get_ref()
	if peer == null or peer.authority.world._atomic_depth != 0:
		return false
	if (
		identifier != "lobby"
		and (
			identifier
			not in preload("res://scripts/frontend/network_session_menu_model.gd").maps(session.mode).map(
				func(row): return row.id
			)
		)
	):
		last_error = "Map does not belong to this game mode"
		return false
	if not _mount_source():
		return false
	var definition := preload("res://scripts/game/world_definition.gd").new()
	if not definition.load_map(source, identifier):
		last_error = "Unable to load selected map"
		return false
	definition.set_meta("session_flow", true)
	var candidate := preload("res://scripts/game/world_state.gd").new()
	candidate.configure_definition(definition)
	candidate.admission_state.source_visibility = true
	if not candidate.vs_state.is_empty():
		candidate.vs_state.limit = kill_limit
	candidate.campaign_state = peer.authority.campaign.describe().duplicate(true)
	candidate.campaign_state.level_number = (
		int(identifier.trim_prefix("level-")) if identifier.begins_with("level-") else 0
	)
	candidate.campaign_state.continue_credits = 3
	candidate.campaign_state._game_over_presented = false
	candidate.campaign_state._transition_pending = false
	candidate.campaign_state._transition_carry = {}
	candidate.campaign_state.card = {}
	candidate.campaign_state.paused = true
	candidate.campaign_state.score_eligible = false
	if not _replace_world(candidate):
		return false
	session.enabled = true
	session.map = identifier
	session.lobby = identifier == "lobby"
	return true


func set_kill_limit(value: int) -> bool:
	if value not in preload("res://scripts/game/vs_match.gd").LIMITS or session.mode != "versus":
		return false
	var previous := kill_limit
	kill_limit = value
	if session.lobby or select_map(session.map):
		return true
	kill_limit = previous
	return false


func rematch() -> bool:
	return session.mode == "versus" and not session.lobby and select_map(session.map)


func save_game(slot: int, slots: RefCounted) -> bool:
	last_error = ""
	var peer: Node = _peer.get_ref()
	if peer == null or session.mode != "coop" or session.lobby:
		last_error = "Save is available during a co-op game"
		return false
	var bytes: PackedByteArray = peer.authority.capture_checkpoint()
	if bytes.is_empty():
		last_error = peer.authority.world.last_checkpoint_error
		return false
	if not slots.write(slot, bytes):
		last_error = slots.last_error
		return false
	return true


func load_game(slot: int, slots: RefCounted) -> bool:
	last_error = ""
	if session.mode != "coop" or not _mount_source():
		last_error = "Load is available in co-op mode"
		return false
	var bytes: PackedByteArray = slots.read(slot)
	if bytes.is_empty():
		last_error = slots.last_error
		return false
	var candidate := preload("res://scripts/game/world_state.gd").new()
	if not candidate.restore_checkpoint(bytes, source):
		last_error = candidate.last_checkpoint_error
		return false
	if candidate.level.get_meta("battle_mode", false) or int(candidate.campaign_state.get("level_number", 0)) < 1:
		last_error = "Only campaign saves can be loaded in co-op"
		return false
	if candidate.campaign_state.is_empty():
		last_error = "Save has no campaign coordinator state"
		return false
	if not candidate.demo_state.is_empty():
		last_error = "Recorded demos cannot be loaded as multiplayer games"
		return false
	candidate.definition.set_meta("session_flow", true)
	candidate.actor_system.native_multiplayer = true
	if candidate.loot_state.is_empty():
		candidate.loot_state = preload("res://scripts/game/native_inventory_drops.gd").initial()
	candidate._loot_geometry.configure(candidate.level)
	if candidate.score_state.is_empty():
		candidate.score_state = preload("res://scripts/game/coop_score.gd").initial_world()
	for player: RefCounted in candidate.players:
		if player.level_stats.is_empty():
			player.level_stats = preload("res://scripts/game/coop_score.gd").initial()
			# Historical saves cannot prove a no-life-loss campaign.
			player.level_stats.campaign_deaths = 1
	candidate.actor_system.epoch = ResourceUID.create_id()
	candidate.campaign_state.paused = true
	candidate.campaign_state.score_eligible = false
	if not _replace_world(candidate,true):
		return false
	session.enabled = true
	session.map = "level-%d" % candidate.campaign_state.level_number
	session.lobby = false
	return true


func _mount_source() -> bool:
	if source == null:
		source = preload("res://scripts/assets/original_asset_source.gd").new()
		if not source.mount(source.configured_disc_path()):
			last_error = source.last_error
			return false
	return true


func _replace_world(candidate: RefCounted, saved: bool = false) -> bool:
	var peer: Node = _peer.get_ref()
	var claims := {}
	# Stable local seats are the initial co-op save identity policy. Every
	# connected participant keeps its current seat, never a saved peer number.
	for connection: int in peer.peers:
		var row: Dictionary = peer.peers[connection]
		var player: RefCounted = peer.authority.world.resolve_player(
			row.owner if not row.owner.is_empty() else row.reclaim
		)
		if player != null:
			claims[connection] = player.seat
	for player: RefCounted in candidate.players:
		var bot: bool = candidate.bots.is_bot(player.player_ref())
		if (bot and player.seat in claims.values()) or (not bot and player.seat not in claims.values()):
			candidate.remove_player(player.player_ref())
	var replacements := {}
	for connection: int in claims:
		var seat: int = claims[connection]
		var matching: Array = candidate.players.filter(func(player): return player.seat == seat)
		var reference: Dictionary = (
			matching[0].player_ref() if not matching.is_empty() else candidate.spawn_player(seat)
		)
		if reference.is_empty():
			last_error = "Selected map has no valid spawn for the connected party"
			return false
		replacements[connection] = reference
	if not saved:
		candidate.bots.state.difficulty=peer.authority.world.bots.state.difficulty
		for old: RefCounted in peer.authority.world.players:
			if not peer.authority.world.bots.is_bot(old.player_ref()) or old.seat in claims.values(): continue
			var reference: Dictionary = candidate.spawn_player(old.seat)
			if reference.is_empty(): last_error="No valid companion spawn"; return false
			candidate.bots.mark(candidate,reference)
		var desired: int = peer.authority.world.bots.count(peer.authority.world)
		if not candidate.bots.set_count(candidate,desired): last_error="Unable to allocate bot seats"; return false
	peer.authority.install_checkpoint(candidate)
	peer.authority.release_controls(false)
	for connection: int in replacements:
		peer.peers[connection].reclaim = replacements[connection]
	# An explicit map selection or successful save load establishes a new
	# score timeline. Disconnected records cannot carry future points into it.
	peer.returning.reset_campaign()
	peer._world_changed()
	return true


func can_edit_bots() -> bool:
	var peer: Node = _peer.get_ref()
	if peer == null or peer.authority == null or not session.enabled:
		return false
	var world: RefCounted = peer.authority.world
	if world._atomic_depth != 0:
		return false
	return (
		(session.lobby and world.level.source_path == "/NATIVE/LOBBY")
		or (session.mode == "versus" and not world.vs_state.is_empty())
	)


func set_bot_count(value: int) -> bool:
	last_error = ""
	if not can_edit_bots() or value < 0 or value > 3:
		last_error = "Change bots in the lobby or VS Battle"
		return false
	var peer: Node = _peer.get_ref()
	var world: RefCounted = peer.authority.world
	if not world.bots.set_count(world, value):
		last_error = "No free bot seat or safe spawn"
		return false
	# This is a roster delta, not a map transition. Existing identities, clocks,
	# controllers, connection tokens and the running music remain attached.
	peer.roster_changed()
	return true


func set_bot_difficulty(value: int) -> bool:
	last_error = ""
	if not can_edit_bots() or session.mode != "versus" or value not in [0, 1, 2]:
		last_error = "Change difficulty in VS Battle"
		return false
	var peer: Node = _peer.get_ref()
	peer.authority.world.bots.state.difficulty=value
	return true


func remove_bot(reference: Dictionary) -> bool:
	last_error = ""
	if not can_edit_bots():
		last_error = "Remove bots in the lobby or VS Battle"
		return false
	var peer: Node = _peer.get_ref()
	if not peer.authority.world.bots.is_bot(reference):
		last_error = "Bot is no longer present"
		return false
	var removed: bool = peer.authority.world.remove_player(reference)
	if removed: peer.roster_changed()
	return removed


func revive_bot(reference: Dictionary) -> bool:
	var peer: Node = _peer.get_ref()
	if peer==null or session.mode!="coop" or session.lobby: return false
	var server: RefCounted = peer.authority
	var player: RefCounted = server.world.resolve_player(reference)
	if player==null or not server.world.bots.is_bot(reference) or int(player.fighter.state)!=0 or server.campaign.continue_credits<=0 or not server.campaign._state.card.is_empty(): return false
	if not _revive(server,player): return false
	server.campaign.continue_credits-=1
	return true


func _banked_score(server: RefCounted, player: RefCounted, fresh: bool) -> int:
	var previous := int(player.level_stats.get("banked", 0))
	if fresh:
		return previous  # Failed-attempt points are not banked on a full retry.
	var card: Dictionary = server.campaign._state.card
	for row: Dictionary in card.get("result", {}).get("players", []):
		if row.reference == player.player_ref():
			return clampi(
				int(row.total),
				-preload("res://scripts/game/coop_score.gd").LIMIT,
				preload("res://scripts/game/coop_score.gd").LIMIT
			)
	return _peer.get_ref().returning.carry_score(server.world, player.player_ref(), previous)
