extends RefCounted
## Shared pure owning-player motor. Both authority and prediction use the exact
## native fixed-point movement, original integer wall queries and body contact.
## No world clock, AI, lifecycle, damage, inventory or RNG is owned here.
const Motion = preload("res://scripts/simulation/cd_responsive_motion.gd")
const Body = preload("res://scripts/simulation/cd_player_body_contact.gd")
var _collision: RefCounted
var _cursor := 0


func advance(
	motion: Dictionary,
	input: Dictionary,
	tables: Resource,
	period: int,
	collision: RefCounted,
	cursor: int,
	actors: Array,
	catalog: Resource,
	proxy: int,
	dynamic_start: int,
	body_slots: Variant = null
) -> Dictionary:
	_collision = collision
	_cursor = cursor
	var result := motion.duplicate()
	for field: String in ["forward", "turn", "strafe"]:
		result[field] = input[field]
	var before := Vector2i(int(result.x), int(result.y))
	result = Motion.advance(result, tables, period, _query)
	if int(result.state) == 1:
		if (
			body_slots == null
			and dynamic_start >= 0
			and ClassDB.class_exists("BloodshotPrimitiveCodec")
		):
			var native: Object = ClassDB.instantiate("BloodshotPrimitiveCodec")
			if native.has_method("select_integer_records"):
				body_slots = native.select_integer_records(
					actors, "kind", 1, 22, mini(dynamic_start, actors.size())
				)
		# Prediction caches the solid source slots per installed collision view.
		# Authority filters the current full pool natively, with a portable scan
		# fallback. Both paths retain source indices/order and the same resolver.
		for index: int in range(dynamic_start, actors.size()) if body_slots == null else body_slots:
			if index < dynamic_start:
				continue
			var actor: Dictionary = actors[index]
			if int(actor.kind) < 1 or int(actor.kind) > 22 or index == proxy:
				continue
			if absi(int(result.x) - int(actor.x)) > 105 or absi(int(result.y) - int(actor.y)) > 105:
				continue
			var body := result.duplicate()
			body.prev_x = before.x
			body.prev_y = before.y
			var resolved := Body.resolve(
				body,
				{"id": index, "kind": actor.kind, "x": actor.x, "y": actor.y},
				proxy,
				catalog,
				_query
			)
			for axis: String in ["x", "y"]:
				if int(result[axis]) != int(resolved[axis]):
					result[axis] = int(resolved[axis])
					result[axis + "_sub"] = 0
	return {"motion": result, "cursor": _cursor}


func _query(target: Vector2i) -> Dictionary:
	var result: Dictionary = _collision.query(target, _cursor)
	_cursor = int(result.cursor)
	return result
