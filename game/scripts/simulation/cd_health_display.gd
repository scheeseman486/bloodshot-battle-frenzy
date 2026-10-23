class_name CdHealthDisplay
extends RefCounted
## CD $00C438..$00C4D4. Health display and warning share the original input clock.
## Native drawing only reads these fields; it never advances timers or audio.
const ALARM_SAMPLE := 0x24d64


static func advance(player: Dictionary) -> Dictionary:
	var result := {"state": player.duplicate(true), "audio": [], "redraw": false}
	var state: Dictionary = result.state
	var reload_warning := false
	if int(state.health_alarm_timer) != 0:
		state.health_alarm_timer = _word(int(state.health_alarm_timer) - 1)
		if int(state.health_alarm_timer) == 0:
			state.health_alarm_on = _word(~int(state.health_alarm_on))
			if int(state.state) != 2:
				# $C6BA ignores negative requests. An off phase is not a request
				# to stop voices, CD music, or another player's warning.
				result.audio.append(ALARM_SAMPLE if int(state.health_alarm_on) != 0 else -1)
			reload_warning = int(state.health_alarm_on) == 0 or int(state.health_copy) <= 45
	elif int(state.health_copy) <= 45:
		reload_warning = true
	if reload_warning:
		state.health_alarm_timer = _word((int(state.health_copy) >> 1) + 10)
		result.redraw = true
		return result
	if int(state.health_hit_timer) != 0:
		state.health_hit_timer = _word(int(state.health_hit_timer) - 1)
		if int(state.health_hit_timer) == 0:
			result.redraw = true
			return result
	if int(state.health_copy) < int(state.health):
		state.health_copy = _word(int(state.health_copy) + 1)
		result.redraw = true
	return result


static func highlighted(player: Dictionary) -> bool:
	return (
		int(player.health_hit_timer) != 0
		or (int(player.health_alarm_timer) != 0 and int(player.health_alarm_on) != 0)
	)


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
