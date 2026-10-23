class_name CdProjectileMotionPath
extends RefCounted
## Visual flight from committed velocity/gravity and source wall rules. It never
## calls live hit callbacks, advances animation, or creates an impact/explosion.
const Flight = preload("res://scripts/simulation/cd_projectile_flight.gd")


static func build(
	actor: Dictionary, elapsed: int, level: Resource, fractions: Array, catalog: Resource
) -> Dictionary:
	var duration := mini(elapsed, 6)
	if duration <= 0:
		return {}
	var flight := Flight.advance(actor, elapsed, level, fractions, [], [], _ignore_hit, catalog)
	var endpoint: Dictionary = flight.state
	var displacement := Vector3.ZERO
	var limit := 1.0
	if int(endpoint.kind) == int(actor.kind):
		# Includes source bounce direction and signed integer endpoint rounding.
		displacement = Vector3(
			float(endpoint.x) - float(actor.x),
			float(endpoint.y) - float(actor.y),
			float(endpoint.height) - float(actor.height)
		)
	else:
		# A terminal source step still has known travel. Keep its artwork alive
		# until the real event, approaching contact instead of freezing at birth.
		displacement = Vector3(_word(int(actor.vx) * duration), _word(int(actor.vy) * duration), 0)
		if int(actor.kind) == 27:
			var fall := float(_word(int(actor.gravity) * duration))
			displacement.z = fall
			if fall > 0.0:
				limit = minf(limit, maxf(0.0, (128.0 - float(actor.height)) / fall))
		if int(flight.wall) >= 0:
			limit = minf(
				limit, _contact_limit(actor, displacement, level.walls[int(flight.wall)], fractions)
			)
	if int(actor.kind) == 27 and int(endpoint.kind) == int(actor.kind):
		displacement.z = float(_word(int(actor.gravity) * duration))
	if absf(displacement.x) > 32768.0 or absf(displacement.y) > 32768.0:
		return {}  # Never draw a map-spanning line across signed-word wrapping.
	return {"velocity": displacement / float(elapsed), "duration": float(elapsed), "limit": limit}


static func sample(actor: Dictionary, path: Dictionary, phase: float) -> void:
	var elapsed := minf(clampf(phase, 0.0, 1.0), float(path.limit)) * float(path.duration)
	var velocity: Vector3 = path.velocity
	actor.x = float(actor.x) + velocity.x * elapsed
	actor.y = float(actor.y) + velocity.y * elapsed
	actor.height = clampf(float(actor.height) + velocity.z * elapsed, -128.0, 128.0)


static func _contact_limit(
	actor: Dictionary, displacement: Vector3, wall: Dictionary, fractions: Array
) -> float:
	var offset := Vector2i.ZERO
	if int(wall.motion_kind) != 0:
		var fraction := int(fractions[int(wall.motion_group)])
		var delta: Vector2i = wall.motion_delta
		offset = Vector2i((delta.x * fraction) >> 12, (delta.y * fraction) >> 12)
	var start := Vector2(float(actor.x), float(actor.y))
	var movement := Vector2(displacement.x, displacement.y)
	var contact: Variant = Geometry2D.segment_intersects_segment(
		start, start + movement, Vector2(wall.start + offset), Vector2(wall.finish + offset)
	)
	if contact != null and movement.length_squared() > 0.0:
		return clampf(
			(Vector2(contact) - start).dot(movement) / movement.length_squared(), 0.0, 1.0
		)
	# Original collision can signal a wall beyond this endpoint (midpoint/ahead
	# rules). Draw only this interval's travel; never invent a later impact event.
	return 1.0


static func _ignore_hit(_target: int) -> bool:
	return true


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
