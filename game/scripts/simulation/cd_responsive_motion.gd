class_name CdResponsiveMotion
extends RefCounted
## Deliberate native locomotion adapter, not a port of a new source routine.
## Four steps per measured input period retain sub-unit displacement rather than
## rounding every small step away. Original integer wall queries remain in use.
const POLICY_ID := "native-responsive-player-v1"
const SUBSTEPS := 4
const POSITION_BITS := 18  # source trig divisor 65536 * four substeps
const POSITION_ONE := 1 << POSITION_BITS
const ANGLE_ONE := 65536
const ANGLE_CYCLE := 16384 * ANGLE_ONE


static func advance(
	state: Dictionary, tables: Resource, samples_per_update: int, query: Callable
) -> Dictionary:
	var result := state.duplicate()
	if int(result.state) not in [1, 3]:
		return result
	var phase := (int(result.angle) >> 6) & 255
	var angle := int(result.angle) * ANGLE_ONE + int(result.get("angle_sub", 0))
	@warning_ignore("integer_division")
	angle = posmod(angle + int(result.turn) * ANGLE_ONE / SUBSTEPS, ANGLE_CYCLE)
	result.angle = angle >> 16
	result.angle_sub = angle & (ANGLE_ONE - 1)
	_translate(
		result,
		int(result.forward),
		int(tables.sine[phase]),
		int(tables.cosine[phase]),
		samples_per_update,
		query
	)
	_translate(
		result,
		int(result.strafe),
		int(tables.cosine[phase]),
		-int(tables.sine[phase]),
		samples_per_update,
		query
	)
	return result


static func aim(state: Dictionary, delta: float) -> void:
	if int(state.state) not in [1, 3] or not is_finite(delta):
		return
	var angle := int(state.angle) * ANGLE_ONE + int(state.get("angle_sub", 0))
	angle = posmod(angle + roundi(fmod(delta, 16384.0) * ANGLE_ONE), ANGLE_CYCLE)
	state.angle = angle >> 16
	state.angle_sub = angle & (ANGLE_ONE - 1)


## Equivalent to successive already-rounded 16.16 aim events. Local prediction
## uses integer addition after admission; authority timing remains unchanged.
static func aim_fixed(state: Dictionary, delta: int) -> void:
	if int(state.state) not in [1, 3]:
		return
	var angle := posmod(
		int(state.angle) * ANGLE_ONE + int(state.get("angle_sub", 0)) + delta, ANGLE_CYCLE
	)
	state.angle = angle >> 16
	state.angle_sub = angle & (ANGLE_ONE - 1)


static func pose(state: Dictionary) -> Dictionary:
	var result := state.duplicate()
	result.x = float(state.x) + float(state.get("x_sub", 0)) / POSITION_ONE
	result.y = float(state.y) + float(state.get("y_sub", 0)) / POSITION_ONE
	result.angle = float(state.angle) + float(state.get("angle_sub", 0)) / ANGLE_ONE
	return result


static func _translate(
	state: Dictionary, speed: int, sine: int, cosine: int, period: int, query: Callable
) -> void:
	if speed == 0:
		return
	# Preserve the normalized source's 80-unit per-axis/per-move ceiling as a
	# velocity limit. Splitting its displacement must not increase top speed.
	@warning_ignore("integer_division")
	var limit := (80 * POSITION_ONE) / (SUBSTEPS * period)
	var x := (
		(int(state.x) << POSITION_BITS)
		+ int(state.get("x_sub", 0))
		+ clampi(speed * sine, -limit, limit)
	)
	var y := (
		(int(state.y) << POSITION_BITS)
		+ int(state.get("y_sub", 0))
		+ clampi(speed * cosine, -limit, limit)
	)
	var target := Vector2i(_word(x >> POSITION_BITS), _word(y >> POSITION_BITS))
	var contact: Dictionary = query.call(target)
	if contact.blocked:
		state.contact_attempt = _word(int(state.contact_attempt) + 1)
		if int(state.contact_attempt) != 1:
			return
		state.contact_attempt = 0
		contact = query.call(contact.target)
		if contact.blocked:
			if not _can_leave_overlap(state, speed, sine, cosine, period, query):
				return
			# Keep this tiny intended movement, including its fractional speed.
			# The source-sized endpoint proves an exit exists in this direction;
			# it is never used as a teleport or a deferred movement destination.
			contact = {"target": target, "blocked": false}
			query.call(target)  # Restore the search cursor to the actual position.
	var resolved: Vector2i = contact.target
	if absi(_word(int(state.x) - resolved.x)) > 80 or absi(_word(int(state.y) - resolved.y)) > 80:
		return
	state.x = resolved.x
	state.y = resolved.y
	# A clipped axis loses its residual: it must not accumulate behind a wall.
	state.x_sub = (x & (POSITION_ONE - 1)) if resolved.x == target.x else 0
	state.y_sub = (y & (POSITION_ONE - 1)) if resolved.y == target.y else 0


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768


## A closing door can leave an existing overlap whose two corrections disagree
## by one map unit. Original coarse movement can leave it, while tiny responsive
## steps otherwise repeat the rejected correction forever. Permit only the
## current input's ordinary-speed steps when its exact source-sized endpoint is
## clear. A player outside an overlap can never enter this escape path.
static func _can_leave_overlap(
	state: Dictionary, speed: int, sine: int, cosine: int, period: int, query: Callable
) -> bool:
	var current := Vector2i(int(state.x), int(state.y))
	if not bool(query.call(current).blocked):
		return false
	var distance := _word(absi(speed) * period)
	var dx := _word((sine * distance) >> 16)
	var dy := _word((cosine * distance) >> 16)
	if speed < 0:
		dx = _word(-dx)
		dy = _word(-dy)
	var endpoint := current + Vector2i(clampi(dx, -80, 80), clampi(dy, -80, 80))
	return endpoint != current and not bool(query.call(endpoint).blocked)
