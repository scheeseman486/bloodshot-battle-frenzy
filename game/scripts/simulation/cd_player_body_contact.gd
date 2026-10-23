class_name CdPlayerBodyContact
extends RefCounted
## European CD $0398C6..$039B1C, before each actor's behaviour dispatch.
## The 105-unit circular contact uses the previous/current player midpoint to
## choose an outward side. Blocked or excessive correction restores the previous
## player position; it does not deal damage or apply a generic physics impulse.
const Chase = preload("res://scripts/simulation/cd_enemy_chase.gd")
const RADIUS := 105


static func resolve(
	player: Dictionary,
	actor: Dictionary,
	own_proxy: int,
	catalog: Resource,
	query: Callable,
	query_remainder: Callable = Callable()
) -> Dictionary:
	var result := player.duplicate(true)
	if (
		int(player.state) != 1
		or int(actor.id) == own_proxy
		or int(actor.kind) < 1
		or int(actor.kind) > 22
	):
		return result
	var dx := _word(int(player.x) - int(actor.x))
	var dy := _word(int(player.y) - int(actor.y))
	if absi(dx) > RADIUS or absi(dy) > RADIUS or dx * dx + dy * dy >= RADIUS * RADIUS:
		return result
	var direction := Chase.normalize_direction(
		_word(((int(player.prev_x) + int(player.x)) >> 1) - int(actor.x)),
		_word(((int(player.prev_y) + int(player.y)) >> 1) - int(actor.y)),
		catalog
	)
	# Source lookup vectors are scaled by 16384; MULS420/SWAP produces
	# the 105-unit separation with the original signed high-word rounding.
	var target := Vector2i(
		_word(int(actor.x) + ((direction.x * 420) >> 16)),
		_word(int(actor.y) + ((direction.y * 420) >> 16))
	)
	if query_remainder.is_valid():
		query_remainder.call(_word(direction.y * 420) << 16)
	var contact: Dictionary = query.call(target)
	if result.has("wall_cursor") and contact.has("cursor"):
		result.wall_cursor = int(contact.cursor)
	if (
		contact.blocked
		or absi(_word(int(player.prev_x) - int(contact.target.x))) > 80
		or absi(_word(int(player.prev_y) - int(contact.target.y))) > 80
	):
		result.x = player.prev_x
		result.y = player.prev_y
	else:
		result.x = contact.target.x
		result.y = contact.target.y
	return result


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
