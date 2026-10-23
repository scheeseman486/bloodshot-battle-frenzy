class_name CdBossOrbit
extends RefCounted


## Satellite position $02FCB2..$02FD0C and shared oscillator $031F72..$031FFA.
static func position(
	phase: int, clock: int, radius: int, centre: Vector2i, tables: Resource
) -> Dictionary:
	var angle := _word((clock >> 5) + phase)
	if angle >= 256:
		angle = _word(angle - 256)
	assert(angle >= 0 and angle < 256)
	return {
		"x": _word(centre.x + ((int(tables.sine[angle]) * radius) >> 16)),
		"y": _word(centre.y + ((int(tables.cosine[angle]) * radius) >> 16))
	}


static func advance(
	state: Dictionary, elapsed: int, remaining: int, theme: Dictionary
) -> Dictionary:
	var result := state.duplicate(true)
	if remaining != 0:
		return result
	result.clock = _word(int(result.clock) + int(theme.angular_speed) * elapsed)
	if int(result.clock) >= 8192:
		result.clock = _word(int(result.clock) - 8192)
	result.radius = _word(int(result.radius) + int(result.speed) * elapsed)
	if int(result.speed) >= 0:
		if int(result.radius) >= int(theme.maximum_radius):
			result.radius = int(theme.maximum_radius)
			result.speed = _word(-int(result.speed))
	elif int(result.radius) <= int(theme.minimum_radius):
		result.radius = int(theme.minimum_radius)
		result.speed = _word(-int(result.speed))
	return result


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
