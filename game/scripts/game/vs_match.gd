extends RefCounted
## Explicit native FFA policy, independent of source campaign/lives/rewards.
const Spawns = preload("res://scripts/game/vs_spawns.gd")
const Items = preload("res://scripts/simulation/cd_item_pickup.gd")
const Status = preload("res://scripts/simulation/cd_status_overlay.gd")
const Audio = preload("res://scripts/audio/cd_audio_requests.gd")
const LIMITS := [5, 10, 15, 20, 30, 50]
const MAX_ROWS := 16
const MAX_CORPSES := 32
const MAX_TICK := 1 << 48


static func periods(seconds: int) -> int:
	return ceili(seconds * 53203424.0 * 4.0 / 1070460.0)


static func _renewable(kind: int) -> bool:
	return kind in range(29, 39) or kind == 46


static func initial(world: RefCounted) -> Dictionary:
	var placements := []
	for slot: int in range(world.actor_system.actors.size()):
		if _renewable(int(world.actor_system.actors[slot].kind)):
			placements.append({"source": slot, "slot": slot, "generation": 1, "due": 0})
	return {"phase": "waiting", "limit": 15, "tick": 0,
		"rng": ResourceUID.create_id() & 0xffffffff, "rows": [], "placements": placements, "corpses": [], "result": {}}


static func row(world: RefCounted, handle: int) -> Dictionary:
	for entry: Dictionary in world.vs_state.get("rows", []):
		if int(entry.reference.id) - 1 == handle: return entry
	return {}


static func joined(world: RefCounted, player: RefCounted) -> void:
	var state: Dictionary = world.vs_state
	if state.is_empty(): return
	state.rows.append({"reference": player.player_ref(), "seat": player.seat,
		"kills": 0, "deaths": 0, "suicides": 0, "streak": 0, "awards": 0,
		"active": true, "dead": false, "respawn_at": 0})
	while state.rows.size() > MAX_ROWS:
		var index: int = state.rows.find_custom(func(entry): return not entry.active)
		if index < 0: break
		state.rows.remove_at(index)
	sync_phase(world)


static func left(world: RefCounted, handle: int) -> void:
	var entry := row(world, handle)
	if entry.is_empty(): return
	entry.active = false
	entry.respawn_at = 0
	sync_phase(world)


static func sync_phase(world: RefCounted) -> void:
	if world.vs_state.is_empty() or world.vs_state.phase == "results": return
	world.vs_state.phase = "playing" if world.players.size() >= 2 else "waiting"


static func damage(world: RefCounted, handle: int, amount: int) -> void:
	if world.vs_state.is_empty() or amount <= 0: return
	var entry := row(world, handle)
	if entry.is_empty(): return
	entry.streak = 0
	if handle not in world.vs_pending.damaged: world.vs_pending.damaged.append(handle)


static func killed(world: RefCounted, shooter: int, victim: int) -> void:
	if world.vs_state.is_empty() or world.vs_state.phase != "playing" or shooter == victim: return
	var entry := row(world, shooter)
	var target := row(world, victim)
	if entry.is_empty() or target.is_empty() or not entry.active or not target.active or target.dead: return
	if world.vs_pending.kills.any(func(event): return event.victim == victim): return
	entry.kills = mini(999999, int(entry.kills) + 1)
	world.vs_pending.kills.append({"shooter": shooter, "victim": victim})


static func died(world: RefCounted, player: RefCounted, context: Dictionary) -> bool:
	if world.vs_state.is_empty(): return false
	var entry := row(world, player.handle)
	if entry.is_empty() or entry.dead: return false
	entry.dead = true
	entry.deaths = mini(999999, int(entry.deaths) + 1)
	entry.streak = 0
	entry.respawn_at = mini(MAX_TICK, int(world.vs_state.tick) + periods(2))
	# Existing source death/flash/corpse effects have already committed. Lives
	# are compatibility storage only; native VS never runs exhaustion/continue.
	var slot: int = player.fighter.get("proxy", -1)
	if slot >= 0 and slot < world.actor_system.actors.size() and int(world.actor_system.actors[slot].kind) == 23:
		world.vs_state.corpses.append({"slot": slot, "generation": int(world.actor_system.entity_generations[slot]),
			"due": mini(MAX_TICK, int(world.vs_state.tick) + periods(60))})
	_trim_corpses(world)
	context.lives = 3
	context.death_timer = 0
	return true


static func fast_step(world: RefCounted) -> bool:
	if world.vs_state.is_empty(): return true
	sync_phase(world)
	if world.vs_state.phase != "playing": return false
	world.vs_state.tick = mini(MAX_TICK, int(world.vs_state.tick) + 1)
	_trim_corpses(world)
	for player: RefCounted in world.players:
		var entry := row(world, player.handle)
		if entry.dead and int(entry.respawn_at) <= int(world.vs_state.tick):
			_respawn(world, player, entry)
	for placement: Dictionary in world.vs_state.placements:
		if int(placement.slot) >= 0 or int(placement.due) > int(world.vs_state.tick): continue
		var slot: int = world.actor_system._allocate()
		if slot < 0: continue
		world.actor_system.actors[slot] = world.definition.catalog.actors[int(placement.source)].duplicate(true)
		placement.slot = slot
		placement.generation = int(world.actor_system.entity_generations[slot])
		placement.due = 0
	return true


static func _trim_corpses(world: RefCounted) -> void:
	var system: RefCounted = world.actor_system
	world.vs_state.corpses = world.vs_state.corpses.filter(func(body):
		return int(body.slot) < system.actors.size() and int(body.generation) == int(system.entity_generations[body.slot]) and int(system.actors[body.slot].kind) == 23)
	while not world.vs_state.corpses.is_empty():
		var body: Dictionary = world.vs_state.corpses.front()
		if world.vs_state.corpses.size() <= MAX_CORPSES and int(body.due) > int(world.vs_state.tick): break
		system.actors[int(body.slot)] = preload("res://scripts/simulation/cd_projectile_flight.gd").clear(system.actors[int(body.slot)])
		world.vs_state.corpses.pop_front()


static func _respawn(world: RefCounted, player: RefCounted, entry: Dictionary) -> void:
	var previous_seed: int = world.vs_state.rng
	var spawn := Spawns.select(world, player.handle)
	if spawn.is_empty(): return
	var system: RefCounted = world.actor_system
	var slot: int = system.restore_player_proxy(player.handle)
	if slot < 0:
		world.vs_state.rng = previous_seed
		return
	var scheme: int = player.control_scheme
	player.configure(world, player.id, player.generation, player.seat)
	player.control_scheme = scheme
	player._weapon_entities.clear()
	player.wall_cursor = 0
	player._query_remainder = 0
	player._door_remainder = 0
	player._sightings.clear()
	for key: String in ["x", "y", "angle"]: player.motion[key] = spawn[key]
	player.motion.prev_x = spawn.x
	player.motion.prev_y = spawn.y
	player.fighter.proxy = slot
	player.fighter.checkpoint_x = spawn.x
	player.fighter.checkpoint_y = spawn.y
	player.fighter.checkpoint_angle = spawn.angle
	player.world_origin = Vector2i(spawn.x, spawn.y)
	system.actors[slot].player_colour = player.seat
	system.bind_player(player.handle, player.combat_state())
	system._update_player_proxy()
	entry.dead = false
	entry.respawn_at = 0
	world.admission_state.queue = world.admission_state.queue.filter(func(event): return event.player != player.player_ref())
	world.admission_state.controls.erase(player.handle)
	world.admission_state.rates.erase(player.handle)
	world.last_events.append({"kind": "player_respawned"})


static func collected(world: RefCounted, slot: int) -> void:
	if world.vs_state.is_empty(): return
	for placement: Dictionary in world.vs_state.placements:
		if placement.slot == slot and placement.generation == int(world.actor_system.entity_generations[slot]):
			_schedule_renewal(world, placement)
			return


static func _schedule_renewal(world: RefCounted, placement: Dictionary) -> void:
	placement.slot = -1
	placement.due = mini(MAX_TICK, int(world.vs_state.tick) + periods(60))


static func finish_update(world: RefCounted) -> void:
	if world.vs_state.is_empty(): return
	_trim_corpses(world)
	# A map mine becomes a source explosion when triggered. Retire only its
	# placement binding; leave the real blast/damage/animation slot untouched.
	for placement: Dictionary in world.vs_state.placements:
		var slot: int = placement.slot
		if slot < 0 or int(world.definition.catalog.actors[placement.source].kind) != 46: continue
		if int(world.actor_system.entity_generations[slot]) != int(placement.generation): continue
		if int(world.actor_system.actors[slot].kind) != 46:
			_schedule_renewal(world, placement)
	for player: RefCounted in world.players:
		var entry := row(world, player.handle)
		if entry.is_empty(): continue
		if int(player.fighter.state) != 1 or player.handle in world.vs_pending.damaged:
			entry.streak = 0
		else:
			for event: Dictionary in world.vs_pending.kills:
				if event.shooter != player.handle: continue
				entry.streak += 1
				if entry.streak != 3: continue
				entry.streak = 0
				entry.awards = mini(999999, int(entry.awards) + 1)
				var selected: int = player.weapon_state.selected
				if selected >= 0 and int(player.weapon_state.inventory[selected].kind) > 0:
					player.weapon_state.inventory[selected].ammo = Items.FULL_AMMO
					player.weapon_state.inventory[selected].extra = 35
				player.fighter.reward_timer = 70
				player.fighter = Status.request(player.fighter, Status.BONUS)
				world.audio_requested.emit(Audio.sample(0x1f72a, player.motion, player.player_ref()))
		player.fighter.kill_chain = entry.streak
		world.actor_system.bind_player(player.handle, player.combat_state())
	world.vs_pending = {"damaged": [], "kills": []}
	if world.vs_state.phase != "playing": return
	var best := 0
	for entry: Dictionary in world.vs_state.rows:
		if entry.active: best = maxi(best, int(entry.kills))
	if best < int(world.vs_state.limit): return
	var winners := []
	for entry: Dictionary in world.vs_state.rows:
		if entry.active and int(entry.kills) == best: winners.append(entry.reference.duplicate())
	world.vs_state.result = {"limit": int(world.vs_state.limit), "winners": winners,
		"rows": world.vs_state.rows.duplicate(true)}
	world.vs_state.phase = "results"
	world.admission_state.queue.clear()
	world.admission_state.controls.clear()
	world.admission_state.rates.clear()
	world.last_events.append({"kind": "vs_finished"})


static func public_state(world: RefCounted) -> Dictionary:
	var result: Dictionary = world.vs_state.duplicate(true)
	result.erase("rng")
	result.erase("placements")
	result.erase("corpses")
	return result


static func valid(value: Variant, definition: RefCounted, public: bool = false) -> bool:
	var fields := ["phase", "limit", "tick", "rows", "result"] + ([] if public else ["rng", "placements", "corpses"])
	if not value is Dictionary or value.size() != fields.size() or not value.has_all(fields): return false
	if not definition.level.get_meta("battle_mode", false): return false
	if value.phase not in ["waiting", "playing", "results"] or not _int(value.limit, 5, 50) or value.limit not in LIMITS: return false
	if not _int(value.tick, 0, MAX_TICK): return false
	if not public and not _int(value.rng, 0, 0xffffffff): return false
	if not _rows_valid(value.rows): return false
	if not public:
		if not value.placements is Array: return false
		var expected := []
		for slot: int in range(definition.catalog.actors.size()):
			if _renewable(int(definition.catalog.actors[slot].kind)): expected.append(slot)
		if not value.corpses is Array or value.corpses.size() > MAX_CORPSES: return false
		var corpse_slots := []
		for body: Variant in value.corpses:
			if not body is Dictionary or body.size() != 3 or not body.has_all(["slot", "generation", "due"]): return false
			if not _int(body.slot, 0, 179) or body.slot in corpse_slots or not _int(body.generation, 1, 0xffffffff) or not _int(body.due, 0, MAX_TICK): return false
			corpse_slots.append(body.slot)
		if value.placements.size() != expected.size(): return false
		var live_slots := []
		for index: int in range(expected.size()):
			var placement: Variant = value.placements[index]
			if not placement is Dictionary or placement.size() != 4 or not placement.has_all(["source", "slot", "generation", "due"]): return false
			if not placement.source is int or placement.source != expected[index] or not _int(placement.slot, -1, 179) or not _int(placement.generation, 1, 0xffffffff) or not _int(placement.due, 0, MAX_TICK): return false
			if placement.slot >= 0:
				if placement.slot in live_slots or placement.due != 0: return false
				live_slots.append(placement.slot)
			elif placement.due == 0: return false
	if not value.result is Dictionary: return false
	if value.phase != "results": return value.result.is_empty()
	if value.result.size() != 3 or not value.result.has_all(["limit", "winners", "rows"]): return false
	if not _int(value.result.limit, 5, 50) or value.result.limit != value.limit or not _rows_valid(value.result.rows): return false
	if not value.result.winners is Array or value.result.winners.is_empty() or value.result.winners.size() > 4: return false
	var seen := []
	var best := 0
	for entry: Dictionary in value.result.rows:
		if entry.active: best = maxi(best, int(entry.kills))
	for winner: Variant in value.result.winners:
		if not winner is Dictionary or winner.size() != 2 or not winner.has_all(["id", "generation"]) or not _int(winner.id, 1, 0xffffffff) or not _int(winner.generation, 1, 0xffffffff): return false
		if winner in seen: return false
		seen.append(winner)
		if not value.result.rows.any(func(entry): return entry.reference == winner and entry.active and entry.kills == best and entry.kills >= value.limit): return false
	return value.result.winners == value.result.rows.filter(func(entry): return entry.active and entry.kills == best and entry.kills >= value.limit).map(func(entry): return entry.reference)


static func valid_bindings(value: Dictionary, actors: Array, generations: Array, players: Array, definition: RefCounted, public: bool = false) -> bool:
	var current: Array = value.rows.filter(func(entry): return entry.active)
	if current.size() != players.size(): return false
	for player: Dictionary in players:
		var reference: Dictionary = player.reference if public else {"id": player.id, "generation": player.generation}
		if not current.any(func(entry): return entry.reference == reference and entry.seat == player.seat): return false
		if public and not current.any(func(entry): return entry.reference==reference and entry.get("controller","human")==player.get("controller","human")): return false
	if public: return true
	for body: Dictionary in value.corpses:
		var slot: int = body.slot
		if slot >= actors.size() or slot >= generations.size() or generations[slot] != body.generation or actors[slot].kind != 23: return false
	for placement: Dictionary in value.placements:
		var slot: int = placement.slot
		if slot < 0: continue
		if slot >= actors.size() or slot >= generations.size() or generations[slot] != placement.generation: return false
		var actor: Dictionary = actors[slot]
		var source: Dictionary = definition.catalog.actors[int(placement.source)]
		if actor.kind != source.kind or actor.x != source.x or actor.y != source.y: return false
	return true


static func _rows_valid(value: Variant) -> bool:
	if not value is Array or value.size() > MAX_ROWS: return false
	var identities := []
	var seats := []
	for entry: Variant in value:
		if not entry is Dictionary or entry.size() != 10 + int(entry.has("controller")) + int(entry.has("name")) or not entry.has_all(["reference", "seat", "kills", "deaths", "suicides", "streak", "awards", "active", "dead", "respawn_at"]): return false
		if entry.has("name") and not preload("res://scripts/network/network_settings.gd").valid_name(entry.name): return false
		if entry.has("controller") and entry.controller not in ["bot","human"]: return false
		if not entry.reference is Dictionary or entry.reference.size() != 2 or not entry.reference.has_all(["id", "generation"]): return false
		if not _int(entry.reference.id, 1, 0xffffffff) or not _int(entry.reference.generation, 1, 0xffffffff) or entry.reference.id in identities: return false
		identities.append(entry.reference.id)
		if not _int(entry.seat, 0, 3) or not entry.active is bool or not entry.dead is bool: return false
		if entry.active:
			if entry.seat in seats: return false
			seats.append(entry.seat)
		for key: String in ["kills", "deaths", "suicides", "awards"]:
			if not _int(entry[key], 0, 999999): return false
		if not _int(entry.streak, 0, 2) or not _int(entry.respawn_at, 0, MAX_TICK): return false
	return true


static func _int(value: Variant, low: int, high: int) -> bool:
	return value is int and value >= low and value <= high
