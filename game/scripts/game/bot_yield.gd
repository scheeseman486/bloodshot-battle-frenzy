extends RefCounted
## Native cooperative contact courtesy. Pure bounded pressure propagation over
## at most four living teammates; no positions, impulses or human controls change.
const CONTACT := 150.0
const STEP := 180.0


static func solve(participants: Array, clear: Callable) -> Dictionary:
	var pressure := {}
	var queue := []
	for human: Dictionary in participants:
		if human.bot or Vector2(human.intent).is_zero_approx(): continue
		var direction: Vector2 = Vector2(human.intent).normalized()
		for bot: Dictionary in participants:
			if not bot.bot or not _ahead(human.point, bot.point, direction, clear): continue
			if not pressure.has(bot.id): queue.append(bot)
			pressure[bot.id] = direction
	var result := {}
	while not queue.is_empty():
		var bot: Dictionary = queue.pop_front()
		if result.has(bot.id): continue
		var direction: Vector2 = pressure[bot.id]
		var chosen := Vector2.ZERO
		# Stable handedness avoids alternating left/right at a blocked doorway.
		var side := 1.0 if int(bot.id)%2==0 else -1.0
		for angle: float in [0.0, side*PI/4.0, -side*PI/4.0, side*PI/2.0, -side*PI/2.0]:
			var candidate := direction.rotated(angle)
			var destination: Vector2 = Vector2(bot.point)+candidate*STEP
			if not clear.call(Vector2(bot.point), destination): continue
			var human_blocked := false
			for human: Dictionary in participants:
				if human.bot: continue
				var delta: Vector2 = Vector2(human.point)-Vector2(bot.point)
				var nearest := Geometry2D.get_closest_point_to_segment(
					Vector2(human.point), Vector2(bot.point), destination
				)
				if delta.dot(candidate) > 0 and nearest.distance_to(Vector2(human.point)) < 105:
					human_blocked = true
			if not human_blocked:
				chosen = candidate
				break
		result[bot.id] = chosen
		if chosen.is_zero_approx(): continue
		for other: Dictionary in participants:
			if not other.bot or other.id==bot.id or result.has(other.id): continue
			if _ahead(bot.point, other.point, chosen, clear):
				if not pressure.has(other.id): queue.append(other)
				pressure[other.id] = chosen
	return result


static func _ahead(origin: Vector2, point: Vector2, direction: Vector2, clear: Callable) -> bool:
	var delta := point-origin
	return (
		delta.length_squared() <= CONTACT * CONTACT
		and (delta.is_zero_approx() or delta.normalized().dot(direction) > 0.2)
		and clear.call(origin, point)
	)


static func controls(direction: Vector2, angle: int) -> Dictionary:
	var heading := float(angle)*TAU/16384.0
	var forward := Vector2(sin(heading),cos(heading))
	var along := direction.dot(forward)
	var lateral := direction.dot(Vector2(forward.y,-forward.x))
	var held := 0xffffffff
	if along>0.25: held &= ~1
	elif along< -0.25: held &= ~2
	return {"held":held,"strafe":int(signf(lateral)) if absf(lateral)>0.25 else 0}
