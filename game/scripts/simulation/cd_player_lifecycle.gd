class_name CdPlayerLifecycle
extends RefCounted
## Player death $0373E2, timer $035CFA and reinitialization $036C80.


static func die(player: Dictionary) -> Dictionary:
	var result := player.duplicate(true)
	result.state = 2
	result.death_timer = 20
	result.grace = -1
	if result.has("lives_previous"):
		result.lives_previous = result.lives
	if result.has("lives_timer"):
		result.lives_timer = 35
	result.lives = _word(int(result.lives) - 1)
	if int(result.lives) == 0:
		result.lives = -1
		result.death_timer = 150
	if result.has("proxy"):
		result.proxy = -1
	if result.has("flash_cursor"):
		result.flash_cursor = 0x3778a
		result.flash_callback = 0
	return result


static func respawn(player: Dictionary, countdown: int) -> Dictionary:
	var result := player.duplicate(true)
	result.health = 128
	result.health_copy = 128
	# A death during the core countdown revives in place. Ordinary deaths use
	# the retained combat checkpoint; neither case rebuilds the level/world.
	if int(player.state) != 2 or countdown == 0:
		result.x = player.checkpoint_x
		result.y = player.checkpoint_y
		result.angle = player.checkpoint_angle
		result.prev_x = player.checkpoint_x
		result.prev_y = player.checkpoint_y
	for field: String in [
		"use_latch",
		"use_duration",
		"strafe_mode",
		"since_hit",
		"forward",
		"turn",
		"strafe",
		"impulse_x",
		"impulse_y"
	]:
		result[field] = 0
	result.weapons.timer = 0
	result.weapons.buffered = 0
	result.weapons.special = -1
	if result.weapons.has("state"):
		result.weapons.state = 1
	result.map_timer = 150
	result.wall_cursor = 0
	result.grace = 20
	result.state = 1
	return result


static func advance(player: Dictionary, elapsed: int, countdown: int) -> Dictionary:
	var result := {"state": player.duplicate(true), "respawned": false, "removed": false}
	var grace := int(player.grace)
	if grace != 0:
		result.state.grace = _word(grace - elapsed) if grace > elapsed else 0
	if int(player.state) != 2:
		return result
	# The source BGT after SUB.W uses signed overflow flags. Compare operands
	# before wrapping, so a negative timer cannot wrap into a long new delay.
	var delay := int(player.death_timer)
	if delay > elapsed:
		result.state.death_timer = _word(delay - elapsed)
		return result
	result.state.death_timer = 0
	if int(player.lives) > 0:
		result.state = respawn(result.state, countdown)
		result.respawned = true
	else:
		result.state.state = 0
		result.removed = true
	return result


static func finish(mode: int, states: Array) -> int:
	if mode == 2 and not states.any(func(state: Variant) -> bool: return int(state) != 0):
		return 0
	return mode


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
