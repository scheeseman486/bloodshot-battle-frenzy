extends RefCounted
## Native convenience actions in the unused upper 24 controls bits. The low
## source byte and original cycle callback remain unchanged for demos/tests/bots.
const Weapons = preload("res://scripts/simulation/cd_weapon_rules.gd")
const NEXT := 10
const PREVIOUS := 11
const MASK := 0xffffff00
const SERIAL_MAX := 0xfffff


static func word(held: int) -> int:
	return (~held >> 8) & 0xffffff


static func source_changed(a: Dictionary, b: Dictionary) -> bool:
	return (int(a.held) & 255) != (int(b.held) & 255) or int(a.strafe) != int(b.strafe)


static func take(latch: RefCounted, held: int) -> int:
	var token := word(held)
	var before := word(int(latch.state.previous))
	# The existing saved latch is also the deduplication watermark. Updating
	# these unused bits cannot manufacture a source move/fire/use/cycle edge.
	latch.state.previous = (int(latch.state.previous) & 255) | (held & MASK)
	var action := token & 15
	return (
		action if token != before and (token >> 4) > 0 and action >= 1 and action <= PREVIOUS else 0
	)


static func apply(state: Dictionary, action: int) -> Dictionary:
	if action == NEXT:
		return Weapons.cycle(state, 0xffffffdf)
	var result: Dictionary = state.duplicate(true)
	var events: Array[Dictionary] = []
	var response := {"state": result, "events": events}
	var selected := int(result.selected)
	var target := -1
	if action == PREVIOUS:
		for index: int in range(mini(9, result.inventory.size())):
			if int(result.inventory[index].kind) != 0 and index > selected:
				target = index
				break
		if target < 0 and int(result.inventory[0].kind) != 0:
			target = 0
	elif action >= 1 and action <= 9:
		target = action - 1
	if target < 0 or target >= result.inventory.size() or int(result.inventory[target].kind) == 0:
		return response
	result.manual = -1
	if target == selected:
		return response
	result.selected = target
	events.append({"kind": "weapon_selected", "slot": target})
	events.append({"kind": "sound", "source_id": 0x28390})
	return response
