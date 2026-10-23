class_name CdStagedEnemyDamage
extends RefCounted
## European CD $02F962/$02FAFC..$02FB7C: kinds 11 and 12 leave their
## ordinary corpse and clone the next form into the first vacant source slot.
## Direct hits and explosion damage share this health transition. Drawing never
## drives the transformation or substitutes a different actor in the same slot.
const Damage = preload("res://scripts/simulation/cd_combat_damage.gd")
const ActorAnimation = preload("res://scripts/simulation/cd_actor_animation.gd")
const Chase = preload("res://scripts/simulation/cd_enemy_chase.gd")


static func health(
	state: Dictionary, damage: int, context: Dictionary, catalog: Resource
) -> Dictionary:
	var created: Array = []
	var kind := int(state.kind)
	var clone_id := int(context.get("clone_id", -1))
	if kind in [11, 12] and int(state.health) <= damage and clone_id >= 0:
		# $033574 copies all fields before the old form is killed/reset. In
		# particular its hit impulse, sighting and pre-reset counter survive.
		var next := state.duplicate(true)
		next.kind = kind + 1
		next.parameter = 0x2fd76 + (int(next.kind) - 1) * 64
		next.health = catalog.parameters[int(next.parameter)].health
		next.cooldown = 50
		next.frame = 0x52f24 if kind == 11 else 0x52f5a
		next.target = -1
		next.cursor = 0
		next.timer = 0
		created.append({"id": clone_id, "state": next})
	var ordinary := Damage.enemy_health(
		state,
		damage,
		catalog.parameters[int(state.parameter)],
		context.active,
		int(context.actor),
		int(context.gate),
		catalog
	)
	return {"state": ordinary.state, "active": ordinary.active, "created": created}


static func impact(
	state: Dictionary, projectile: Dictionary, context: Dictionary, catalog: Resource
) -> Dictionary:
	var reacted := Damage.reaction(
		state,
		int(projectile.vx),
		int(projectile.vy),
		int(projectile.damage),
		catalog.parameters[int(state.parameter)],
		int(context.update),
		catalog
	)
	return health(reacted, int(projectile.damage), context, catalog)


static func area(
	state: Dictionary,
	effect: Dictionary,
	origin: Dictionary,
	context: Dictionary,
	catalog: Resource,
	query_remainder: Callable = Callable()
) -> Dictionary:
	if (
		not Damage._near_effect(state, effect, 180)
		or int(state.impulse_x) != 0
		or int(state.impulse_y) != 0
	):
		return {"state": state.duplicate(true), "active": context.active.duplicate(), "created": []}
	var result := state.duplicate(true)
	var direction := Chase.normalize_direction(
		Damage._word(int(state.x) - int(origin.x)),
		Damage._word(int(state.y) - int(origin.y)),
		catalog
	)
	if query_remainder.is_valid():
		query_remainder.call(Damage._word(direction.y * 140) << 16)
	result.impulse_x = Damage._word((direction.x * 140) >> 16)
	result.impulse_y = Damage._word((direction.y * 140) >> 16)
	result = (
		ActorAnimation
		. select(result, int(catalog.parameters[int(state.parameter)].hurt), catalog)
		. state
	)
	return health(result, 70, context, catalog)
