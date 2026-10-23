class_name CdCampaignCarry
extends RefCounted
const StatusOverlay = preload("res://scripts/simulation/cd_status_overlay.gd")


## CD inter-level handoff: player initialization $036C80 and the captured
## LEVEL1-to-LEVEL2 transition preserve lives/weapons/key 3, restore health and clear level keys 1/2.
static func capture(session: RefCounted) -> Dictionary:
	var weapons: Dictionary = session.weapon_state
	var inventory: Array = weapons.inventory.duplicate(true)
	for slot: Dictionary in inventory:
		slot.extra = 0  # Original inter-level cards outlast all HUD pickup flashes.
	var keys: Array = session.keys.duplicate(true)
	for key: Dictionary in keys:
		if int(key.kind) in [1, 2]:
			key.kind = 0
		key.timer = 0
	return {
		"keys": keys,
		"palette_phase": session.palette_state.phase,
		"lives": session.fighter.lives,
		"reward_index": int(session.fighter.get("reward_index", 0)),
		"inventory": inventory,
		"selected": weapons.selected,
		"manual": weapons.manual,
		"pattern": weapons.pattern,
		# $031228 resets per-level counters, radius/speed and both RNG streams.
		# The orbit phase, packed campaign tally and $055B34 update word survive.
		"boss_phase": int(session.actor_system.boss_clock.clock),
		"damage_total": int(session.actor_system.encounter.damage_total),
		"countdown_boundary": int(session.actor_system.encounter.countdown_boundary),
		"world_update": int(session.actor_system._update)
	}


static func apply_to(session: RefCounted, carry: Dictionary) -> void:
	if carry.is_empty():
		return
	session.fighter.lives = int(carry.lives)
	session.fighter.reward_index = int(carry.get("reward_index", 0))
	session.fighter.grace = 20
	session.keys = carry.keys.duplicate(true)
	session.palette_state.phase = int(carry.palette_phase)
	session.weapon_state.inventory = carry.inventory.duplicate(true)
	for field: String in ["selected", "manual", "pattern"]:
		session.weapon_state[field] = carry[field]
	if session.actor_system != null:
		session.actor_system.boss_clock.clock = int(carry.get("boss_phase", 0))
		session.actor_system.encounter.damage_total = int(carry.get("damage_total", 0))
		session.actor_system.encounter.countdown_boundary = int(carry.get("countdown_boundary", 0))
		session.actor_system._update = int(carry.get("world_update", 0)) & 65535
	# Player initialization requests the retained weapon card for 150 world
	# samples before the minimap returns, including an unarmed handoff.
	session.fighter = StatusOverlay.selection(session.fighter, session.weapon_state, -1)
