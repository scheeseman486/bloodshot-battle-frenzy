class_name CdCoreDamage
extends RefCounted
## European CD $02F68E/$02F962/$039DCA. Native state transitions for core,
## satellite and terminal hits. Source traces: tests/traces/cd-core-nodes.json.
## Context supplies globals, ordered active IDs, actor/update IDs, level seconds
## and an allocated clone ID (-1 on exhaustion). All returned states are copies.
const Damage = preload("res://scripts/simulation/cd_combat_damage.gd")
const ActorAnimation = preload("res://scripts/simulation/cd_actor_animation.gd")
const Chase = preload("res://scripts/simulation/cd_enemy_chase.gd")


static func impact(
	state: Dictionary, projectile: Dictionary, context: Dictionary, catalog: Resource
) -> Dictionary:
	var result := _unchanged(state, context)
	if int(state.kind) == 4 and int(result.globals.gate) != 0:
		if int(result.globals.remaining) == 0:
			_accelerate(result.globals, catalog.theme, "shield_hit_angular", "shield_hit_rate")
		return result
	if int(state.kind) == 19:
		result.globals.remaining = _word(int(result.globals.remaining) - 1)
		result.state.kind = 23
		result.state.frame = 0
		_deactivate(result, int(context.actor))
		_clone_explosion(result, context, catalog)
		return result
	var params: Dictionary = catalog.parameters[int(state.parameter)]
	var reacted := Damage.reaction(
		state,
		int(projectile.vx),
		int(projectile.vy),
		int(projectile.damage),
		params,
		int(context.update),
		catalog
	)
	return health(reacted, int(projectile.damage), context, catalog)


static func health(
	state: Dictionary, damage: int, context: Dictionary, catalog: Resource
) -> Dictionary:
	var result := _unchanged(state, context)
	var params: Dictionary = catalog.parameters[int(state.parameter)]
	if int(state.kind) == 4 and int(state.health) <= damage:
		# Timer initialization precedes cloning; the duplicate keeps pre-reset
		# health/target fields. The lower slot is the explosion in either ordering.
		result.globals.countdown_boundary = _word(int(context.seconds) * 50 + 1)
		result.globals.countdown = _word(int(result.globals.countdown_boundary) + 250)
		result.state.kind = 21
		result.state = ActorAnimation.select(result.state, 0x30442, catalog).state
		_clone_explosion(result, context, catalog)
		_deactivate(result, int(context.actor))
		result.state.health = 0
		result.state.charge = 0
		result.state.cooldown = params.hit_rest
		result.state.counter = params.hit_clock
	else:
		if int(state.kind) == 17 and int(state.health) <= damage and int(state.target) != -1:
			result.globals.gate = _word(int(result.globals.gate) - 1)
			_accelerate(
				result.globals, catalog.theme, "satellite_death_angular", "satellite_death_rate"
			)
		var ordinary := Damage.enemy_health(
			state,
			damage,
			params,
			result.active,
			int(context.actor),
			int(result.globals.gate),
			catalog
		)
		result.state = ordinary.state
		result.active = ordinary.active
	return result


static func area(
	state: Dictionary,
	effect: Dictionary,
	origin: Dictionary,
	context: Dictionary,
	catalog: Resource,
	query_remainder: Callable = Callable()
) -> Dictionary:
	# The CD gates direct projectiles, but does not gate this explosion path.
	# Terminal splash follows ordinary health; it does not decrement remaining.
	if (
		not Damage._near_effect(state, effect, 180)
		or int(state.impulse_x) != 0
		or int(state.impulse_y) != 0
	):
		return _unchanged(state, context)
	var result := state.duplicate(true)
	var direction := Chase.normalize_direction(
		_word(int(state.x) - int(origin.x)), _word(int(state.y) - int(origin.y)), catalog
	)
	if query_remainder.is_valid():
		query_remainder.call(Damage._word(direction.y * 140) << 16)
	result.impulse_x = _word((direction.x * 140) >> 16)
	result.impulse_y = _word((direction.y * 140) >> 16)
	var params: Dictionary = catalog.parameters[int(state.parameter)]
	result = ActorAnimation.select(result, int(params.hurt), catalog).state
	return health(result, 70, context, catalog)


static func _accelerate(
	state: Dictionary, theme: Dictionary, angular: String, rate: String
) -> void:
	state.angular_speed = mini(
		_word(int(state.angular_speed) + int(theme[angular])), int(theme.maximum_angular)
	)
	state.satellite_rate = mini(
		_word(int(state.satellite_rate) + int(theme[rate])), int(theme.maximum_satellite_rate)
	)


static func _deactivate(result: Dictionary, actor: int) -> void:
	var index: int = result.active.find(actor)
	assert(index >= 0, "A damaged core/terminal belongs to the ordered active list")
	result.active.remove_at(index)
	result.state.target = -1


static func _clone_explosion(result: Dictionary, context: Dictionary, catalog: Resource) -> void:
	var clone_id := int(context.get("clone_id", -1))
	if clone_id < 0:
		return
	var copy: Dictionary = result.state.duplicate(true)
	if int(context.actor) < clone_id:
		result.state.kind = 48
		result.state = ActorAnimation.select(result.state, 0x3044e, catalog).state
	else:
		copy.kind = 48
		copy = ActorAnimation.select(copy, 0x3044e, catalog).state
	result.created.append({"id": clone_id, "state": copy})


static func _unchanged(state: Dictionary, context: Dictionary) -> Dictionary:
	return {
		"state": state.duplicate(true),
		"globals": context.globals.duplicate(true),
		"active": context.active.duplicate(),
		"created": []
	}


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
