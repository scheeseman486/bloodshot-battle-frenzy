class_name CdPauseRules
extends RefCounted
## European CD paused input $30822 and callbacks $30A12..30B40.
const Pickups = preload("res://scripts/simulation/cd_item_pickup.gd")
const Weapons = preload("res://scripts/simulation/cd_weapon_rules.gd")
const Status = preload("res://scripts/simulation/cd_status_overlay.gd")
const WEAPON_CALLBACKS := {
	0x30ab6: 1,
	0x30ac4: 2,
	0x30ad2: 3,
	0x30ae0: 4,
	0x30aee: 5,
	0x30afc: 6,
	0x30b0a: 7,
	0x30b18: 8,
	0x30b26: 9,
	0x30b34: 10
}


static func advance(history: Array, edge: int, codes: Array) -> Dictionary:
	var resumed := (edge & 128) == 0
	# $3084C leaves the pause cue pointer in D0 before $30880 scans it.
	# This stock-CD Start side effect appends Up, even with no direction held.
	var effective := 0x2873c if resumed else edge
	var result := {"history": history.duplicate(), "match": -1, "resume": resumed}
	if (effective & 127) == 127:
		return result
	var symbol := 1
	while (effective & 1) != 0:
		effective >>= 1
		symbol += 1
	result.history = history.slice(1)
	result.history.append(symbol)
	for index: int in range(codes.size()):
		if result.history == codes[index].sequence:
			result.match = index
			return result
	return result


static func apply(before: Dictionary, callback: int) -> Dictionary:
	var result := before.duplicate(true)
	var player: Dictionary = result.player
	var weapons: Dictionary = player.weapons
	var audio: Array[int] = [0x1f72a]
	result.mode = 2
	result.cheated = -1
	# $3091A is a word store to the high half of the packed long tally.
	result.damage_total = int(result.damage_total) & 65535
	result.windows = [0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff]
	match callback:
		0x30a12:
			result.level = mini(16, int(result.level) + 1)
			result.exit_delay = -2
			player.health = 128
			for key: Dictionary in player.keys:
				if int(key.kind) in [1, 2]:
					key.kind = 0
				key.timer = 0
		0x30a46:
			if int(player.lives) < 4:
				player = Pickups.add_life(player)
				audio.append(0x2547e)
			audio.append(0x2547e)
		0x30a5e:
			player.health = 128
			audio.append(0x21272)
		0x30a8a:
			for index: int in range(9):
				if int(weapons.inventory[index].kind) == 0:
					break
				weapons.inventory[index].ammo = 0x150000
				weapons.inventory[index].extra = 35
			player = Status.selection(player, weapons, -1, false)
			audio.append(0x2547e)
		0x30a96, 0x30aa6:
			for key: Dictionary in player.keys:
				if int(key.kind) == 0:
					key.kind = 2 if callback == 0x30a96 else 1
					key.timer = 35
					audio.append_array([0x21c9a, 0x2547e])
					break
		_:
			assert(WEAPON_CALLBACKS.has(callback), "Unverified European CD cheat callback")
			player = Status.pickup(player, weapons, false)
			for index: int in range(9):
				if int(weapons.inventory[index].kind) == 0:
					weapons.inventory[index] = {
						"kind": WEAPON_CALLBACKS[callback], "ammo": 0x150000, "extra": 35
					}
					Weapons.select_automatic(weapons)
					player = Status.pickup(player, weapons, true)
					audio.append_array([0x17c8c, 0x2547e])
					break
	player.weapons = weapons
	result.player = player
	result.audio = audio
	return result


static func after_level_load(before: Dictionary) -> Dictionary:
	# $36C34/36C80 clear all eighteen inventory records whenever the cheat flag
	# survives a level load. Keep its selected slot/manual value as the CD does.
	var result := before.duplicate(true)
	var player: Dictionary = result.player
	player.health = 128
	player.health_copy = 128
	player.state = 1
	player.map_timer = 150
	var selected := int(player.weapons.selected)
	player.panel_weapon = int(player.weapons.inventory[selected].kind) - 1 if selected >= 0 else -1
	for weapon: Dictionary in player.weapons.inventory:
		weapon.kind = 0
		weapon.ammo = 0
		weapon.extra = 0
	result.exit_delay = 0
	return result


static func can_pause(player: Dictionary, views: int = 1, layout_busy: int = 0) -> bool:
	return (
		int(player.state) != 0
		and views > 0
		and layout_busy == 0
		and int(player.get("death_timer", 0)) == 0
		and int(player.get("flash_cursor", 0)) == 0
	)
