class_name CdKillReward
extends RefCounted
## Original kill-chain reward $0374E2..$037612. Runtime SHELL reward table.
## Caller decides whether a lethal hit qualifies; splash uses a distinct guard.
const Items = preload("res://scripts/simulation/cd_item_pickup.gd")
const Keys = preload("res://scripts/simulation/cd_key_pickup.gd")
const StatusOverlay = preload("res://scripts/simulation/cd_status_overlay.gd")


static func apply(
	player: Dictionary, weapons: Dictionary, globals: Dictionary, tables: Resource
) -> Dictionary:
	var result := {
		"player": player.duplicate(true),
		"weapons": weapons.duplicate(true),
		"globals": globals.duplicate(true),
		"audio": []
	}
	result.player.kill_chain = Items._word(int(player.kill_chain) + 1)
	if int(result.player.kill_chain) != 3:
		return result
	result.player.kill_chain = 0
	result.player.reward_timer = 70
	# Source ADDI.W addresses the upper word of the packed long counter.
	result.globals.damage_total = (
		((((int(globals.damage_total) >> 16) + 100) & 65535) << 16)
		| (int(globals.damage_total) & 65535)
	)
	result.globals.bonuses = Items._word(int(globals.bonuses) + 1)
	var index := int(player.reward_index)
	assert(index >= 0 and index < tables.rewards.size())
	var code := int(tables.rewards[index])
	result.player.reward_index = (index + 1) % tables.rewards.size()
	var contact := player.duplicate(true)
	contact.merge({"state": 1, "x": 0, "y": 0}, true)
	if code >= 22 and code <= 32:
		var pickup := Items.collect({"kind": code + 7, "x": 0, "y": 0}, contact, weapons)
		result.weapons = pickup.weapons
		result.player = StatusOverlay.pickup(result.player, result.weapons, bool(pickup.collected))
		if pickup.collected:
			result.audio.append_array([0x17c8c, 0x2547e])
	elif code >= 1 and code <= 3:
		var pickup := Keys.collect({"kind": code + 39, "x": 0, "y": 0}, contact, player.keys)
		result.player.keys = pickup.keys
		if int(pickup.slot) >= 0:
			result.audio.append_array([0x21c9a, 0x2547e])
	elif code == 37:
		# Reward healing assigns source health directly; its display copy is separate.
		result.player.health = 128
		result.audio.append(0x21272)
	elif code == 34:
		result.player = Items.add_life(result.player)
		if int(player.lives) < 4:
			result.audio.append(0x2547e)
		result.audio.append(0x2547e)
	elif code == 36:
		for index_in_inventory: int in range(9):
			var slot: Dictionary = result.weapons.inventory[index_in_inventory]
			if int(slot.kind) == 0:
				break
			slot.ammo = Items.FULL_AMMO
			slot.extra = Items.DISPLAY_TIMER
		result.audio.append(0x2547e)
	result.audio.append(0x1f72a)
	result.player = StatusOverlay.request(result.player, StatusOverlay.BONUS)
	return result
