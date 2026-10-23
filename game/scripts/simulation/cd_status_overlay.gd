class_name CdStatusOverlay
extends RefCounted
## Original CD message $C7D2, input timers $C4D4, map lifetime $35E04 and
## weapon notice helpers $3387E/$C9A0. Source IDs refer to runtime SHELL data.
const MINE := 0x339aa
const BONUS := 0x33afe
const GET_KEY := 0x33b1e


static func request(player: Dictionary, source_id: int, duration: int = 80) -> Dictionary:
	var result := player.duplicate(true)
	if result.has("message_timer"):
		result.message_id = source_id
		result.message_timer = _word(duration)
	return result


static func advance_input(player: Dictionary) -> Dictionary:
	var result := player.duplicate(true)
	if int(result.message_timer) != 0:
		result.message_timer = _word(int(result.message_timer) - 1)
	if int(result.map_timer) != 0 and int(result.panel_phase) != 0:
		result.panel_phase_timer = _word(int(result.panel_phase_timer) - 1)
		if int(result.panel_phase_timer) == 0:
			result.panel_phase_timer = 6
			result.panel_phase = _word(int(result.panel_phase) - 1)
	return result


static func advance_world(player: Dictionary, elapsed: int) -> Dictionary:
	var result := player.duplicate(true)
	if int(result.map_timer) != 0:
		# Original signed SUB.W/BGT clamps even when subtraction wraps a word.
		result.map_timer = (
			_word(int(result.map_timer) - elapsed) if int(result.map_timer) > elapsed else 0
		)
	return result


static func visible(player: Dictionary, flash: int, exit_delay: int) -> bool:
	return int(player.message_timer) != 0 and flash == 0 and exit_delay == 0


## Failed weapon insertion still resets the original map timer. Manual
## selection keeps its current weapon card without starting the pickup reveal.
static func pickup(player: Dictionary, weapons: Dictionary, collected: bool) -> Dictionary:
	var result := player.duplicate(true)
	if not result.has("panel_weapon"):
		return result
	result.map_timer = 150
	if collected:
		result = selection(result, weapons, 7 if int(weapons.manual) == 0 else -1, false)
	return result


static func selection(
	player: Dictionary, weapons: Dictionary, phase: int = 1, reset_map: bool = true
) -> Dictionary:
	var result := player.duplicate(true)
	if not result.has("panel_weapon"):
		return result
	var selected := int(weapons.selected)
	result.panel_weapon = int(weapons.inventory[selected].kind) - 1 if selected >= 0 else -1
	if reset_map:
		result.map_timer = 150
	if phase >= 0:
		result.panel_phase = phase
		result.panel_phase_timer = 6
	return result


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
