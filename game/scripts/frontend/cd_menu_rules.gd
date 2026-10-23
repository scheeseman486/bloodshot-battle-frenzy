class_name CdMenuRules
extends RefCounted
## European CD menu input dispatcher $0321F6..$0323B2. State is independent
## of scenes, artwork, input devices, render rate and native preferences.


static func advance(state: Dictionary) -> Dictionary:
	var result := state.duplicate(true)
	if int(result.stage) == 0 or not bool(result.ready):
		return result
	if int(result.stage) == 2:
		if int(result.selected) == 0:
			result.selected = 1
		result.stage = 1
	var edge := int(result.edge)
	if (edge & 1) == 0 and int(result.selected) > 1:
		result.selected -= 1
		return result
	if (edge & 2) == 0 and int(result.selected) < int(result.rows):
		result.selected += 1
		return result
	if int(result.selected) < 1 or int(result.selected) > result.items.size():
		return result
	var item: Dictionary = result.items[int(result.selected) - 1]
	if int(item.choices) != 0:
		if (edge & 4) == 0:
			_change(result, item, -1)
		if (edge & 8) == 0:
			_change(result, item, 1)
	if (edge & 0x70) != 0x70:
		if int(item.choices) != 0:
			_change(result, item, 1)
		else:
			result.chosen = result.selected
	return result


static func _change(state: Dictionary, item: Dictionary, direction: int) -> void:
	item.value = posmod(int(item.value) - 1 + direction, int(item.choices)) + 1
	var fields := {0x55aaa: "diagonals", 0x55aa8: "sound", 0x55ab0: "language"}
	if fields.has(int(item.address)):
		state[fields[int(item.address)]] = item.value
	state.stage = 2


static func sound_index(index: int, edge: int, count: int) -> int:
	if count <= 0:
		return -1
	if (edge & 4) == 0:
		index = posmod(index - 1, count)
	if (edge & 8) == 0:
		index = posmod(index + 1, count)
	return index
