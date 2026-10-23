extends RefCounted
## Trusted read-only adapter. Controllers receive observations, never this world.
const RANGE := 18.0 * 256.0


static func visible(nav: RefCounted, groups: Array, pose: Dictionary, point: Vector2i) -> bool:
	var delta := Vector2(point) - Vector2(pose.x, pose.y)
	if delta.length_squared() > RANGE * RANGE:
		return false
	var heading := Vector2(
		sin(float(pose.angle) * TAU / 16384.0), cos(float(pose.angle) * TAU / 16384.0)
	)
	if delta.length_squared() > 0 and heading.dot(delta.normalized()) < 0.5:
		return false
	return nav.geometry.line_clear(Vector2(pose.x, pose.y), Vector2(point), groups)


static func observe(world: RefCounted, player: RefCounted, nav: RefCounted) -> Dictionary:
	var versus: bool = not world.vs_state.is_empty()
	var here := Vector2i(player.motion.x, player.motion.y)
	var result := {
		"seat": player.seat,
		"position": here,
		"angle": int(player.motion.angle),
		"health": int(player.fighter.health),
		"selected": int(player.weapon_state.selected),
		"inventory": player.weapon_state.inventory.duplicate(true),
		"targets": [],
		"friends": [],
		"items": [],
		"hazards": [],
		"projectiles": [],
		"escape": false,
		"exit": here
	}
	if versus:
		for other: RefCounted in world.players:
			if other == player or int(other.fighter.state) != 1:
				continue
			var point := Vector2i(other.motion.x, other.motion.y)
			if visible(nav, world.groups, player.motion, point):
				result.targets.append(
					{"id": other.id, "generation": other.generation, "point": point}
				)
	else:
		# Cooperative team-position knowledge is allowed for following, never enemy tracking.
		for other: RefCounted in world.players:
			if not world.bots.is_bot(other.player_ref()) and int(other.fighter.state) in [1, 3]:
				result.friends.append(
					{
						"seat": other.seat,
						"angle": int(other.motion.angle),
						"point": Vector2i(other.motion.x, other.motion.y),
						"escaped": int(other.fighter.state) == 3
					}
				)
		result.escape = int(world.actor_system.encounter.countdown) > 0
		# Only a witnessed exit/human arrival supplies the return coordinate.
		if result.friends.any(func(friend): return friend.escaped):
			result.exit = Vector2i(
				result.friends.filter(func(friend): return friend.escaped)[0].point
			)
		elif visible(nav, world.groups, player.motion, world.level.spawn):
			result.exit = world.level.spawn
	for slot: int in range(world.actor_system.actors.size()):
		var actor: Dictionary = world.actor_system.actors[slot]
		var kind := int(actor.kind)
		var enemy: bool = (
			not versus
			and kind in range(1, 20)
			and kind not in [4, 15, 17, 19]
			and int(actor.health) > 0
		)
		if (
			not enemy
			and kind != 46
			and kind not in range(24, 29)
			and not (versus and (kind in range(29, 39) or kind == 43))
		):
			continue
		var point := Vector2i(actor.x, actor.y)
		if not visible(nav, world.groups, player.motion, point):
			continue
		if enemy:
			result.targets.append(
				{
					"id": slot,
					"generation": int(world.actor_system.entity_generations[slot]),
					"point": point
				}
			)
		elif kind == 46:
			result.hazards.append(point)
		elif kind in range(24, 29):
			result.projectiles.append(point)
		elif versus and (kind in range(29, 39) or kind == 43):
			result.items.append({"id": slot, "point": point, "kind": kind, "present": true})
	if versus:
		# Original map placements are static knowledge. Observe an empty location
		# only when it is in sight; never consult private renewal deadlines.
		for slot: int in range(world.definition.catalog.actors.size()):
			var original: Dictionary = world.definition.catalog.actors[slot]
			if int(original.kind) not in range(29, 39):
				continue
			var point := Vector2i(original.x, original.y)
			if (
				visible(nav, world.groups, player.motion, point)
				and not result.items.any(func(item): return item.id == slot)
			):
				result.items.append(
					{"id": slot, "point": point, "kind": int(original.kind), "present": false}
				)
		for drop: Dictionary in world.loot_state.get("items", []):
			var point := Vector2i(drop.x, drop.y)
			if visible(nav, world.groups, player.motion, point):
				result.items.append(
					{"id": -int(drop.id), "point": point, "kind": int(drop.kind), "present": true}
				)
	return result
