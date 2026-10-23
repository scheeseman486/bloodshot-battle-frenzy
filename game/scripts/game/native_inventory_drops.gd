extends RefCounted
## Native multiplayer policy. CD single-player inventory/lifecycle is unchanged.
const AudioRequests = preload("res://scripts/audio/cd_audio_requests.gd")
const FULL_AMMO := 0x150000
const MAX_ITEMS := 512
const DEPARTURE_SECONDS := 0.6
const GRAVITY := 420.0
const FLOOR_DRAG := 8.0
const PICKUP_DELAY := 0.7
const FAST_SECONDS := 1070460.0 / (53203424.0 * 4.0)
const DATA = preload("res://scripts/assets/cd_level_decoder.gd")


static func initial() -> Dictionary:
	return {"next_id": 1, "items": [], "departures": []}


static func frame_for_kind(catalog: Resource, kind: int) -> int:
	# Source six-byte placement templates at $531AC; lookup supports weapons
	# absent from this map, without hardcoding extracted artwork or frame IDs.
	for offset: int in range(12, 0xf1, 6):
		var at := 0x531ac - 0x8000 + offset
		if DATA._u16(catalog._shell_bytes, at + 4) == kind:
			return DATA._u32(catalog._shell_bytes, at)
	return 0


static func scatter(world: RefCounted, player: RefCounted, context: Dictionary = {}, health: bool = false, keys_only: bool = false) -> void:
	if world.loot_state.is_empty():
		return
	var keys: Array = context.get("keys", player.keys)
	var weapons: Dictionary = {"inventory":[]} if keys_only else context.get("weapons", player.weapon_state)
	var origin := Vector2(context.get("x", player.motion.x), context.get("y", player.motion.y))
	if not world._loot_geometry.bounds.has_point(origin):
		origin = Vector2(world.level.spawn)
	origin = world._loot_geometry.recover(origin, Vector2(world.level.spawn), world.groups)
	var payloads := []
	if health: payloads.append({"kind": 43, "ammo": 0})
	for key: Dictionary in keys:
		if int(key.kind) != 0:
			payloads.append({"kind": int(key.kind) + 39, "ammo": 0})
	for weapon: Dictionary in weapons.inventory:
		if int(weapon.kind) != 0:
			payloads.append({"kind": int(weapon.kind) + 28, "ammo": int(weapon.ammo)})
	for index: int in range(payloads.size()):
		var payload: Dictionary = payloads[index]
		# Pressure stacks conserve quantity and total ammo at the physical limit,
		# without consuming original actor slots or losing progression keys.
		var stack := -1
		if world.loot_state.items.size() >= MAX_ITEMS:
			stack = world.loot_state.items.find_custom(
				func(item): return item.kind == payload.kind
			)
		if stack >= 0:
			world.loot_state.items[stack].count += 1
			world.loot_state.items[stack].ammo += payload.ammo
			if not world.vs_state.is_empty():
				world.loot_state.items[stack].expires_at = mini(1 << 48, int(world.vs_state.tick) + preload("res://scripts/game/vs_match.gd").periods(60))
		else:
			if world.loot_state.items.size() >= MAX_ITEMS:
				_merge_for_space(world.loot_state.items)
			var direction := Vector2.from_angle(index * 2.3999632297 + player.seat * 1.7)
			var velocity := direction * (110.0 + (index % 3) * 12.0)
			world.loot_state.items.append({
				"id": world.loot_state.next_id, "kind": payload.kind, "ammo": payload.ammo,
				"count": 1, "x": origin.x, "y": origin.y, "z": 32.0,
				"vx": velocity.x, "vy": velocity.y, "vz": 20.0 + (index % 3) * 5.0,
				"age": 0.0, "anchor_x": origin.x, "anchor_y": origin.y
			})
			world.loot_state.next_id += 1
			if not world.vs_state.is_empty():
				world.loot_state.items.back().expires_at = mini(1 << 48, int(world.vs_state.tick) + preload("res://scripts/game/vs_match.gd").periods(60))
	for index: int in range(keys.size()):
		keys[index] = {"kind": 0, "timer": 0}
	for index: int in range(weapons.inventory.size()):
		weapons.inventory[index] = {"kind": 0, "ammo": 0, "extra": 0}
	weapons.selected = -1
	weapons.buffered = 0
	weapons.special = -1
	player.keys = keys
	if not keys_only: player.weapon_state = weapons
	if not context.is_empty():
		context.keys = keys
		context.weapons = weapons


static func depart(world: RefCounted, player: RefCounted) -> void:
	var slot := int(world.actor_system.player_proxies.get(player.handle, -1))
	if slot < 0 or int(world.actor_system.actors[slot].kind) != 20:
		return
	var proxy: Dictionary = world.actor_system.actors[slot]
	world.audio_requested.emit(AudioRequests.sample(0x2547e, player.motion, player.player_ref()))
	# Bound short-lived presentation history across rapid reconnects.
	world.loot_state.departures.append({"id": world.loot_state.next_id,
		"x": float(player.motion.x), "y": float(player.motion.y),
		"frame": int(proxy.frame), "age": 0.0, "player_colour": player.seat})
	world.loot_state.next_id += 1
	if world.loot_state.departures.size() > 16:
		world.loot_state.departures.pop_front()


static func _merge_for_space(items: Array) -> void:
	# There are only thirteen pickup kinds. At the bounded physical-view limit
	# two records necessarily share a kind. Preserve quantity and total ammo;
	# pressure stacks divide that remaining ammo evenly on later collection.
	var first := {}
	for index: int in range(items.size()):
		var item: Dictionary = items[index]
		if first.has(item.kind):
			var other: Dictionary = items[first[item.kind]]
			other.count += item.count
			other.ammo += item.ammo
			if item.has("expires_at"): other.expires_at = maxi(int(other.get("expires_at", 0)), int(item.expires_at))
			items.remove_at(index)
			return
		first[item.kind] = index


static func advance(world: RefCounted, seconds: float) -> void:
	if world.loot_state.is_empty():
		return
	if not world.vs_state.is_empty():
		world.loot_state.items = world.loot_state.items.filter(func(item): return int(item.expires_at) > int(world.vs_state.tick))
	for departure: Dictionary in world.loot_state.departures:
		departure.age += seconds
	world.loot_state.departures = world.loot_state.departures.filter(
		func(row): return row.age < DEPARTURE_SECONDS
	)
	for item: Dictionary in world.loot_state.items:
		var geometry: RefCounted = world._loot_geometry
		var point := Vector2(item.x, item.y)
		var anchor := Vector2(item.anchor_x, item.anchor_y)
		if not geometry.obstacle(point, world.groups).is_empty() and not geometry.obstacle(anchor, world.groups).is_empty():
			# If both lie in a closing doorway, keep the key on the side of
			# a nearby living participant rather than choosing an arbitrary side.
			var best := 512.0
			for player: RefCounted in world.players:
				if int(player.fighter.state) != 1:
					continue
				var target := Vector2(player.motion.x, player.motion.y)
				if point.distance_to(target) < best and geometry.obstacle(target, world.groups).is_empty() and geometry.line_clear(point, target, world.groups, false):
					best = point.distance_to(target)
					item.anchor_x = target.x
					item.anchor_y = target.y
		move(item, seconds, geometry, world.groups)
	collect(world)


static func move(
	item: Dictionary, seconds: float, geometry: RefCounted, groups: Array,
	maximum_step: float = FAST_SECONDS
) -> void:
	# Settled items stay byte-stable on the wire; still check closing-door safety.
	if item.age >= PICKUP_DELAY and item.z == 0.0 and item.vz == 0.0 and item.vx == 0.0 and item.vy == 0.0:
		if geometry.obstacle(Vector2(item.x, item.y), groups).is_empty():
			return
	# Fixed authority steps are ~5 ms. Bound/subdivide presentation forecasts too.
	var steps := maxi(1, ceili(seconds / maximum_step))
	var dt := seconds / steps
	for step: int in range(steps):
		if item.age < PICKUP_DELAY:
			item.age = minf(PICKUP_DELAY, item.age + dt)
		var point := Vector2(item.x, item.y)
		var safe: Vector2 = geometry.recover(point, Vector2(item.anchor_x, item.anchor_y), groups)
		if safe != point:
			point = safe
			item.vx = 0.0
			item.vy = 0.0
		var velocity := Vector2(item.vx, item.vy)
		var candidate := point + velocity * dt
		var hit: Dictionary = geometry.obstacle(candidate, groups)
		if hit.is_empty():
			point = candidate
		elif velocity.dot(hit.normal) < 0:
			velocity = velocity.bounce(hit.normal) * 0.35
		item.vz -= GRAVITY * dt
		item.z += item.vz * dt
		if item.z <= 0:
			item.z = 0.0
			item.vz = -item.vz * 0.18 if item.vz < -60.0 else 0.0
			velocity *= exp(-FLOOR_DRAG * dt)
			if velocity.length_squared() < 1.0:
				velocity = Vector2.ZERO
		item.x = point.x
		item.y = point.y
		item.vx = velocity.x
		item.vy = velocity.y


static func collect(world: RefCounted) -> void:
	for item: Dictionary in world.loot_state.items:
		if item.age < PICKUP_DELAY or item.z > 24.0:
			continue
		for player: RefCounted in world.players:
			if int(player.fighter.state) != 1:
				continue
			if not world.bots.may_collect(world,player.handle,int(item.kind)): continue
			var point := Vector2(player.motion.x, player.motion.y)
			var origin := Vector2(item.x, item.y)
			if absf(point.x - origin.x) > 128 or absf(point.y - origin.y) > 128:
				continue
			if not world._loot_geometry.line_clear(point, origin, world.groups):
				continue
			if not _give(item, player, 6 if world.level.get_meta("battle_mode", false) else 9):
				continue
			item.count -= 1
			world.audio_requested.emit(
				AudioRequests.sample(0x21272 if item.kind == 43 else (0x21c9a if item.kind >= 40 else 0x17c8c), player.motion, player.player_ref())
			)
			if item.kind != 43:
				world.audio_requested.emit(AudioRequests.sample(0x2547e, player.motion, player.player_ref()))
			if item.count == 0:
				break
	world.loot_state.items = world.loot_state.items.filter(func(item): return item.count > 0)


static func _give(item: Dictionary, player: RefCounted, capacity: int = 9) -> bool:
	if item.kind == 43:
		if int(player.fighter.health) >= 128: return false
		player.fighter.health = mini(128, int(player.fighter.health) + 32)
		return true
	if item.kind >= 40:
		for index: int in range(player.keys.size()):
			if int(player.keys[index].kind) == 0:
				player.keys[index] = {"kind": int(item.kind) - 39, "timer": 35}
				return true
		return false  # Unlike the source delete-on-full quirk, preserve a dropped key.
	for index: int in range(capacity):
		if int(player.weapon_state.inventory[index].kind) != 0:
			continue
		@warning_ignore("integer_division")
		var ammo := int(item.ammo) / int(item.count)
		player.weapon_state.inventory[index] = {"kind": int(item.kind) - 28,
			"ammo": ammo, "extra": 35}
		item.ammo -= ammo
		preload("res://scripts/simulation/cd_weapon_rules.gd").select_automatic(player.weapon_state)
		player.fighter = preload("res://scripts/simulation/cd_status_overlay.gd").pickup(
			player.fighter, player.weapon_state, true)
		return true
	return false


static func valid(value: Variant, definition: RefCounted) -> bool:
	if not value is Dictionary or value.size() != 3 or not value.has_all(["next_id", "items", "departures"]):
		return false
	if not value.next_id is int or value.next_id < 1 or value.next_id > 0x7fffffffffffffff:
		return false
	if not value.items is Array or value.items.size() > MAX_ITEMS:
		return false
	if not value.departures is Array or value.departures.size() > 16:
		return false
	var seen := {}
	var bounds := _bounds(definition)
	for item: Variant in value.items:
		var fields := ["id", "kind", "ammo", "count", "x", "y", "z", "vx", "vy", "vz", "age", "anchor_x", "anchor_y"]
		if definition.level.get_meta("battle_mode", false) and (not item is Dictionary or not item.has("expires_at")):
			return false
		if item is Dictionary and item.has("expires_at"):
			fields.append("expires_at")
			if not definition.level.get_meta("battle_mode", false) or not item.expires_at is int or item.expires_at < 0 or item.expires_at > (1 << 48): return false
		if not item is Dictionary or item.size() != fields.size() or not item.has_all(fields):
			return false
		for field: String in ["id", "kind", "ammo", "count"]:
			if not item[field] is int:
				return false
		if not _identity(item.id, value.next_id, seen):
			return false
		if not item.kind in range(29, 39) and not item.kind in range(40, 44):
			return false
		if item.kind == 43 and not definition.level.get_meta("battle_mode", false): return false
		if item.count < 1 or item.count > 0x7fffffff or item.ammo < 0 or item.ammo > FULL_AMMO * item.count:
			return false
		if item.kind >= 40 and item.ammo != 0:
			return false
		if frame_for_kind(definition.catalog, item.kind) == 0:
			return false
		for field: String in ["x", "y", "anchor_x", "anchor_y"]:
			if not _number(item[field], -32768.0, 32767.0):
				return false
		if not bounds.has_point(Vector2(item.x, item.y)) or not bounds.has_point(Vector2(item.anchor_x, item.anchor_y)):
			return false
		for field: String in ["vx", "vy", "vz"]:
			if not _number(item[field], -1000.0, 1000.0):
				return false
		if not _number(item.z, 0.0, 256.0) or not _number(item.age, 0.0, 1.0e12):
			return false
	for row: Variant in value.departures:
		if not row is Dictionary or row.size() != (6 if row.has("player_colour") else 5) or not row.has_all(["id", "x", "y", "frame", "age"]):
			return false
		if row.has("player_colour") and (not row.player_colour is int or row.player_colour < 0 or row.player_colour > 3):
			return false
		if not _identity(row.id, value.next_id, seen):
			return false
		if not row.frame is int or not definition.catalog.frames.has(row.frame):
			return false
		if not _number(row.x, -32768.0, 32767.0) or not _number(row.y, -32768.0, 32767.0):
			return false
		if not _number(row.age, 0.0, DEPARTURE_SECONDS):
			return false
	return true


static func _identity(value: Variant, next_id: int, seen: Dictionary) -> bool:
	if not value is int or value < 1 or value >= next_id or seen.has(value):
		return false
	seen[value] = true
	return true


static func _number(value: Variant, low: float, high: float) -> bool:
	return value is float and is_finite(value) and value >= low and value <= high


static func _bounds(definition: RefCounted) -> Rect2:
	# Immutable content memoization, separate from per-world door/collision state.
	if definition.has_meta("native_drop_bounds"):
		return definition.get_meta("native_drop_bounds")
	var result := Rect2(Vector2(definition.level.walls[0].start), Vector2.ZERO)
	for wall: Dictionary in definition.level.walls:
		result = result.expand(Vector2(wall.start)).expand(Vector2(wall.finish))
	definition.set_meta("native_drop_bounds", result)
	return result
