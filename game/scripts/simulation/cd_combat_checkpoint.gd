class_name CdCombatCheckpoint
extends RefCounted
## European CD prop $02F798 and core startup/death checkpoint writes.
## Checkpoints store source position/heading; respawn scheduling is separate.


static func prop(
	players: Array,
	owner: int,
	multiplayer: int,
	level: Resource,
	fractions: Array,
	active_kinds: Array
) -> Array:
	var result := players.duplicate(true)
	if multiplayer != 0 or owner not in [-2, -3] or active_kinds.has(4):
		return result
	var index := 0 if owner == -2 else 1
	if index >= result.size():
		return result
	var player: Dictionary = result[index]
	for wall: Dictionary in level.walls:
		var group := int(wall.motion_group)
		if int(wall.motion_kind) != 1 or group >= fractions.size() or int(fractions[group]) == 0:
			continue
		# The source tests the original wall start, not its translated position.
		if (
			absi(_word(int(wall.start.x) - int(player.x))) <= 256
			and absi(_word(int(wall.start.y) - int(player.y))) <= 256
		):
			return result
	_store(player)
	return result


static func core(players: Array) -> Array:
	var result := players.duplicate(true)
	for player: Dictionary in result:
		_store(player)
	return result


static func _store(player: Dictionary) -> void:
	player.checkpoint_x = player.x
	player.checkpoint_y = player.y
	player.checkpoint_angle = int(player.get("angle", 0))


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
