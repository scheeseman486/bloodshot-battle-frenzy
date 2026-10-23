class_name CdProximityMine
extends RefCounted
## Mine flashing and ordered proximity checks, sub-CPU $039BCE..$039D10.
const ActorAnimation = preload("res://scripts/simulation/cd_actor_animation.gd")


static func advance(
	state: Dictionary, players: Array, active: Array, catalog: Resource
) -> Dictionary:
	var result := state.duplicate(true)
	var triggers: Array = []
	# This counter advances once per actor dispatch, not by elapsed time.
	result.mine_clock = _word(int(result.mine_clock) + 1)
	var limit := 20 if int(result.frame) == 0x53188 else 15
	if int(result.mine_clock) == limit:
		result.mine_clock = 0
		result.frame = 0x5319a if int(result.frame) == 0x53188 else 0x53188
	for index: int in range(players.size()):
		if int(players[index].state) != 0 and _inside(result, players[index]):
			triggers.append(-2 - index)
			result = _trigger(result, catalog)
	for enemy: Dictionary in active:
		if _inside(result, enemy):
			triggers.append(enemy.id)
			result = _trigger(result, catalog)
	return {"state": result, "triggers": triggers}


static func _trigger(state: Dictionary, catalog: Resource) -> Dictionary:
	state.kind = 48
	return ActorAnimation.select(state, 0x3044e, catalog).state


static func _inside(state: Dictionary, target: Dictionary) -> bool:
	return (
		_word(int(state.x) - 96) <= int(target.x)
		and int(target.x) <= _word(int(state.x) + 96)
		and _word(int(state.y) - 96) <= int(target.y)
		and int(target.y) <= _word(int(state.y) + 96)
	)


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
