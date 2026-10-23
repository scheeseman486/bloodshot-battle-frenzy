@tool
class_name CdBehaviourTables
extends Resource
## Runtime translation of non-code tables from the European CD SHELL.BIN.

var sine := PackedInt32Array()
var cosine := PackedInt32Array()
var weapons: Array[Dictionary] = []
var projectile_weapons: Dictionary = {}
var spread := PackedInt32Array()
var rewards := PackedInt32Array()
var player_flashes: Dictionary = {}
var player_proxy_frames := PackedInt32Array()
var source_sha256: String


func decode(data: PackedByteArray) -> bool:
	# SHELL is loaded at sub-CPU $008000. Only translate identified data
	# spans; original instructions are never interpreted by the native game.
	if data.size() < 0x328ee:
		return false
	sine.clear()
	cosine.clear()
	weapons.clear()
	projectile_weapons.clear()
	spread.clear()
	rewards.clear()
	player_flashes.clear()
	player_proxy_frames.clear()
	for phase: int in range(256):
		sine.append(_s16(data, 0x3d2 + phase * 2))
		cosine.append(_s16(data, 0x5d2 + phase * 2))
	for index: int in range(21):
		var at := 0x32710 + index * 22
		var parameters := {
			"ammo_cost": _u32(data, at),
			"damage": _s16(data, at + 4),
			"frame_address": _u32(data, at + 6),
			"sound_id": _s32(data, at + 10),
			"speed": _s16(data, at + 14),
			"projectile_kind": _s16(data, at + 16),
			"minimum_delay": _s16(data, at + 18),
			"automatic_delay": _s16(data, at + 20)
		}
		projectile_weapons[0x3a710 + index * 22] = parameters
		if index < 11:
			weapons.append(parameters)
	for index: int in range(8):
		spread.append(_s16(data, 0x328de + index * 2))
	# $0374E2 advances through this seventeen-entry list and wraps at -1.
	for index: int in range(17):
		rewards.append(_s16(data, 0x2f91c + index * 2))
	if _s16(data, 0x2f91c + 34) != -1:
		return false
	# Hit and death are duration/colour pairs on the independent PAL clock.
	for start: int in [0x37784, 0x3778a, 0x377b4]:
		var cursor := start
		for guard: int in range(32):
			var duration := _s16(data, cursor - 0x8000)
			player_flashes[cursor] = {
				"duration": duration,
				"word": _s16(data, cursor - 0x8000 + 2) if duration != 0 else 0
			}
			if duration == 0:
				break
			if duration < 0:
				return false
			cursor += 4
	for index: int in range(40):
		player_proxy_frames.append(_u32(data, 0x2f87c + index * 4))
	return true


static func _s16(data: PackedByteArray, at: int) -> int:
	var value := (int(data[at]) << 8) | int(data[at + 1])
	return value - 65536 if value >= 32768 else value


static func _u32(data: PackedByteArray, at: int) -> int:
	return (
		(int(data[at]) << 24)
		| (int(data[at + 1]) << 16)
		| (int(data[at + 2]) << 8)
		| int(data[at + 3])
	)


static func _s32(data: PackedByteArray, at: int) -> int:
	var value := _u32(data, at)
	return value - 4294967296 if value >= 2147483648 else value
