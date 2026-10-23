extends RefCounted
## Drawing from public committed intents. No remote AI, RNG or collision forecast
## writes. Human extrapolation is limited to 20 ms; there is no coarse tick buffer.
const HitFilter = preload("res://scripts/presentation/knockback_filter.gd")
const Motion = preload("res://scripts/simulation/cd_responsive_motion.gd")
const STEP_USEC := 1070460000000.0 / 212813696.0
const CLOCK_RATE_LIMIT := 0.1
const ProjectilePath = preload("res://scripts/presentation/cd_projectile_motion_path.gd")
var _human_corrections: Dictionary = {}
var _human_hit_paths: Dictionary = {}
var state: Dictionary = {}
var definition: RefCounted
var elapsed_usec := 0
var estimated_tick := 0.0
var _paths := preload("res://scripts/presentation/cd_replica_presentation.gd").new()
var _doors := preload("res://scripts/presentation/cd_door_motion_presentation.gd").new()
var _animations := preload("res://scripts/presentation/cd_sprite_animation_presentation.gd").new()
var _collision := preload("res://scripts/simulation/cd_collision_world.gd").new()
var _last_epoch := -1
var _generations: Array = []
var _flight_continuations: Dictionary = {}
var _reactions := preload("res://scripts/network/remote_reactions.gd").new()
var _reaction_time := 0.0
var _loot_geometry := preload("res://scripts/game/native_drop_geometry.gd").new()


func install(snapshot: Dictionary, content: RefCounted, server_tick: float = -1.0) -> void:
	var previous := state
	var reset: bool = (
		state.is_empty()
		or _last_epoch != int(snapshot.epoch)
		or definition != content
		or state.owner != snapshot.owner
	)
	if reset:
		previous = {}
		_animations.configure(content.catalog)
		_loot_geometry.configure(content.level)
		_reactions.configure(content.catalog)
		_reaction_time = 0.0
		_doors = preload("res://scripts/presentation/cd_door_motion_presentation.gd").new()
		_last_epoch = snapshot.epoch
		_generations = []
		_flight_continuations.clear()
		_human_corrections.clear()
		_human_hit_paths.clear()
	state = snapshot if snapshot.is_read_only() else snapshot.duplicate(true)
	var proxies: Array = state.roster.map(func(row: Dictionary) -> int: return int(row.proxy))
	for proxy: int in _human_hit_paths.keys():
		if proxy not in proxies:
			_human_hit_paths.erase(proxy)
	definition = content
	for slot: int in _flight_continuations.keys():
		var cached: Dictionary = _flight_continuations[slot]
		if (
			not state.segments.has(slot)
			or cached.segment != state.segments[slot]
			or cached.groups != state.records.groups
		):
			_flight_continuations.erase(slot)
	elapsed_usec = 0
	if reset:
		estimated_tick = maxf(
			(
				float(snapshot.revision)
				+ float(snapshot.clock.phase % 1070460000000) / 1070460000000.0
			),
			server_tick
		)
	_synchronize_human_hits(previous)
	_reactions.synchronize(previous, state, _reaction_time)
	# A snapshot replaces records, not elapsed visual time. Its source timestamp
	# can precede the pose already drawn even on LAN (publication/fragment time).
	# Clock observations calibrate rate in advance_usec, never rewind this clock.
	var boundary := floorf(float(snapshot.revision) / 24.0) * 6.0
	_paths._segments = state.segments
	_paths._groups = state.records.groups
	_doors.synchronize(state.records.groups, boundary, 6, state.records.blocked_doors)
	# Network publications outnumber world/animation boundaries. Reuse the
	# existing visual program only when its complete input is unchanged; births,
	# deaths, generations and input-phase combat changes still synchronize now.
	if (
		previous.is_empty()
		or floorf(float(previous.revision) / 24.0) * 6.0 != boundary
		or previous.records.actor_system.actors != state.records.actor_system.actors
		or (
			previous.records.actor_system.projectile_launches
			!= state.records.actor_system.projectile_launches
		)
		or (
			previous.records.actor_system.entity_generations
			!= state.records.actor_system.entity_generations
		)
	):
		var launches: Dictionary = state.records.actor_system.projectile_launches.duplicate(true)
		for index: int in range(state.records.actor_system.actors.size()):
			if not launches.has(index):
				launches[index] = {
					"generation": state.records.actor_system.entity_generations[index]
				}
		_animations.synchronize(state.records.actor_system.actors, boundary, launches)
	_generations = state.records.actor_system.entity_generations.duplicate()


func advance_usec(elapsed: int, server_tick: float = -1.0) -> void:
	elapsed_usec += maxi(0, elapsed)
	_reaction_time += float(maxi(0, elapsed)) / (STEP_USEC * 4.0)
	var step := float(maxi(0, elapsed)) / STEP_USEC
	var next := estimated_tick + step
	if server_tick >= 0:
		# Slew both positive and negative clock errors at at most ten percent.
		# A new pong cannot move actors, doors or animation instantly, including
		# zero-elapsed input pumps. Path expiry still bounds every visual forecast.
		next += clampf(server_tick - next, -step * CLOCK_RATE_LIMIT, step * CLOCK_RATE_LIMIT)
	estimated_tick = next


func sample(local_pose: Dictionary, provisional: Array = []) -> Dictionary:
	if state.is_empty():
		return {}
	var records: Dictionary = state.records
	var shown: Dictionary = _paths.sample(
		records.motion,
		records.actor_system.actors,
		records.groups,
		records.actor_system.projectile_launches,
		0.0
	)
	if state.get("versus", {}).get("phase", "playing") != "playing":
		# A waiting/result arena has no next committed interval. Keep source
		# frames, doors, bodies and physical drops at the authority boundary.
		for row: Dictionary in state.roster:
			var proxy: int = row.proxy
			if proxy < 0 or proxy >= shown.actors.size() or int(shown.actors[proxy].kind) != 20: continue
			shown.actors[proxy].local_player = row.reference == state.owner
			shown.actors[proxy].frame = _player_frame(shown.actors[proxy], row.motion.angle, local_pose.angle)
		shown.motion = local_pose.duplicate(true)
		shown.loot = state.get("loot", {}).duplicate(true)
		shown.animation_time = int(state.versus.tick) / 4.0
		return shown
	# Each path owns its source time and generation. Reattachment/reuse cannot
	# restart it or borrow an old occupant's motion, even for identical artwork.
	for slot: int in state.segments:
		var segment: Dictionary = state.segments[slot]
		if (
			segment.identity.epoch != state.epoch
			or segment.identity.generation != _generations[slot]
			or segment.source != records.actor_system.actors[slot]
		):
			continue
		var fraction := clampf(
			(estimated_tick - float(segment.start)) / float(segment.until - segment.start), 0.0, 1.0
		)
		var actor: Dictionary = shown.actors[slot]
		if int(actor.kind) == 0:
			continue
		if segment.has("path"):
			ProjectilePath.sample(actor, segment.path, fraction)
			if estimated_tick > float(segment.until):
				_continue_flight(slot, segment, actor)
		else:
			for field: String in ["x", "y", "height"]:
				if segment.end.has(field):
					actor[field] = lerpf(
						float(segment.source[field]), float(segment.end[field]), fraction
					)
	if state.has("loot"):
		shown.loot = state.loot.duplicate(true)
		var seconds := clampf((estimated_tick - float(state.revision)) * STEP_USEC / 1000000.0, 0.0, 0.12)
		for item: Dictionary in shown.loot.items:
			# Draw-only integration uses bounded 30 Hz substeps; authority retains
			# the exact rational fast phase. Drop travel per substep stays small.
			preload("res://scripts/game/native_inventory_drops.gd").move(
				item, seconds, _loot_geometry, records.groups, 1.0 / 30.0
			)
		for row: Dictionary in shown.loot.departures:
			row.age += seconds
		shown.loot.departures = shown.loot.departures.filter(
			func(row): return row.age < preload("res://scripts/game/native_inventory_drops.gd").DEPARTURE_SECONDS)
	shown.actors = _animations.sample(shown.actors, estimated_tick / 4.0, true)
	# A door's committed motor is known beyond one AI interval. Cover the next
	# publication gap, bounded to two source intervals; real blocked/reversed/
	# stopped commands still synchronize immediately and collision stays current.
	shown.actors = _reactions.sample(shown.actors, _reaction_time)
	shown.groups = _doors.sample(records.groups, estimated_tick / 4.0, 12.0)
	# Extrapolate only known human velocity, with the original static wall query.
	# Newly commanded acceleration/doors, body hits and death remain authority.
	_collision.level = definition.level
	_collision.fractions = records.groups.map(func(group): return int(group.fraction))
	for row: Dictionary in state.roster:
		var proxy: int = row.proxy
		if proxy < 0 or proxy >= shown.actors.size() or int(shown.actors[proxy].kind) != 20:
			continue
		shown.actors[proxy].local_player = row.reference == state.owner
		if row.reference == state.owner:
			continue
		var facing := float(row.motion.angle) + float(row.motion.get("angle_sub", 0)) / 65536.0
		if int(row.state) != 1:
			shown.actors[proxy].frame = _player_frame(shown.actors[proxy], facing, local_pose.angle)
			continue
		var pose := _human_pose(row, state)
		var error := _human_error(proxy)
		var origin := Vector2(pose.x, pose.y)
		var target := origin + error
		for step: int in range(1, ceili(error.length() / 6.0) + 1):
			var point := origin.lerp(target, float(step) / ceili(error.length() / 6.0))
			if _collision.query(Vector2i(point.round())).blocked:
				_human_corrections.erase(proxy)
				target = origin
				break
		pose.x = target.x
		pose.y = target.y
		shown.actors[proxy].x = pose.x
		shown.actors[proxy].y = pose.y
		shown.actors[proxy].frame = _player_frame(shown.actors[proxy], pose.angle, local_pose.angle)
	shown.motion = local_pose.duplicate(true)
	shown.actors.append_array(provisional)
	shown.animation_time = estimated_tick / 4.0
	if state.has("versus"):
		# Match time excludes waiting; the HUD keeps one time domain when a
		# participant leaves, play resumes, or results stop the next interval.
		shown.animation_time = (float(state.versus.tick) + maxf(0.0, estimated_tick - float(state.revision))) / 4.0
	return shown


## $377F6 compares the two CD players' angles before reading $3787C.
## Shared source records retain their original frame; each native view selects
## only its direction column, preserving the walk/hurt row and descriptor mirror.
func _player_frame(actor: Dictionary, facing: float, viewer: float) -> int:
	var frames: PackedInt32Array = definition.tables.player_proxy_frames
	var index := frames.find(int(actor.frame))
	if index < 0:
		return int(actor.frame)
	var direction := int(floor(fposmod(viewer - facing + 2048.0, 16384.0) / 4096.0))
	return int(frames[(index & ~3) + direction])


func _continue_flight(slot: int, segment: Dictionary, actor: Dictionary) -> void:
	if (
		float(segment.path.limit) < 1.0
		or Vector3(segment.path.velocity).is_zero_approx()
		or not segment.source.has_all(["vx", "vy", "age", "owner"])
		or (int(actor.kind) == 27 and not segment.source.has("gravity"))
	):
		return
	if not _flight_continuations.has(slot):
		# Cache only pure flight math on a private record. No World, target hits,
		# animation/effect dispatch, AI or RNG runs here. A terminal first step
		# never becomes an invented explosion, bounce or deletion on the client.
		var fractions: Array = state.records.groups.map(func(group): return int(group.fraction))
		var source: Dictionary = segment.source.duplicate()
		# The wall cursor is a private lookup accelerator, omitted from snapshots.
		# Start its sorted search at zero on this private visual copy.
		source.wall_cursor = 0
		var flight: Dictionary = (
			preload("res://scripts/simulation/cd_projectile_flight.gd")
			. advance(
				source,
				6,
				definition.level,
				fractions,
				[],
				[],
				_ignore_flight_hit,
				definition.catalog
			)
		)
		var next_actor: Dictionary = flight.state
		var continuation := {}
		if (
			int(next_actor.kind) == int(actor.kind)
			and absf(float(next_actor.x) - float(actor.x)) < 0.001
			and absf(float(next_actor.y) - float(actor.y)) < 0.001
			and absf(float(next_actor.height) - float(actor.height)) < 0.001
		):
			var path := ProjectilePath.build(
				next_actor, 6, definition.level, fractions, definition.catalog
			)
			if not path.is_empty():
				continuation = {"actor": next_actor, "path": path}
		_flight_continuations[slot] = {
			"segment": segment, "groups": state.records.groups, "next": continuation
		}
	var next: Dictionary = _flight_continuations[slot].next
	if next.is_empty():
		return
	var position: Dictionary = next.actor.duplicate()
	ProjectilePath.sample(
		position, next.path, clampf((estimated_tick - float(segment.until)) / 24.0, 0.0, 1.0)
	)
	for field: String in ["x", "y", "height"]:
		actor[field] = position[field]


static func _ignore_flight_hit(_target: int) -> bool:
	return true


## Sample old and new publications at the SAME visual time. Their difference
## isolates the correction; ordinary forecast motion does not acquire hit lag.
func _human_pose(row: Dictionary, snapshot: Dictionary) -> Dictionary:
	_collision.level = definition.level
	_collision.fractions = snapshot.records.groups.map(func(group): return int(group.fraction))
	_collision.axis_remainder = null
	var motor: Dictionary = row.motion.duplicate(true)
	var cursor := [0]
	var query := func(point: Vector2i) -> Dictionary:
		var contact: Dictionary = _collision.query(point, cursor[0])
		cursor[0] = contact.cursor
		return contact
	var steps := clampf(estimated_tick - float(snapshot.revision), 0.0, 4.0)
	for step: int in range(int(steps)):
		motor = Motion.advance(motor, definition.tables, 6, query)
	var pose := Motion.pose(motor)
	var fraction := steps - floorf(steps)
	if fraction > 0.0:
		var next := Motion.pose(Motion.advance(motor, definition.tables, 6, query))
		var origin := Vector2(float(pose.x), float(pose.y))
		var end := Vector2(float(next.x), float(next.y))
		var point := origin.lerp(end, fraction)
		if origin.distance_to(end) <= 80.0 and not _collision.query(Vector2i(point)).blocked:
			pose.x = point.x
			pose.y = point.y
	# A packet gap may finish this known displacement, but cannot restart it
	# or invent another impulse. New publications supply the next decay state.
	var boundary := floorf(float(snapshot.revision) / 24.0) * 24.0
	var proxy := int(row.proxy)
	if not _human_hit_paths.has(proxy):
		_human_hit_paths[proxy] = {}
	return HitFilter.preview(
		pose, snapshot.records.actor_system.actors[int(row.proxy)],
		clampf((estimated_tick - boundary) / 24.0, 0.0, 1.0), query,
		[definition.level, _collision.fractions, cursor[0]], _human_hit_paths[proxy]
	)


func _human_error(proxy: int) -> Vector2:
	if not _human_corrections.has(proxy):
		return Vector2.ZERO
	var entry: Dictionary = _human_corrections[proxy]
	var seconds := maxf(0.0, _reaction_time - float(entry.time)) * 4.0 * STEP_USEC / 1000000.0
	return Vector2(entry.offset) * exp(-seconds / HitFilter.RESPONSE_SECONDS)


func _synchronize_human_hits(previous: Dictionary) -> void:
	var retained := {}
	for row: Dictionary in state.roster:
		var proxy: int = row.proxy
		if row.reference == state.owner or int(row.state) != 1 or proxy < 0:
			continue
		var identity := [row.reference, proxy, state.records.actor_system.entity_generations[proxy]]
		var offset := Vector2.ZERO
		if _human_corrections.has(proxy) and _human_corrections[proxy].identity == identity:
			offset = _human_error(proxy)
		# The original public proxy frame already carries the hurt row. It is
		# sufficient to recognize hit corrections without exposing private stats
		# or changing the protocol. Late joins never replay an earlier hit.
		var frame: int = definition.tables.player_proxy_frames.find(int(state.records.actor_system.actors[proxy].frame))
		if frame >= 36 and frame < 40 and not previous.is_empty():
			for old: Dictionary in previous.roster:
				if old.reference != row.reference or old.proxy != proxy or int(old.state) != 1:
					continue
				if previous.records.actor_system.entity_generations[proxy] != identity[2]:
					continue
				var before := _human_pose(old, previous)
				var after := _human_pose(row, state)
				var delta := Vector2(before.x - after.x, before.y - after.y)
				# Large relocations are authoritative teleports, never a long trail.
				offset = offset + delta if delta.length() <= 114.0 else Vector2.ZERO
		if offset.length() <= 160.0 and offset.length() >= 0.01:
			retained[proxy] = {"identity": identity, "offset": offset, "time": _reaction_time}
	_human_corrections = retained
