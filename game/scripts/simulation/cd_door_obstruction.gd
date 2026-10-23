class_name CdDoorObstruction
extends RefCounted
## Closing-door endpoint test, sub-CPU $0370FE..$037290.


static func blocked(
	level: Resource,
	group: int,
	fraction: int,
	first: int,
	last: int,
	blockers: Array,
	initial_remainder: int = 0
) -> bool:
	return bool(query(level, group, fraction, first, last, blockers, initial_remainder).blocked)


static func query(
	level: Resource,
	group: int,
	fraction: int,
	first: int,
	last: int,
	blockers: Array,
	initial_remainder: int = 0
) -> Dictionary:
	var scratch := initial_remainder
	for index: int in range(first, last + 1):
		var wall: Dictionary = level.walls[index]
		if int(wall.motion_kind) == 0 or int(wall.motion_group) != group:
			continue
		var delta: Vector2i = wall.motion_delta
		# $03712E/$037140 skip MULS for a zero delta, retaining the
		# previous offset's upper word. Carry it between matching walls too:
		# after a negative offset, a zero axis becomes -16 map units.
		scratch = delta.x * fraction if delta.x != 0 else (scratch & ~65535)
		scratch >>= 12
		var offset := Vector2i(scratch, 0)
		scratch = delta.y * fraction if delta.y != 0 else (scratch & ~65535)
		scratch >>= 12
		offset.y = scratch
		for endpoint: Vector2i in [wall.start + offset, wall.finish + offset]:
			for body: Dictionary in blockers:
				if (
					int(body.state) != 0
					and absi(_word(endpoint.x - int(body.x))) <= 104
					and absi(_word(endpoint.y - int(body.y))) < 104
				):
					return {"blocked": true, "remainder": scratch}
	return {"blocked": false, "remainder": scratch}


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
