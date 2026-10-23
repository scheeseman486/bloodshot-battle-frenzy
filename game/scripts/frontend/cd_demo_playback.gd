class_name CdDemoPlayback
extends RefCounted
## Pure CD attract stream and interruption rules; original records are runtime data.


static func input(state: Dictionary, records: Array, player: int) -> Dictionary:
	var result := state.duplicate(true)
	if int(result.remaining) != 0:
		result.remaining = (int(result.remaining) - 1) & 65535
		return result
	while int(result.cursor) < records.size():
		var record: Dictionary = records[int(result.cursor)]
		result.cursor += 1
		if (int(record.tag) >> 14) == player:
			result.held = int(record.first)
			result.edge = int(record.second)
			result.remaining = ((int(record.tag) & 0x3fff) - 1) & 65535
			return result
	# Verified streams terminate gameplay with a recorded Start edge. A bounded
	# fallback also prevents a truncated stream from reading outside CD data.
	result.held = 0xff7f
	result.edge = 0xff7f
	return result


static func action(state: Dictionary, kind: String, actor: int, target: int) -> Dictionary:
	var result := state.duplicate(true)
	if kind == "activate":
		result.target = target
		result.lost = 200
		result.active.append(actor)
	else:
		var index: int = result.active.find(actor)
		assert(index >= 0, "Original demo removal requires an active actor")
		result.active.remove_at(index)
		result.target = -1
	return result


static func interrupt(state: Dictionary) -> Dictionary:
	var result := {"mode": state.mode, "request": state.request}
	if (int(state.held) & 0x70) != 0x70:
		result.mode = 0
	elif (int(state.edge) & 0x80) == 0:
		result.mode = 0
		result.request = 0x55b90
	elif (int(state.other_edge) & 0x80) == 0:
		result.mode = 0
		result.request = 0x55d0a
	return result
