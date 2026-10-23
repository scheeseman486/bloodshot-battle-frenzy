class_name CdCollisionWorld
extends RefCounted
## Pure integer collision queries from sub-CPU $036596..$0367C8.

var level: Resource
var fractions: Array = []
var axis_remainder: Variant = null


func query(target: Vector2i, cursor: int = 0, initial_radius: int = 100) -> Dictionary:
	assert(level != null and not level.walls.is_empty(), "A decoded original level is required")
	var walls: Array = level.walls
	cursor = clampi(cursor, 0, walls.size() - 1)
	var lower := _word(target.y - 356)
	# Retain the source search cursor and its precise equality rules. Wall order
	# matters at corners; do not replace it with Godot's floating-point physics.
	if lower > int(walls[cursor].start.y):
		# Original walls are ordered by start Y. Find exactly the first wall
		# the source forward scan would reach, retaining equality and end rules.
		# Repeated swept-hit queries otherwise walk most of the map each time.
		var high := walls.size() - 1
		while cursor < high:
			var middle := (cursor + high) >> 1
			if lower > int(walls[middle].start.y):
				cursor = middle + 1
			else:
				high = middle
	else:
		while cursor > 0:
			cursor -= 1
			if lower > int(walls[cursor].start.y):
				cursor += 1
				break
	var radius := initial_radius
	var index := cursor
	var retained_axis := int(axis_remainder) if axis_remainder != null else (target.y & ~65535)
	while index < walls.size():
		var wall: Dictionary = walls[index]
		if absi(_word(int(wall.start.x) - target.x)) <= 356:
			var start: Vector2i = wall.start
			var finish: Vector2i = wall.finish
			if (
				int(wall.motion_kind) != 0
				and int(wall.motion_group) < fractions.size()
				and int(fractions[int(wall.motion_group)]) != 0
			):
				var fraction := int(fractions[int(wall.motion_group)])
				var delta: Vector2i = wall.motion_delta
				# $036688/$03669A skip MULS when a delta word is zero.
				# MOVE.W retains D5's upper word: after a negative X offset,
				# a zero Y delta therefore becomes -16, not zero. This CD
				# collision quirk is captured at actor contact wall 14.
				var scratch := delta.x * fraction if delta.x != 0 else retained_axis
				scratch >>= 12
				var displacement := Vector2i(scratch, 0)
				scratch = delta.y * fraction if delta.y != 0 else (scratch & ~65535)
				displacement.y = scratch >> 12
				start += displacement
				finish += displacement
				start = Vector2i(_word(start.x), _word(start.y))
				finish = Vector2i(_word(finish.x), _word(finish.y))
			var dx := absi(_word(finish.x - start.x))
			var dy := absi(_word(finish.y - start.y))
			var diagonal := dx != 0 and dy != 0
			if diagonal:
				# $0366DC accumulates this for subsequent candidate walls too.
				radius += 20
			var swapped := dy < dx
			var candidate := target
			if swapped:
				start = Vector2i(start.y, start.x)
				finish = Vector2i(finish.y, finish.x)
				candidate = Vector2i(target.y, target.x)
			var minimum := mini(start.y, finish.y)
			var maximum := maxi(start.y, finish.y)
			if not diagonal:
				minimum = _word(minimum - 32)
				maximum = _word(maximum + 32)
			if minimum <= candidate.y and candidate.y <= maximum:
				var intercept := 0
				if start.x != finish.x:
					intercept = _divide(
						_word(candidate.y - start.y) * _word(finish.x - start.x),
						_word(finish.y - start.y)
					)
				var distance := _word(candidate.x - intercept - start.x)
				if distance > -radius and distance < radius:
					candidate.x = _word(intercept + start.x + (-radius if distance < 0 else radius))
					if swapped:
						candidate = Vector2i(candidate.y, candidate.x)
					return {"target": candidate, "blocked": true, "cursor": cursor}
			# $36770 restores saved coordinate words with sign extension after
			# each candidate; only the first tested wall sees the incoming fraction.
			retained_axis = target.y & ~65535
		index += 1
		if index < walls.size() and _word(int(walls[index].start.y) - target.y) >= 356:
			break
	return {"target": target, "blocked": false, "cursor": cursor}


static func _divide(numerator: int, denominator: int) -> int:
	# Godot integer division and 68000 DIVS both truncate towards zero.
	@warning_ignore("integer_division")
	return numerator / denominator


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
