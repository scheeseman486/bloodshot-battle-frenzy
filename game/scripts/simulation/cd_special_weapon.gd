class_name CdSpecialWeapon
extends RefCounted
## European CD aimed projectile $0396D4 and release fan $03935A..$0393F6.
## Allocation IDs are supplied in original first-empty order by the world.
const Chase = preload("res://scripts/simulation/cd_enemy_chase.gd")
const FRAGMENT_FRAME := 0x3e798


static func aim(player: Dictionary, target: Dictionary, catalog: Resource) -> Vector2i:
	return Chase.normalize_direction(
		_word(int(target.x) - int(player.x)), _word(int(target.y) - int(player.y)), catalog
	)


static func split(
	state: Dictionary, clone_ids: Array, tables: Resource, query_remainder: Callable = Callable()
) -> Dictionary:
	var result := {"state": state.duplicate(true), "created": [], "audio": [0x10d18]}
	result.state.frame = FRAGMENT_FRAME
	result.state.damage = 35
	var phase := _word(int(state.launch_angle)) >> 6
	phase = posmod(phase - 48, 256)
	var remainder := 0
	for index: int in range(mini(clone_ids.size(), 6) + 1):
		var fragment: Dictionary = result.state if index == 0 else result.state.duplicate(true)
		fragment.vx = _divide(int(tables.sine[phase]) * 13, 16384)
		var product := int(tables.cosine[phase]) * 13
		fragment.vy = _divide(product, 16384)
		# $0393E2..0393EA: DIVS retains its signed remainder above the
		# quotient. Zero-axis door queries later consume the final fragment's
		# high word if player movement has not replaced that context.
		remainder = (product - int(fragment.vy) * 16384) << 16
		if index > 0:
			result.created.append({"id": int(clone_ids[index - 1]), "state": fragment})
		phase = (phase + 16) & 255
	if query_remainder.is_valid():
		query_remainder.call(remainder)
	return result


static func select_candidate(before: Dictionary, offset: int, actor: int) -> Dictionary:
	var result := before.duplicate(true)
	if absi(offset) <= int(before.hit_flag):
		result.hit_flag = absi(offset)
		result.hit_target = actor
	return result


## Behaviour-only horizontal projection, $0324C4..$032524. No console drawing.
## 32767 denotes a point behind the player or an overflowing source quotient.
static func projected_offset(
	player: Dictionary, target: Dictionary, tables: Resource, scale: int
) -> int:
	var phase := int(player.view_angle) & 255
	var dx := _word(int(target.x) - int(player.x))
	var dy := _word(int(target.y) - int(player.y))
	var sine := int(tables.sine[phase])
	var cosine := int(tables.cosine[phase])
	var lateral := _word(_signed32((dx * sine + dy * cosine) << 2) >> 16)
	var depth := _word(_signed32((dy * sine - dx * cosine) << 1) >> 16)
	if depth <= 0:
		return 32767
	var offset := _divide(lateral * scale, depth)
	return offset if offset >= -32768 and offset <= 32767 else 32767


static func _divide(numerator: int, denominator: int) -> int:
	@warning_ignore("integer_division")
	return numerator / denominator


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768


static func _signed32(value: int) -> int:
	value &= 0xffffffff
	return value - 0x100000000 if value >= 0x80000000 else value
