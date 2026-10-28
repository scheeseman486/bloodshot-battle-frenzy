class_name CdInputAdmission
extends RefCounted
## Authority-local rational event timeline. A timestamp describes the last fast
## boundary plus its exact residue, including all older unexecuted clock debt.
const Motion = preload("res://scripts/simulation/cd_responsive_motion.gd")


static func initial() -> Dictionary:
	return {
		"queue": [],
		"controls": {},
		"rates": {},
		"next_sequence": 1,
		"applied": 0,
		"source_visibility": false
	}


static func admit(
	world: RefCounted, reference: Dictionary, controls: Dictionary, rate: float, deltas: Array
) -> bool:
	if world.resolve_player(reference) == null or not valid_controls(controls):
		return false
	if not is_finite(rate) or absf(rate) > 65536.0 or deltas.size() > 64:
		return false
	var aim: Array = []
	for delta: Variant in deltas:
		if not (delta is float or delta is int) or not is_finite(float(delta)):
			return false
		aim.append(roundi(fmod(float(delta), 16384.0) * 65536.0))
	if not world.vs_state.is_empty() and (world.vs_state.phase != "playing" or int(world.resolve_player(reference).fighter.state) != 1):
		return true  # Consume authenticated transport input without retaining a future edge.
	var state: Dictionary = world.admission_state
	if state.queue.size() >= 4096 or int(state.next_sequence) >= 0x7fffffffffffffff:
		return false
	@warning_ignore("integer_division")
	var ordinal: int = world.clock.tick_count + world.clock._phase / world.clock._threshold
	state.queue.append(
		{
			"player": reference.duplicate(),
			"ordinal": ordinal,
			"offset": world.clock._phase % world.clock._threshold,
			"sequence": state.next_sequence,
			"controls": controls.duplicate(true),
			"rate": rate,
			"aim": aim
		}
	)
	state.next_sequence += 1
	apply_due(world)
	return true


static func apply_due(world: RefCounted) -> void:
	var state: Dictionary = world.admission_state
	while not state.queue.is_empty() and int(state.queue.front().ordinal) <= world.clock.tick_count:
		var event: Dictionary = state.queue.pop_front()
		state.applied = event.sequence
		var player: RefCounted = world.resolve_player(event.player)
		if player == null or (not world.vs_state.is_empty() and (world.vs_state.phase != "playing" or int(player.fighter.state) != 1)):
			continue
		state.controls[player.handle] = event.controls
		state.rates[player.handle] = event.rate
		# Process every admitted native selection at its ordered boundary; wheel
		# presses cannot be overwritten by a later release before input sampling.
		player.select_native_weapon(int(event.controls.held))
		for delta: int in event.aim:
			Motion.aim(player.motion, float(delta) / 65536.0)


## Authority controllers run at an already committed fast boundary. Pending
## wall-clock debt must not timestamp their input in a later render partition.
static func bot_controls(world: RefCounted, reference: Dictionary, controls: Dictionary, rate: float) -> bool:
	var player: RefCounted = world.resolve_player(reference)
	if player==null or not world.bots.is_bot(reference) or not valid_controls(controls) or not is_finite(rate) or absf(rate)>65536.0: return false
	world.admission_state.controls[player.handle]=controls.duplicate()
	world.admission_state.rates[player.handle]=rate
	return true


static func controls(_index: int, owner: WeakRef, handle: int) -> Dictionary:
	var world: RefCounted = owner.get_ref()
	return world.admission_state.controls.get(handle, {"held": 0xffffffff, "strafe": 0})


static func rate(owner: WeakRef, handle: int) -> float:
	var world: RefCounted = owner.get_ref()
	return float(world.admission_state.rates.get(handle, 0.0))


static func valid_controls(value: Dictionary) -> bool:
	return (
		value.size() == 2
		and value.has_all(["held", "strafe"])
		and value.held is int
		and value.strafe is int
		and value.held >= 0
		and value.held <= 0xffffffff
		and value.strafe >= -1
		and value.strafe <= 1
	)
