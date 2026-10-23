class_name CdHudModel
extends RefCounted
## Pure layout/value translation from original HUD routines. No scene or clock work.


## European CD $037660..$03775C, expressed in the source HUD canvas. Only flag
## value 1 enables all weapon sights; weapon 2 also has its own acquisition sight.
## The original artwork's centre sits four source rows below the view midpoint.
static func weapon_sight(
	state: int, weapon: int, all_sights: int, hit_flag: int = 64, hit_offset: int = 0
) -> Dictionary:
	if state != 1 or weapon < 0 or weapon > 10 or (all_sights != 1 and weapon != 2):
		return {"visible": false}
	var locked := weapon == 2 and hit_flag != 64
	return {
		"visible": true,
		"frame": 11 if locked else weapon,
		"position": Vector2i(120 + (hit_offset if locked else 0), 132)
	}


static func health_tiles(health: int, highlighted: bool = false) -> Array[int]:
	var tiles: Array[int] = []
	var empty := 128 - clampi(health, 0, 128)
	var base := 0xb6 if highlighted else 0xa2
	for row: int in range(16):
		var amount := mini(empty, 8)
		empty -= amount
		var tile := base + amount * 2
		if row == 15:
			tile = 0xc8 if amount == 8 else base - 2
		tiles.append(tile)
	return tiles


static func ammo_tiles(ammo: int) -> Array[int]:
	var tiles: Array[int] = []
	var empty := maxi(23 - (ammo >> 16), 0)
	for row: int in range(6):
		tiles.append(0xc8 + row * 5 + mini(empty, 4))
		empty = maxi(empty - 4, 0)
	return tiles


static func icon_tiles(icon: int) -> Array[int]:
	var column := posmod(icon, 20)
	@warning_ignore("integer_division")
	var row := icon / 20
	var tile := row * 80 + column * 2
	return [tile, tile + 1, tile + 40, tile + 41]


static func reward_meter_tiles(chain: int, flashing: bool) -> Array[int]:
	var result: Array[int] = []
	var remaining := 3 if flashing else chain
	for segment: int in range(3):
		remaining = ((remaining - 1 + 32768) & 65535) - 32768
		result.append(231 if remaining >= 0 else 229)
	return result


## $00BD9C keeps the larger old/new life count during a notification. Its last
## occupied slot displays the same animated static used for weapon/key pickups.
static func life_icons(lives: int, previous: int, flashing: bool) -> Array[int]:
	var remaining := maxi(maxi(lives, 0), previous) if flashing else maxi(lives, 0)
	var result: Array[int] = []
	for index: int in range(4):
		result.append(5 if remaining <= 0 else 33 if flashing and remaining == 1 else 4)
		remaining -= 1
	return result
