class_name CdEnemyChase
extends RefCounted
## Campaign chase, sub-CPU $02F38A..$02F52C. World query and shared movement
## RNG are explicit; animation requests are returned in original call order.
const RandomStream = preload("res://scripts/simulation/cd_enemy_random.gd")


static func advance(
	state: Dictionary,
	params: Dictionary,
	player: Dictionary,
	distance: int,
	elapsed: int,
	random_state: int,
	catalog: Resource,
	query: Callable,
	query_remainder: Callable = Callable()
) -> Dictionary:
	var result := state.duplicate(true)
	var response := {"state": result, "seed": random_state, "animations": []}
	if distance < int(params.stand_distance):
		_rest(result, params, response.animations)
		return response
	if int(result.cooldown) != 0:
		# BPL tests the stored word sign, unlike the charge's SUB/BGT branch.
		result.cooldown = maxi(0, _word(int(result.cooldown) - elapsed))
		return response
	if int(result.charge) == 0:
		response.animations.append(params.walk)
		var aim := Vector2i(int(player.x), int(player.y))
		if int(params.spread) != 0:
			var spread := _word((distance * int(params.spread)) >> 8)
			var random := RandomStream.step(int(response.seed))
			aim.x = _word(aim.x + ((int(random.value) * spread) >> 7))
			random = RandomStream.step(int(random.seed))
			aim.y = _word(aim.y + ((int(random.value) * spread) >> 7))
			response.seed = random.seed
		result.aim_x = aim.x
		result.aim_y = aim.y
		result.charge = params.duration
	else:
		var previous := int(result.charge)
		result.charge = _word(previous - elapsed)
		if previous <= elapsed:
			result.charge = 0
			result.cooldown = params.rest
			response.animations.append(params.idle)
	var dx := _word(int(result.aim_x) - int(result.x))
	var dy := _word(int(result.aim_y) - int(result.y))
	if dx == 0 and dy == 0:
		return response
	var direction := normalize_direction(dx, dy, catalog)
	var speed := _word(int(params.speed) * elapsed)
	var target := Vector2i(
		_word(int(result.x) + clampi((direction.x * speed) >> 16, -80, 80)),
		_word(int(result.y) + clampi((direction.y * speed) >> 16, -80, 80))
	)
	if query_remainder.is_valid():
		query_remainder.call(_word(direction.y * speed) << 16)
	var contact: Dictionary = query.call(target)
	if contact.blocked:
		contact = query.call(contact.target)
	if contact.blocked:
		_rest(result, params, response.animations)
	else:
		result.x = int(contact.target.x)
		result.y = int(contact.target.y)
	return response


static func _rest(state: Dictionary, params: Dictionary, animations: Array) -> void:
	state.cooldown = maxi(50, int(params.rest))
	animations.append(params.idle)


static func normalize_direction(dx: int, dy: int, catalog: Resource) -> Vector2i:
	# $02F52E uses 257-entry original lookup tables, not floating point sqrt.
	var major := absi(dx)
	var minor := absi(dy)
	var swapped := minor >= major
	if swapped:
		var temporary := major
		major = minor
		minor = temporary
	if major == 0:
		return Vector2i.ZERO
	@warning_ignore("integer_division")
	var ratio := (minor * 256) / major
	assert(ratio >= 0 and ratio <= 256)
	var direction := Vector2i(int(catalog.normal_major[ratio]), int(catalog.normal_minor[ratio]))
	if swapped:
		direction = Vector2i(direction.y, direction.x)
	if dx < 0:
		direction.x = -direction.x
	if dy < 0:
		direction.y = -direction.y
	return direction


static func direction_remainder(dx: int, dy: int) -> int:
	# $2F57C..2F5A2 retains the ratio division's remainder in the minor Y
	# component. The swapped branch restores the major component's zero word.
	var major := absi(dx)
	var minor := absi(dy)
	return 0 if major == 0 or minor >= major else ((minor * 256) % major) << 16


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
