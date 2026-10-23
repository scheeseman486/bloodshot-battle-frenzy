class_name CdItemPickup
extends RefCounted
## Health/ammo/weapons at $03A548, weapon insertion $03A460 and refill $037614.
## This returns gameplay commits; source HUD redraw/blink timing is separate.
const WeaponRules = preload("res://scripts/simulation/cd_weapon_rules.gd")
const StatusOverlay = preload("res://scripts/simulation/cd_status_overlay.gd")
const FULL_AMMO := 0x150000
const DISPLAY_TIMER := 35


static func collect(
	actor: Dictionary, player: Dictionary, weapons: Dictionary, multiplayer: int = 0
) -> Dictionary:
	var result := {
		"actor": actor.duplicate(true),
		"player": player.duplicate(true),
		"weapons": weapons.duplicate(true),
		"collected": false
	}
	if int(player.state) == 0 or not _inside(actor, player):
		return result
	var kind := int(actor.kind)
	if kind >= 29 and kind <= 38:
		result.player = StatusOverlay.pickup(result.player, result.weapons, false)
		var capacity := 9 if multiplayer == 0 else 6
		for index: int in range(capacity):
			if int(result.weapons.inventory[index].kind) == 0:
				result.weapons.inventory[index] = {
					"kind": kind - 28, "ammo": FULL_AMMO, "extra": DISPLAY_TIMER
				}
				WeaponRules.select_automatic(result.weapons)
				result.collected = true
				result.player = StatusOverlay.pickup(result.player, result.weapons, true)
				break
	elif kind == 43:
		if int(player.health) != 128:
			# Keep the CD's signed-word addition and preserve health_copy: that
			# field belongs to the separately animated original health display.
			result.player.health = mini(_word(int(player.health) + 32), 128)
			result.collected = true
	elif kind == 44:
		# Source scans nine contiguous records and stops at the first empty
		# kind. One underfull slot causes the whole carried prefix to refill.
		for index: int in range(9):
			if int(result.weapons.inventory[index].kind) == 0:
				break
			if int(result.weapons.inventory[index].ammo) < FULL_AMMO:
				result.collected = true
				break
		if result.collected:
			for index: int in range(9):
				if int(result.weapons.inventory[index].kind) == 0:
					break
				result.weapons.inventory[index].ammo = FULL_AMMO
				result.weapons.inventory[index].extra = DISPLAY_TIMER
	elif kind == 45 and int(player.lives) < 4:
		result.player = add_life(player)
		result.collected = true
	if result.collected:
		for field: String in result.actor:
			result.actor[field] = -1 if field in ["target", "seen", "owner", "wall_cursor"] else 0
	return result


## Shared $037490 life increment, including its original signed-word behaviour.
static func add_life(player: Dictionary) -> Dictionary:
	var result := player.duplicate(true)
	if int(player.lives) < 4:
		result.lives_previous = player.lives
		result.lives = _word(int(player.lives) + 1)
		result.lives_timer = DISPLAY_TIMER
	return result


static func _inside(actor: Dictionary, player: Dictionary) -> bool:
	return (
		_word(int(actor.x) - 128) <= int(player.x)
		and int(player.x) <= _word(int(actor.x) + 128)
		and _word(int(actor.y) - 128) <= int(player.y)
		and int(player.y) <= _word(int(actor.y) + 128)
	)


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
