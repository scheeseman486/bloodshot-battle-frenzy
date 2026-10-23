class_name CdCombatDamage
extends RefCounted
## Ordinary enemy health $02F962 and reaction $02F8EC, plus player health
## $037390. World rewards, boss transitions and respawn scheduling are separate.
const ActorAnimation = preload("res://scripts/simulation/cd_actor_animation.gd")
const Chase = preload("res://scripts/simulation/cd_enemy_chase.gd")
const Lifecycle = preload("res://scripts/simulation/cd_player_lifecycle.gd")
const PlayerFlash = preload("res://scripts/simulation/cd_player_flash.gd")


static func enemy_health(
	state: Dictionary,
	damage: int,
	params: Dictionary,
	active: Array,
	actor: int,
	gate: int,
	catalog: Resource
) -> Dictionary:
	var result := state.duplicate(true)
	var ordered := active.duplicate()
	var remaining := _word(int(state.health) - damage)
	if int(state.health) <= damage:
		result.kind = 23
		result = ActorAnimation.select(result, int(params.death), catalog).state
		var index := ordered.find(actor)
		assert(index >= 0, "Damaged enemies belong to the ordered active list")
		ordered.remove_at(index)
		result.target = -1
		remaining = 0
	result.health = remaining
	result.charge = 0
	result.cooldown = params.hit_rest
	result.counter = params.hit_clock
	return {"state": result, "active": ordered, "gate": gate}


static func reaction(
	state: Dictionary,
	vx: int,
	vy: int,
	damage: int,
	params: Dictionary,
	update: int,
	catalog: Resource
) -> Dictionary:
	var result: Dictionary = ActorAnimation.select(state, int(params.hurt), catalog).state
	var direction := Chase.normalize_direction(vx, vy, catalog)
	var forward := _word(damage * int(params.forward_push)) >> 3
	var sideways := int(params.lateral_push)
	if (update & 32) == 0:
		sideways = _word(-sideways)
	result.impulse_x = _word((direction.x * forward + direction.y * sideways) >> 16)
	result.impulse_y = _word((direction.y * forward - direction.x * sideways) >> 16)
	return result


static func player_health(state: Dictionary, damage: int) -> Dictionary:
	var result := state.duplicate(true)
	if int(result.kill_chain) != 0:
		result.kill_chain = _word(int(result.kill_chain) - 1)
	result.since_hit = 0
	var remaining := _word(int(result.health) - damage)
	if int(result.health) <= damage:
		result = Lifecycle.die(result)
		remaining = 0
	result.health = remaining
	result.health_copy = remaining
	return result


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768


static func enemy_impact(
	state: Dictionary,
	projectile: Dictionary,
	params: Dictionary,
	active: Array,
	actor: int,
	gate: int,
	update: int,
	catalog: Resource,
	clone_id: int = -1
) -> Dictionary:
	var result := state.duplicate(true)
	var ordered := active.duplicate()
	var created: Array = []
	if (
		(int(result.kind) == 5 or int(result.kind) == 6)
		and int(result.cursor) >= 0x303a2
		and int(result.cursor) < 0x303c6
		and int(projectile.kind) != 26
	):
		result = ActorAnimation.select(result, 0x303b6, catalog).state
	elif int(result.kind) == 15:
		result.frame = 0x527d4
		result.kind = 23
		result.target = -1
		var index := ordered.find(actor)
		assert(index >= 0)
		ordered.remove_at(index)
		if clone_id >= 0:
			var copy := result.duplicate(true)
			if actor < clone_id:
				result.kind = 48
				result = ActorAnimation.select(result, 0x3044e, catalog).state
			else:
				copy.kind = 48
				copy = ActorAnimation.select(copy, 0x3044e, catalog).state
			created.append({"id": clone_id, "state": copy})
	else:
		result = reaction(
			result,
			int(projectile.vx),
			int(projectile.vy),
			int(projectile.damage),
			params,
			update,
			catalog
		)
		var response := enemy_health(
			result, int(projectile.damage), params, ordered, actor, gate, catalog
		)
		result = response.state
		ordered = response.active
	return {"state": result, "active": ordered, "created": created}


static func player_impact(
	state: Dictionary,
	projectile: Dictionary,
	owner: Variant,
	owner_params: Dictionary,
	context: Dictionary,
	catalog: Resource
) -> Dictionary:
	var result := state.duplicate(true)
	var shooter: Variant = owner.duplicate(true) if owner != null else null
	if (
		int(result.state) == 2
		or (
			int(context.multiplayer) == 0
			and (int(projectile.owner) == -2 or int(projectile.owner) == -3)
		)
	):
		return {"state": result, "owner": shooter}
	if shooter != null:
		shooter.counter = owner_params.hit_attack_clock
		shooter.lost = 500
	var direction := Chase.normalize_direction(int(projectile.vx), int(projectile.vy), catalog)
	var force := _word(int(projectile.damage) * 6)
	result.impulse_x = _word((direction.x * force) >> 16)
	result.impulse_y = _word((direction.y * force) >> 16)
	var damage := int(projectile.damage)
	if int(context.demo_flag) == 0 and int(context.control_scheme) != 1:
		damage = _word(damage - (damage >> 2))
	result = player_health(PlayerFlash.hit(result), damage)
	if result.has("health_hit_timer"):
		result.health_hit_timer = 10  # Source direct-hit redraw at $03736C.
	return {"state": result, "owner": shooter}


## Explosion contacts $039D12/$039DCA. Bounds and existing-impulse guards
## are source rules; no radial Godot physics impulse is substituted.
static func area_player(
	state: Dictionary,
	effect: Dictionary,
	multiplayer: int,
	catalog: Resource,
	query_remainder: Callable = Callable()
) -> Dictionary:
	var result := state.duplicate(true)
	if (
		int(result.state) != 1
		or not _near_effect(result, effect, 128)
		or int(result.impulse_x) != 0
		or int(result.impulse_y) != 0
	):
		return result
	var direction := Chase.normalize_direction(
		_word(int(result.prev_x) - int(effect.x)),
		_word(int(result.prev_y) - int(effect.y)),
		catalog
	)
	if query_remainder.is_valid():
		query_remainder.call(_word(direction.y * 220) << 16)
	# The CD permits self-damage and repeated hits at the exact blast centre:
	# a zero direction leaves no impulse to trip the guard on the next update.
	# Close-wall weapon-7 traces explicitly preserve this lethal source behaviour.
	result.impulse_x = _word((direction.x * 220) >> 16)
	result.impulse_y = _word((direction.y * 220) >> 16)
	result.forward = 0
	return player_health(PlayerFlash.hit(result), 26 if multiplayer != 0 else 40)


static func area_enemy(
	state: Dictionary,
	effect: Dictionary,
	origin: Dictionary,
	params: Dictionary,
	active: Array,
	actor: int,
	gate: int,
	catalog: Resource,
	clone_id: int = -1,
	query_remainder: Callable = Callable()
) -> Dictionary:
	var result := state.duplicate(true)
	if not _near_effect(result, effect, 180):
		return {"state": result, "active": active.duplicate(), "created": []}
	if int(result.kind) == 15:
		return enemy_impact(result, effect, params, active, actor, gate, 0, catalog, clone_id)
	if int(result.impulse_x) != 0 or int(result.impulse_y) != 0:
		return {"state": result, "active": active.duplicate(), "created": []}
	var direction := Chase.normalize_direction(
		_word(int(result.x) - int(origin.x)), _word(int(result.y) - int(origin.y)), catalog
	)
	if query_remainder.is_valid():
		query_remainder.call(_word(direction.y * 140) << 16)
	result.impulse_x = _word((direction.x * 140) >> 16)
	result.impulse_y = _word((direction.y * 140) >> 16)
	result = ActorAnimation.select(result, int(params.hurt), catalog).state
	var health := enemy_health(result, 70, params, active, actor, gate, catalog)
	return {"state": health.state, "active": health.active, "created": []}


static func _near_effect(state: Dictionary, effect: Dictionary, radius: int) -> bool:
	# Inclusive signed-word intervals, retaining source subtraction wrap.
	return (
		int(state.x) >= _word(int(effect.x) - radius)
		and int(state.x) <= _word(int(effect.x) + radius)
		and int(state.y) >= _word(int(effect.y) - radius)
		and int(state.y) <= _word(int(effect.y) + radius)
	)
