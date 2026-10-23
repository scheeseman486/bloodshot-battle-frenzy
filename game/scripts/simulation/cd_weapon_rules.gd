class_name CdWeaponRules
extends RefCounted
## Weapon decisions, sub-CPU $039316, and selection, $039818.
## Projectile allocation/travel, target queries and damage belong to the world.


static func advance(
	state: Dictionary, context: Dictionary, tables: Resource, emit: Callable
) -> Dictionary:
	var result: Dictionary = state.duplicate(true)
	var events: Array[Dictionary] = []
	var response := {"state": result, "events": events}
	if int(result.state) != 1 and int(result.state) != 3:
		return response
	result.timer = _word(int(result.timer) + int(context.elapsed))
	if int(result.timer) < 0:
		result.timer = 0
	if (int(context.held) & 16) != 0:
		if int(result.special) >= 0 and int(context.special_kind) == 24:
			# The projectile world owns fragmentation/allocation. This event
			# requests the original release operation; it is not a damage rule.
			events.append({"kind": "release_special", "handle": result.special})
		result.pattern = 0
		result.special = -1
		return response
	var selected := int(result.selected)
	var weapon := int(result.inventory[selected].kind) if selected >= 0 else 0
	var parameters: Dictionary = tables.weapons[weapon]
	if int(result.timer) < int(parameters.minimum_delay):
		if (int(context.edge) & 16) == 0:
			result.buffered = -1
		return response
	var automatic := int(parameters.automatic_delay)
	if (
		int(result.buffered) == 0
		and (automatic < 0 or int(result.timer) < automatic)
		and (int(context.edge) & 16) != 0
	):
		return response
	# The source consumes the previous view's hit result. Its acquisition and
	# damage resolution are separate world rules, not simulated by this module.
	result.buffered = 0
	result.timer = 0
	# $39470..39492 hides the minimap for firing, including an empty-weapon
	# attempt. The default gun does so only with a non-prop active target.
	response.map_requested = weapon != 0 or bool(context.get("active_nonprop", false))
	if selected >= 0:
		if int(result.inventory[selected].ammo) <= 0:
			_remove_empty(result, selected)
			events.append({"kind": "inventory_changed"})
			return response
		var cost := int(parameters.ammo_cost)
		if int(context.demo) == 0 and int(context.control_scheme) != 1:
			cost -= cost >> 2
		if int(context.resolution_mode) == 2 and int(context.multiplayer) == 0:
			cost >>= 1
		result.inventory[selected].ammo = maxi(int(result.inventory[selected].ammo) - cost, 0)
		events.append({"kind": "ammo_changed", "slot": selected})
	if int(parameters.sound_id) >= 0:
		events.append({"kind": "sound", "source_id": parameters.sound_id})
	if weapon == 10:
		var spread: int = tables.spread[int(result.pattern)]
		result.pattern = (int(result.pattern) + 1) % tables.spread.size()
		_projectile(result, emit, weapon, spread, 0)
	elif weapon == 9:
		events.append({"kind": "weapon_animation", "weapon": weapon})
		for spread: int in [-21, -14, -7, 0, 7, 14]:
			_projectile(result, emit, weapon, spread, 0)
	elif weapon == 5:
		_projectile(result, emit, weapon, -4, 0)
		_projectile(result, emit, weapon, 4, 0)
		_projectile(result, emit, weapon, 0, 18)
	elif weapon == 2 and int(context.hit_flag) != 64:
		emit.call({"kind": "direct_hit", "target": context.hit_target})
	else:
		_projectile(result, emit, weapon, 0, 0)
	return response


static func cycle(state: Dictionary, edge: int) -> Dictionary:
	var result: Dictionary = state.duplicate(true)
	var events: Array[Dictionary] = []
	var response := {"state": result, "events": events}
	if (edge & 32) != 0 or int(result.selected) < 0:
		return response
	var previous := int(result.selected) - 1
	if previous < 0:
		result.manual = 0
		select_automatic(result)
		if int(result.inventory[1].kind) == 0:
			return response
	else:
		result.selected = previous
		result.manual = -1
	events.append({"kind": "weapon_selected", "slot": result.selected})
	events.append({"kind": "sound", "source_id": 0x28390})  # CD $39878/$3987E.
	return response


static func _projectile(
	state: Dictionary, emit: Callable, weapon: int, spread: int, speed_offset: int
) -> void:
	var handle := int(
		emit.call(
			{"kind": "projectile", "weapon": weapon, "spread": spread, "speed_offset": speed_offset}
		)
	)
	if weapon == 8 and handle >= 0:
		state.special = handle


static func _remove_empty(state: Dictionary, selected: int) -> void:
	# The original inventory has eighteen records including an empty tail
	# sentinel. Compaction copies complete records; only the final kind clears.
	for index: int in range(selected, state.inventory.size() - 1):
		state.inventory[index] = state.inventory[index + 1].duplicate()
	state.inventory[-1].kind = 0
	state.manual = 0
	select_automatic(state)


## $03A4FC: default when unarmed; otherwise preserve manual choice or select
## the last occupied source slot. Used by acquisition and empty-weapon removal.
static func select_automatic(state: Dictionary) -> void:
	if int(state.inventory[0].kind) == 0:
		state.selected = -1
	elif int(state.manual) == 0:
		for index: int in range(state.inventory.size() - 1, -1, -1):
			if int(state.inventory[index].kind) != 0:
				state.selected = index
				return


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
