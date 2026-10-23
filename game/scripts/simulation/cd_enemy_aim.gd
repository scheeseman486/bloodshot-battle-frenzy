class_name CdEnemyAim
extends RefCounted
## Attack request $02F2C4..$02F388. This computes aim/weapon selection only;
## projectile allocation/travel and hit effects are separate rules.
const RandomStream = preload("res://scripts/simulation/cd_enemy_random.gd")
const Chase = preload("res://scripts/simulation/cd_enemy_chase.gd")


static func request(
	actor: Dictionary,
	player: Dictionary,
	distance: int,
	random_state: int,
	params: Dictionary,
	catalog: Resource
) -> Dictionary:
	var spread := _word((distance * int(params.accuracy)) >> 8)
	var first := RandomStream.step(random_state)
	var dx := _word(int(player.x) - int(actor.x) + ((int(first.value) * spread) >> 7))
	var second := RandomStream.step(int(first.seed))
	var dy := _word(int(player.y) - int(actor.y) + ((int(second.value) * spread) >> 7))
	random_state = int(second.seed)
	var direction := Chase.normalize_direction(dx, dy, catalog)
	var weapon := int(params.weapon)
	if int(actor.kind) == 16:
		var third := RandomStream.step(random_state)
		random_state = int(third.seed)
		if int(third.value) & 1:
			weapon = 0x3a7aa
	return {
		"seed": random_state,
		"dx": direction.x,
		"dy": direction.y,
		"weapon": weapon,
		"height": params.height
	}


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
