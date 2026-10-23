class_name CdKeyPickup
extends RefCounted


## Keys $03A548..$03A6BA and inventory insertion $03A6BC..$03A70E.
## The original deletes a nearby key even when all nine inventory slots are full.
static func collect(actor: Dictionary, player: Dictionary, keys: Array) -> Dictionary:
	var result := {"actor": actor.duplicate(true), "keys": keys.duplicate(true), "slot": -1}
	if int(player.state) == 0 or not _inside(actor, player, 128):
		return result
	assert(int(actor.kind) >= 40 and int(actor.kind) <= 42)
	for index: int in range(keys.size()):
		if int(keys[index].kind) == 0:
			result.keys[index].kind = int(actor.kind) - 39
			result.keys[index].timer = 35
			result.slot = index
			break
	for field: String in result.actor:
		result.actor[field] = -1 if field in ["target", "seen", "owner", "wall_cursor"] else 0
	return result


static func _inside(actor: Dictionary, player: Dictionary, radius: int) -> bool:
	# Source comparisons use wrapped signed-word interval endpoints, rather
	# than an absolute distance or a Godot circular Area3D.
	return (
		_word(int(actor.x) - radius) <= int(player.x)
		and int(player.x) <= _word(int(actor.x) + radius)
		and _word(int(actor.y) - radius) <= int(player.y)
		and int(player.y) <= _word(int(actor.y) + radius)
	)


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
