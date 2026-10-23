class_name CdPlayerFlash
extends RefCounted
## Original PAL-clock hit/death palette script, $035F2E..$036032.


static func advance(player: Dictionary, entries: Dictionary, busy: bool = false) -> Dictionary:
	var result := {"state": player.duplicate(true), "writes": []}
	var state: Dictionary = result.state
	var cursor := int(state.get("flash_cursor", 0))
	if cursor == 0:
		return result
	if int(state.flash_active) == 0:
		if busy:
			return result
	else:
		state.flash_hold = ((int(state.flash_hold) - 1 + 32768) & 65535) - 32768
		if int(state.flash_hold) != 0:
			return result
	assert(entries.has(cursor), "Unknown original player palette-script cursor")
	var entry: Dictionary = entries[cursor]
	var duration := int(entry.duration)
	if duration == 0:
		state.flash_cursor = 0
		state.flash_busy = 0
		# A final-life death holds the last (black) frame until removal. Ordinary
		# revival restores the view once both the script and death delay finish.
		if int(state.lives) != 0 and int(state.death_timer) == 0:
			state.flash_active = 0
		return result
	state.flash_hold = duration
	state.flash_cursor = cursor + 4
	state.flash_active = 1
	state.flash_busy = 1
	result.writes.append(int(entry.word))
	return result


static func hit(player: Dictionary) -> Dictionary:
	var result := player.duplicate(true)
	if result.has("flash_cursor"):
		result.flash_cursor = 0x37784
		result.flash_callback = 0
	return result
