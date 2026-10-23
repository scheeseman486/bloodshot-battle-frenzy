class_name CdMovementRules
extends RefCounted
## Source player movement $0362E8..$036390. Collision is an explicit world query.


static func advance(
	state: Dictionary,
	elapsed: int,
	sine: int,
	cosine: int,
	query: Callable,
	query_remainder: Callable = Callable()
) -> Dictionary:
	var result := state.duplicate()
	if int(result.state) != 1 and int(result.state) != 3:
		return result
	result.angle = posmod(_word(int(result.angle) + int(result.turn) * elapsed), 16384)
	if int(result.forward) == 0:
		result.walk_phase = 0
	else:
		_translate(result, int(result.forward), elapsed, sine, cosine, query, query_remainder)
		if int(result.forward) > 0:
			result.walk_phase = 1 if int(result.walk_phase) >= 8 else int(result.walk_phase) + 1
		else:
			result.walk_phase = 8 if int(result.walk_phase) <= 1 else int(result.walk_phase) - 1
	if int(result.strafe) != 0:
		_translate(result, int(result.strafe), elapsed, cosine, -sine, query, query_remainder)
	return result


static func _translate(
	state: Dictionary,
	speed: int,
	elapsed: int,
	sine: int,
	cosine: int,
	query: Callable,
	query_remainder: Callable
) -> void:
	var distance := _word(absi(speed) * elapsed)
	# Signed high-word multiplication floors negative products. Backward movement
	# negates AFTER truncation, as $036392 does; changing that order changes paths.
	var dx := _word((sine * distance) >> 16)
	var dy := _word((cosine * distance) >> 16)
	if speed < 0:
		dx = _word(-dx)
		dy = _word(-dy)
	var target := Vector2i(
		_word(int(state.x) + clampi(dx, -80, 80)), _word(int(state.y) + clampi(dy, -80, 80))
	)
	if query_remainder.is_valid():
		# MULS/SWAP retains the multiplication's fractional word during the
		# source wall query. Zero-axis moving walls can consume that remainder.
		query_remainder.call(_word(cosine * distance) << 16)
	var contact: Dictionary = query.call(target)
	if contact.blocked:
		state.contact_attempt = _word(int(state.contact_attempt) + 1)
		if int(state.contact_attempt) != 1:
			return
		state.contact_attempt = 0
		contact = query.call(contact.target)
		if contact.blocked:
			return
	target = contact.target
	if absi(_word(int(state.x) - target.x)) <= 80 and absi(_word(int(state.y) - target.y)) <= 80:
		state.x = target.x
		state.y = target.y


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
