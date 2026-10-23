class_name CdDoorRules
extends RefCounted
## Shared moving-wall groups, sub-CPU $036A7C..$036B3E.

enum State { CLOSED, OPENING, OPEN, CLOSING }
const OPEN_STEP := 165
const CLOSE_STEP := 400

static func advance(groups: Array, elapsed: int, blocked: Array = []) -> Array:
	var result := groups.duplicate(true)
	for index: int in range(result.size()):
		var group: Dictionary = result[index]
		var previous_state := int(group.state)
		if previous_state == State.OPENING:
			group.fraction = mini(int(group.fraction) + OPEN_STEP, 4096)
			if int(group.fraction) == 4096:
				group.state = State.OPEN
		if int(group.kind) == 1 and previous_state == State.OPEN:
			group.timer = int(group.timer) + elapsed
			if int(group.timer) >= 180:
				group.state = State.CLOSING
		if previous_state == State.CLOSING:
			if not blocked.has(index):
				group.fraction = maxi(int(group.fraction) - CLOSE_STEP, 0)
				if int(group.fraction) == 0:
					group.state = State.CLOSED
			elif int(group.kind) == 2:
				close_other_interlocks(result, index)
	return result


static func close_other_interlocks(groups: Array, selected: int) -> bool:
	# $036A2A mutates groups in source order and can return before visiting
	# later groups. Do not replace this with an unordered all-or-nothing check.
	for index: int in range(groups.size()):
		if index == selected or int(groups[index].kind) != 2:
			continue
		var state := int(groups[index].state)
		if state == State.OPENING or state == State.CLOSING:
			return false
		if state != State.CLOSED:
			groups[index].state = State.CLOSING
	return true
