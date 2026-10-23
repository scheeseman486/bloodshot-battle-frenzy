class_name CdLevelProgression
extends RefCounted
## European CD input countdown $00C200, escape $035D68 and finish $031FFC.
## Rendering may read these states at any refresh rate without advancing time.
const ActorAnimation = preload("res://scripts/simulation/cd_actor_animation.gd")
const Lifecycle = preload("res://scripts/simulation/cd_player_lifecycle.gd")


static func tick(state: Dictionary, players: Array) -> Dictionary:
	var result := {
		"state": state.duplicate(true), "players": players.duplicate(true), "expired": false
	}
	if int(state.countdown) == 0:
		return result
	result.state.countdown = _word(int(state.countdown) - 1)
	var remaining := int(result.state.countdown)
	if remaining > _word(int(state.countdown_boundary) + 100):
		return result
	if _word(remaining + 1) % 50 != 49 or remaining > 50:
		return result
	# Expiry occurs at the original display boundary (normally 48), rather
	# than on reaching zero. Direct death leaves health_copy untouched.
	result.state.countdown = 0
	result.expired = true
	for index: int in range(result.players.size()):
		var player: Dictionary = result.players[index]
		if int(player.state) != 1:
			continue
		player = Lifecycle.die(player)
		player.health = 0
		if player.has("flash_cursor"):
			player.flash_cursor = 0x377b4
		result.players[index] = player
	return result


static func escape(player: Dictionary, countdown: int, spawn: Dictionary) -> Dictionary:
	var result := player.duplicate(true)
	if countdown == 0:
		return result
	var dx := _word(int(player.x) - int(spawn.x))
	var dy := _word(int(player.y) - int(spawn.y))
	dx = _word(-dx) if dx < 0 else dx
	dy = _word(-dy) if dy < 0 else dy
	if dx <= 500 and dy <= 500:
		result.state = 3
	return result


static func finish(state: Dictionary, players: Array, elapsed: int) -> Dictionary:
	var result := state.duplicate(true)
	if int(state.exit_delay) == 0:
		var active := 0
		var escaped := 0
		for player: Dictionary in players:
			active += 1 if int(player.state) != 0 else 0
			escaped += 1 if int(player.state) == 3 else 0
		if active > 0 and escaped >= active:
			result.exit_delay = 150
			result.countdown = 0
	elif int(state.exit_delay) != -2:
		result.exit_delay = _word(int(state.exit_delay) - elapsed)
		if int(result.exit_delay) <= 0:
			result.exit_delay = -1
			result.mode = 3
	return result


static func restore(actor: Dictionary, catalog: Resource) -> Dictionary:
	var result := actor.duplicate(true)
	if int(actor.kind) == 21:
		result.kind = 4
		result.health = catalog.parameters[0x2fe36].health
		result.seen = -1
		result.target = -1
		result = ActorAnimation.select(result, 0x3041a, catalog).state
	return result


static func displayed_seconds(state: Dictionary, player_state: int) -> int:
	if (
		int(state.countdown) == 0
		or int(state.countdown) > int(state.countdown_boundary)
		or player_state == 3
		or int(state.mode) != 2
	):
		return -1
	@warning_ignore("integer_division")
	return int(state.countdown) / 50


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
