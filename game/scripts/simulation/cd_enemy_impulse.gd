class_name CdEnemyImpulse
extends RefCounted


## Impulse movement/decay, sub-CPU $02FBCE..$02FCB0. This branch consumes an
## enemy update instead of ordinary chase/attack, while accumulating shot time.
static func advance(
	state: Dictionary, elapsed: int, query: Callable, query_remainder: Callable = Callable()
) -> Dictionary:
	var result := state.duplicate(true)
	result.counter = _word(int(result.counter) + elapsed)
	var target := Vector2i(
		_word(int(result.x) + clampi(_word(int(result.impulse_x) * elapsed), -80, 80)),
		_word(int(result.y) + clampi(_word(int(result.impulse_y) * elapsed), -80, 80))
	)
	if query_remainder.is_valid():
		query_remainder.call((int(result.impulse_y) * elapsed) & ~65535)
	var contact: Dictionary = query.call(target)
	if contact.blocked:
		contact = query.call(contact.target)
	if not contact.blocked:
		result.x = int(contact.target.x)
		result.y = int(contact.target.y)
	var decay := (elapsed + 1) >> 1
	for field: String in ["impulse_x", "impulse_y"]:
		var value := int(result[field])
		result[field] = (
			mini(0, _word(value + decay)) if value < 0 else maxi(0, _word(value - decay))
		)
	return result


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
