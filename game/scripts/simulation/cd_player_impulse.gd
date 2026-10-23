class_name CdPlayerImpulse
extends RefCounted


## Player knockback and decay, sub-CPU $03649A..$036594.
static func advance(state: Dictionary, elapsed: int, query: Callable) -> Dictionary:
	var result := state.duplicate(true)
	if int(result.impulse_x) == 0 and int(result.impulse_y) == 0:
		return result
	var target := Vector2i(
		_word(int(result.x) + clampi(_word(int(result.impulse_x) * elapsed), -80, 80)),
		_word(int(result.y) + clampi(_word(int(result.impulse_y) * elapsed), -80, 80))
	)
	var contact: Dictionary = query.call(target)
	if contact.blocked:
		contact = query.call(contact.target)
	if (
		not contact.blocked
		and absi(_word(int(result.x) - int(contact.target.x))) <= 80
		and absi(_word(int(result.y) - int(contact.target.y))) <= 80
	):
		result.x = int(contact.target.x)
		result.y = int(contact.target.y)
	var decay := _word(2 * elapsed)
	for field: String in ["impulse_x", "impulse_y"]:
		var value := int(result[field])
		result[field] = (
			mini(0, _word(value + decay)) if value < 0 else maxi(0, _word(value - decay))
		)
	return result


## Native safety policy: sweep small steps and retain tangential wall motion.
## Every projected/axis-slide path is checked, never just its destination.
## Reference execution continues to use advance() above. Optional path vertices
## belong to the caller's presentation copy, never authoritative state.
static func advance_native(state: Dictionary, elapsed: int, query: Callable, path: Array = []) -> Dictionary:
	var result := advance(state, elapsed, func(point: Vector2i) -> Dictionary:
		return {"target": point, "blocked": false}
	)
	var origin := Vector2i(state.x, state.y)
	var target := Vector2i(result.x, result.y)
	path.clear()
	path.append(origin)
	if int(state.impulse_x) == 0 and int(state.impulse_y) == 0:
		return result
	# Word wrap is not a traversable path across the native map.
	if absi(target.x - origin.x) > 80 or absi(target.y - origin.y) > 80:
		result.x = origin.x
		result.y = origin.y
		return result
	# Six before integer rounding keeps each displacement below eight units.
	var steps := maxi(1, ceili(Vector2(target - origin).length() / 6.0))
	var accepted := origin
	var previous_ideal := origin
	var slid := false
	for index: int in range(1, steps + 1):
		var ideal := Vector2i(Vector2(origin).lerp(Vector2(target), float(index) / steps).round())
		var delta := ideal - previous_ideal
		previous_ideal = ideal
		var point := accepted + delta
		var contact: Dictionary = query.call(point)
		if not contact.blocked and _clear_segment(accepted, point, query):
			accepted = point
		else:
			slid = true
			# Prefer the wall's projection (including diagonal walls). Reject
			# distant/opposing corrections and any path through another wall.
			var candidates := [Vector2i(contact.target), Vector2i(point.x, accepted.y), Vector2i(accepted.x, point.y)]
			for candidate: Vector2i in candidates:
				if absi(candidate.x - origin.x) > 80 or absi(candidate.y - origin.y) > 80:
					continue
				var travel := candidate - accepted
				if absi(travel.x) > 8 or absi(travel.y) > 8 or travel.x * delta.x + travel.y * delta.y < 0:
					continue
				if _clear_segment(accepted, candidate, query):
					accepted = candidate
					break
		path.append(accepted)
	if not slid:
		# Preserve exact fractional free flight, without integer-vertex wobble.
		path.clear()
		path.append(origin)
		path.append(target)
	result.x = accepted.x
	result.y = accepted.y
	return result


## Unit-spaced checks prevent both corner cutting and accepting a correction
## into a different pocket. Starting positions are retained, never depenetrated.
static func _clear_segment(origin: Vector2i, target: Vector2i, query: Callable) -> bool:
	if origin == target:
		return not query.call(target).blocked
	var count := maxi(1, ceili(Vector2(target - origin).length() * 2.0))
	var previous := origin
	for index: int in range(1, count + 1):
		var point := Vector2i(Vector2(origin).lerp(Vector2(target), float(index) / count).round())
		if point == previous:
			continue
		previous = point
		if query.call(point).blocked:
			return false
	return true


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
