class_name CdInteractionRules
extends RefCounted
## Door-use selection, key consumption and interlocks, sub-CPU $0367EC.
const Doors = preload("res://scripts/simulation/cd_door_rules.gd")


static func request(
	state: Dictionary,
	player: Dictionary,
	level: Resource,
	tables: Resource,
	first_wall: int,
	last_wall: int,
	visibility: Callable = Callable()
) -> Dictionary:
	var result: Dictionary = state.duplicate(true)
	var events: Array[Dictionary] = []
	var response := {"state": result, "events": events}
	# Use is latched on sampling, but activation waits for the A button to
	# be released. A request is consumed even when no usable door is found.
	if int(result.use_latch) == 0 or (int(player.held) & 64) == 0:
		return response
	result.use_latch = 0
	assert(first_wall >= 0 and last_wall >= first_wall and last_wall < level.walls.size())
	var best_score := 0x7000
	var selected := -1
	for index: int in range(first_wall, last_wall + 1):
		var wall: Dictionary = level.walls[index]
		if int(wall.motion_kind) < 1 or int(wall.motion_kind) > 5:
			continue
		var group: Dictionary = result.doors[int(wall.motion_group)]
		if int(group.state) != Doors.State.CLOSED and int(group.state) != Doors.State.CLOSING:
			continue
		if visibility.is_valid() and not visibility.call(index):
			continue
		for endpoint: Vector2i in [wall.start, wall.finish]:
			var phase := int(player.view_angle) & 255
			response.query_remainder = (
				_word(
					(
						(
							_word(endpoint.x - int(player.x)) * int(tables.sine[phase])
							+ _word(endpoint.y - int(player.y)) * int(tables.cosine[phase])
						)
						<< 2
					)
				)
				<< 16
			)
			var score := _endpoint_score(endpoint, player, tables)
			# Source comparisons are signed words, and ties choose the later
			# endpoint/wall. A negative overflowed score is therefore retained.
			if score != 0x7fffffff and score <= best_score:
				best_score = score
				selected = index
	if selected < 0 or best_score > 700:
		return response
	var selected_wall: Dictionary = level.walls[selected]
	var required_key := int(selected_wall.motion_kind) - 2
	if required_key >= 1:
		var slot := -1
		for index: int in range(result.keys.size() - 1, -1, -1):
			if int(result.keys[index].kind) == required_key:
				slot = index
				break
		if slot < 0:
			events.append({"kind": "key_missing", "key": required_key})
			return response
		result.keys[slot].kind = 0
		result.keys[slot].timer = 35
		events.append({"kind": "key_consumed", "key": required_key, "slot": slot})
	var group_index := int(selected_wall.motion_group)
	if (
		int(result.doors[group_index].kind) == 2
		and not Doors.close_other_interlocks(result.doors, group_index)
	):
		events.append({"kind": "interlock_busy", "group": group_index})
		return response
	result.doors[group_index].state = Doors.State.OPENING
	result.doors[group_index].timer = 0
	# Presentation consumes these semantic events; audio remains stubbed.
	# This pure rule has no dependency on a viewport, renderer or sound node.
	events.append({"kind": "door_opening", "group": group_index})
	return response


static func _endpoint_score(endpoint: Vector2i, player: Dictionary, tables: Resource) -> int:
	var dx := _word(endpoint.x - int(player.x))
	var dy := _word(endpoint.y - int(player.y))
	var phase := int(player.view_angle) & 255
	var sine: int = tables.sine[phase]
	var cosine: int = tables.cosine[phase]
	var lateral := _word(((dx * sine + dy * cosine) << 2) >> 16)
	var depth := _word(((dy * sine - dx * cosine) << 1) >> 16)
	if depth <= 0:
		return 0x7fffffff
	return _word(_word(absi(lateral)) + depth)


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
