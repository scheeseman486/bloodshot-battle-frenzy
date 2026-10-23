extends RefCounted
## Host-only native controllers. Portable semantic state; shared rebuildable map.
const Navigation = preload("res://scripts/game/bot_navigation.gd")
const Perception = preload("res://scripts/game/bot_perception.gd")
const Controller = preload("res://scripts/game/bot_controller.gd")
const Yield = preload("res://scripts/game/bot_yield.gd")
const Admission = preload("res://scripts/game/input_admission.gd")
var state := {"version": 1, "difficulty": 1, "rows": []}
var navigation := Navigation.new()
# Diagnostic counters are not semantic state and never affect decisions.
var metrics := {"calls": 0, "usec": 0, "max_usec": 0, "paths": 0}
var last_error := ""


static func new_row(reference: Dictionary, seat: int) -> Dictionary:
	return {
		"reference": reference.duplicate(),
		"seed": (12345 + seat * 98123) & 0xffffffff,
		"next": seat * 25000,
		"alive": false,
		"memory": [],
		"cues": [],
		"items": [],
		"hazards": [],
		"goal": Vector2i.ZERO,
		"route": [],
		"route_goal": Vector2i.ZERO,
		"route_at": 0,
		"progress": Vector2i.ZERO,
		"stuck": 0,
		"error": 0.0,
		"error_at": 0,
		"fire": false,
		"cycle": false,
		"focus_id": -1,
		"focus_generation": 0,
		"strafe": 0,
		"roam_at": 0
	}


func is_bot(reference: Dictionary) -> bool:
	return state.rows.any(func(row): return row.reference == reference)


func row(reference: Dictionary) -> Dictionary:
	for entry: Dictionary in state.rows:
		if entry.reference == reference:
			return entry
	return {}


func count(world: RefCounted) -> int:
	return world.players.filter(func(player): return is_bot(player.player_ref())).size()


func may_collect(world: RefCounted, handle: int, kind: int = 0) -> bool:
	return (
		not world.vs_state.is_empty()
		or not state.rows.any(func(entry): return int(entry.reference.id) - 1 == handle)
		or kind in range(29, 39)
	)


func sync(world: RefCounted) -> void:
	state.rows = state.rows.filter(
		func(entry): return world.resolve_player(entry.reference) != null
	)
	if world.actor_system == null:
		return
	world.actor_system.weapon_only_collectors = []
	if world.vs_state.is_empty():
		for entry: Dictionary in state.rows:
			world.actor_system.weapon_only_collectors.append(int(entry.reference.id) - 1)


func set_count(world: RefCounted, desired: int) -> bool:
	if (
		desired < 0
		or desired > 3
		or world._atomic_depth != 0
		or not world.definition.get_meta("session_flow", false)
	):
		return false
	var humans: int = world.players.size() - count(world)
	if (humans == 0 and desired > 0) or desired > 4 - humans:
		return false
	# Preflight every identity/proxy and usable spawn before touching the roster.
	# VS starts can be occupied mid-match; a failed batch must not add some bots
	# or consume the shared match's spawn RNG before reporting failure.
	var additions := desired - count(world)
	var seats := []
	for seat: int in range(4):
		if not world.players.any(func(player): return player.seat == seat):
			seats.append(seat)
	if additions > 0 and not world.has_player_capacity(seats.slice(0, additions)):
		return false
	var batch := {}
	if additions > 0 and not world.vs_state.is_empty():
		batch = preload("res://scripts/game/vs_spawns.gd").batch(world, additions)
		if batch.is_empty(): return false
	while count(world) > desired:
		var last: Dictionary = state.rows.back()
		world.remove_player(last.reference)
	var spawned := 0
	while count(world) < desired:
		var seat := -1
		for candidate: int in range(4):
			if not world.players.any(func(player): return player.seat == candidate):
				seat = candidate
				break
		var reference: Dictionary = world.spawn_player(seat, batch.spawns[spawned] if not batch.is_empty() else {})
		if reference.is_empty():
			return false
		mark(world, reference)
		spawned += 1
	if not batch.is_empty(): world.vs_state.rng = batch.rng
	sync(world)
	return true


func mark(world: RefCounted, reference: Dictionary) -> void:
	var player: RefCounted = world.resolve_player(reference)
	if player == null or is_bot(reference):
		return
	if world.level.source_path != "/NATIVE/LOBBY":
		navigation.configure(world.level)
	elif navigation.geometry.cells.is_empty():
		# Lobby courtesy needs collision only, never a cold A* build mid-frame.
		navigation.geometry.configure(world.level)
	state.rows.append(new_row(reference, player.seat))
	state.rows.sort_custom(
		func(a, b): return world.resolve_player(a.reference).seat < world.resolve_player(b.reference).seat
	)
	if not world.vs_state.is_empty():
		preload("res://scripts/game/vs_match.gd").row(world, player.handle).controller = "bot"
	sync(world)


func admit_human(world: RefCounted) -> Dictionary:
	last_error = ""
	# Compatible bootstrap ACKs commit serially on the authority thread. A pure
	# capacity/spawn preflight preserves the bot on failure without cloning a map.
	if not state.rows.is_empty():
		var replacement: Dictionary = world.replace_player(state.rows.back().reference)
		if replacement.is_empty():
			last_error = "No valid replacement spawn or player capacity"
		return replacement
	for seat: int in range(4):
		if not world.players.any(func(player): return player.seat == seat):
			return world.spawn_player(seat)
	return {}


func now_usec(world: RefCounted) -> int:
	@warning_ignore("integer_division")
	return (
		world.clock.tick_count
		* 1000000
		* int(world.timing_profile.input_denominator)
		/ world.clock._numerator
	)


func observe(world: RefCounted, player: RefCounted) -> Dictionary:
	navigation.configure(world.level)
	return Perception.observe(world, player, navigation)


func step(world: RefCounted) -> void:
	if state.rows.is_empty():
		return
	var now := now_usec(world)
	var coop: bool = world.vs_state.is_empty()
	var playable: bool = (
		world.level.source_path != "/NATIVE/LOBBY"
		and not world.is_complete()
		and not world.is_game_over()
	)
	playable = (
		playable
		and world.players.any(
			func(player): return not is_bot(player.player_ref()) and int(player.fighter.state) in [1, 2, 3, 4]
		)
	)
	if not coop:
		playable = playable and world.vs_state.phase == "playing"
	var yielding := _contact_pressure(world) if coop and not world.is_complete() and not world.is_game_over() else {}
	for entry: Dictionary in state.rows:
		var player: RefCounted = world.resolve_player(entry.reference)
		if player == null:
			continue
		if coop and player.keys.any(func(key): return int(key.kind)!=0):
			# Recover legacy streak-granted keys without discarding weapons or
			# rewriting an already frozen result/checkpoint at load time.
			preload("res://scripts/game/native_inventory_drops.gd").scatter(world,player,{},false,true)
		if int(player.fighter.state)==1 and yielding.has(player.handle):
			entry.fire = false
			for target: Dictionary in entry.memory: target.visible = false
			Admission.bot_controls(world,entry.reference,Yield.controls(yielding[player.handle],int(player.motion.angle)),0.0)
			continue
		if not playable or int(player.fighter.state) != 1:
			entry.alive = false
			entry.memory = []
			entry.cues = []
			entry.hazards = []
			entry.route = []
			entry.fire = false
			Admission.bot_controls(world, entry.reference, {"held": 0xffffffff, "strafe": 0}, 0.0)
			continue
		if not entry.alive:
			entry.alive = true
			entry.goal = Vector2i(player.motion.x, player.motion.y)
			entry.progress = entry.goal
			entry.next = now + player.seat * 25000
		if now >= int(entry.next):
			var stamp := Time.get_ticks_usec()
			_decide(world, player, entry, now, coop)
			var elapsed := Time.get_ticks_usec() - stamp
			metrics.calls += 1
			metrics.usec += elapsed
			metrics.max_usec = maxi(metrics.max_usec, elapsed)
			entry.next = now + 100000
		var here := Vector2(player.motion.x, player.motion.y)
		while not entry.route.is_empty() and here.distance_to(Vector2(entry.route.front())) < 96:
			entry.route.pop_front()
		var destination := Vector2(
			entry.route.front() if not entry.route.is_empty() else entry.goal
		)
		var delta := destination - here
		var desired := atan2(delta.x, delta.y) * 16384.0 / TAU
		var error: float = entry.error if entry.fire else 0.0
		var turn := fposmod(desired + error - float(player.motion.angle) + 8192.0, 16384.0) - 8192.0
		var held := 0xffffffff
		if delta.length() > 120 and absf(turn) < 1600:
			held &= ~1
		if entry.fire and delta.length() < 480:
			held |= 1
		if entry.fire and absf(turn) < 260:
			held &= ~16
		if entry.cycle and int(now/100000)%2==0: held&=~32
		if int(now / 200000) % 5 == player.seat:
			held &= ~64
		# A route that stops progressing causes backing away before a new bounded search.
		if int(entry.stuck) >= 8:
			held |= 1
			held &= ~2
		var level: int = 1 if coop else int(state.difficulty)
		var rate := clampf(turn * 10.0, -Controller.TURN[level], Controller.TURN[level])
		Admission.bot_controls(
			world, entry.reference, {"held": held, "strafe": int(entry.strafe)}, rate
		)


## Local body contact is an allowed teammate observation. Pressure originates
## only from a human's held translation, then passes through nearby bot bodies.
func _contact_pressure(world: RefCounted) -> Dictionary:
	var participants := []
	for player: RefCounted in world.players:
		if int(player.fighter.state)!=1: continue
		var bot := is_bot(player.player_ref())
		var intent := Vector2.ZERO
		if not bot:
			var controls: Dictionary = world.admission_state.controls.get(player.handle,{"held":0xffffffff,"strafe":0})
			var forward := int((int(controls.held)&1)==0)-int((int(controls.held)&2)==0)
			var angle := float(player.motion.angle)*TAU/16384.0
			intent = Vector2(sin(angle),cos(angle))*forward + Vector2(cos(angle),-sin(angle))*int(controls.strafe)
		participants.append({"id":player.handle,"bot":bot,"point":Vector2(player.motion.x,player.motion.y),"intent":intent})
	return Yield.solve(participants,func(a, b): return navigation.geometry.line_clear(a,b,world.groups) and navigation.geometry.obstacle(b,world.groups).is_empty())


func _decide(
	world: RefCounted, player: RefCounted, entry: Dictionary, now: int, coop: bool
) -> void:
	var view := observe(world, player)
	var here: Vector2i = view.position
	# Forget a finite/drop pickup only after its remembered location is inspected.
	# Renewable original weapons are represented by explicit visible-empty cues.
	entry.items=entry.items.filter(func(item): return not Perception.visible(navigation,world.groups,player.motion,item.point) or view.items.any(func(seen): return seen.id==item.id))
	var remaining := Vector2(here).distance_to(Vector2(entry.goal))
	if Vector2(here).distance_to(Vector2(entry.progress)) < 20 and remaining>180 and not (entry.fire and remaining<480):
		entry.stuck = mini(20, int(entry.stuck) + 1)
	else:
		entry.stuck = 0
	entry.progress = here
	Controller.decide(entry, view, now, int(state.difficulty), coop)
	var useful_supply: bool = entry.items.any(func(item): return now>=int(item.due) and ((int(item.kind)==43 and view.health<70) or (int(item.kind) in range(29,39) and view.selected<0)))
	if not coop and not useful_supply and view.targets.is_empty() and entry.memory.is_empty() and entry.cues.is_empty():
		if (
			now >= int(entry.roam_at)
			or Vector2(here).distance_to(Vector2(entry.goal)) < 160
			or entry.stuck >= 12
		):
			if not navigation.walkable.is_empty():
				entry.goal = navigation.walkable[
					Controller.random(entry) % navigation.walkable.size()
				]
			entry.roam_at = now + 6000000
	if coop and view.targets.is_empty() and view.friends.is_empty():
		entry.goal = here
	var direct: bool = navigation.geometry.line_clear(
		Vector2(here), Vector2(entry.goal), world.groups
	)
	if direct:
		entry.route = []
	elif (
		now - int(entry.route_at) >= 500000
		and (
			entry.route.is_empty()
			or entry.route_goal != entry.goal
			or now - int(entry.route_at) > 2000000
			or entry.stuck >= 8
		)
	):
		entry.route = navigation.path(here, entry.goal)
		entry.route_goal = entry.goal
		entry.route_at = now
		metrics.paths += 1


func can_fire(world: RefCounted, player: RefCounted) -> bool:
	var entry := row(player.player_ref())
	if entry.is_empty():
		return true
	if not entry.fire:
		return false
	var current := observe(world, player)
	var target: Array = current.targets.filter(
		func(candidate): return candidate.id == entry.focus_id and candidate.generation == entry.focus_generation
	)
	if target.is_empty():
		return false
	var vector := Vector2(target[0].point) - Vector2(current.position)
	var desired := atan2(vector.x, vector.y) * 16384.0 / TAU
	if absf(fposmod(desired - float(player.motion.angle) + 8192.0, 16384.0) - 8192.0) > 300:
		return false
	if world.vs_state.is_empty():
		for friend: Dictionary in current.friends:
			if (
				(
					Geometry2D
					. get_closest_point_to_segment(
						Vector2(friend.point), Vector2(current.position), Vector2(target[0].point)
					)
					. distance_to(Vector2(friend.point))
				)
				< 140
			):
				return false
			if (
				int(player.weapon_state.selected) >= 0
				and Vector2(friend.point).distance_to(Vector2(target[0].point)) < 700
			):
				return false
	return true


func hear(world: RefCounted, request: Dictionary) -> void:
	if state.rows.is_empty() or not request.has("position") or request.get("kind", "") != "sample":
		return
	if not preload("res://scripts/audio/cd_audio_requests.gd").valid_position(request.position):
		return
	navigation.configure(world.level)
	var now := now_usec(world)
	var origin := Vector2(request.position.x, request.position.y)
	for entry: Dictionary in state.rows:
		var player: RefCounted = world.resolve_player(entry.reference)
		if (
			player == null
			or int(player.fighter.state) != 1
			or request.get("emitter", {}) == entry.reference
		):
			continue
		var here := Vector2(player.motion.x, player.motion.y)
		var distance := here.distance_to(origin)
		# Match native audio's outer envelope. Conservative LOS occlusion avoids
		# granting an exact acoustic path or information through a sealed door.
		if (
			distance > 72.0 * 256.0
			or not navigation.geometry.line_clear(here, origin, world.groups)
		):
			continue
		var cue := {
			"bearing": posmod(roundi((origin - here).angle() * 8.0 / TAU), 8),
			"band": 512 if distance < 6.0 * 256.0 else 1536,
			"at": now
		}
		if not entry.cues.is_empty() and entry.cues.back() == cue:
			continue
		if entry.cues.size() >= 8:
			entry.cues.pop_front()
		entry.cues.append(cue)


static func valid(value: Variant, players: Array) -> bool:
	if (
		not value is Dictionary
		or value.size() != 3
		or not value.has_all(["version", "difficulty", "rows"])
	):
		return false
	if (
		not value.version is int
		or value.version != 1
		or not value.difficulty is int
		or value.difficulty < 0
		or value.difficulty > 2
	):
		return false
	if not value.rows is Array or value.rows.size() > 3:
		return false
	var identities := []
	for entry: Variant in value.rows:
		if not entry is Dictionary or not entry.get("reference") is Dictionary:
			return false
		var reference: Dictionary = entry.reference
		if reference.size() != 2 or not reference.has_all(["id", "generation"]):
			return false
		if (
			not reference.id is int
			or not reference.generation is int
			or reference.id < 1
			or reference.generation < 1
		):
			return false
		if (
			reference.id in identities
			or not players.any(
				func(player): return player.id == reference.id and player.generation == reference.generation
			)
		):
			return false
		identities.append(reference.id)
		var template := new_row(reference, 0)
		if entry.size() != template.size():
			return false
		for key: String in template:
			if not entry.has(key) or typeof(entry[key]) != typeof(template[key]):
				return false
		for key: String in ["next", "route_at", "stuck", "error_at", "roam_at"]:
			if entry[key] < 0 or entry[key] > (1 << 48):
				return false
		if (
			entry.seed < 0
			or entry.seed > 0xffffffff
			or not is_finite(entry.error)
			or absf(entry.error) > 1024
			or entry.stuck > 20
		):
			return false
		if (
			entry.focus_id < -1
			or entry.focus_id > 0xffffffff
			or entry.focus_generation < 0
			or entry.focus_generation > 0xffffffff
		):
			return false
		if (
			entry.strafe not in [-1, 0, 1]
			or entry.route.size() > 2048
			or entry.memory.size() > 32
			or entry.items.size() > 32
			or entry.hazards.size() > 32
			or entry.cues.size() > 8
		):
			return false
		for point: Variant in entry.route:
			if not _point(point):
				return false
		for point: Variant in entry.hazards:
			if not _point(point): return false
		for key: String in ["goal", "route_goal", "progress"]:
			if not _point(entry[key]): return false
		for memory: Variant in entry.memory:
			if (
				not memory is Dictionary
				or memory.size() != 6
				or not memory.has_all(["id", "generation", "point", "seen", "ready", "visible"])
			):
				return false
			if (
				not memory.id is int
				or not memory.generation is int
				or not memory.point is Vector2i
				or not memory.visible is bool
			):
				return false
			if not _time(memory.seen) or not _time(memory.ready):
				return false
			if memory.id<0 or memory.id>0xffffffff or memory.generation<1 or memory.generation>0xffffffff or not _point(memory.point): return false
		for item: Variant in entry.items:
			if (
				not item is Dictionary
				or item.size() != 5
				or not item.has_all(["id", "point", "kind", "seen", "due"])
			):
				return false
			if (
				not item.id is int
				or not item.kind is int
				or not item.point is Vector2i
				or not _time(item.seen)
				or not _time(item.due)
			):
				return false
			if item.kind not in range(29,39) and item.kind!=43: return false
			if not _point(item.point): return false
		for cue: Variant in entry.cues:
			if (
				not cue is Dictionary
				or cue.size() != 3
				or not cue.has_all(["bearing", "band", "at"])
			):
				return false
			if (
				not cue.bearing is int
				or cue.bearing < 0
				or cue.bearing > 7
				or cue.band not in [512, 1536]
				or not _time(cue.at)
			):
				return false
	return true


static func _time(value: Variant) -> bool:
	return value is int and value >= 0 and value <= (1 << 48)


static func _point(value: Variant) -> bool:
	return value is Vector2i and absi(value.x)<=65536 and absi(value.y)<=65536
