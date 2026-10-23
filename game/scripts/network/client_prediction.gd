class_name CdClientPrediction
extends RefCounted
## Owning motor/weapon presentation only. Rebase a detached owner at an exact
## authority revision and replay a bounded recent input window, never World/AI.
const Motion = preload("res://scripts/simulation/cd_responsive_motion.gd")
const Keyboard = preload("res://scripts/input/cd_keyboard_controls.gd")
const Weapons = preload("res://scripts/simulation/cd_weapon_rules.gd")
const N := 53203424 * 4
const T := 1070460 * 1000000
const STEP_USEC := float(T) / N
const MAX_STEPS := 128
const CLOCK_RATE_LIMIT := 0.1
var _knockback_view := preload("res://scripts/presentation/knockback_filter.gd").new()
var definition: RefCounted
var base: Dictionary = {}
var motion: Dictionary = {}
var input_state: Dictionary = {}
var weapons: Dictionary = {}
var feedback := preload("res://scripts/network/predicted_feedback.gd").new()
var history: Array = []
var collisions: Array = []
var tick := 0
var phase := 0
var frozen := false
var needs_resync := false
var stats := {
	"reconciliations": 0,
	"corrections": 0,
	"max_correction": 0.0,
	"missing_history": 0,
	"max_replay": 0
}
var _motor := preload("res://scripts/game/player_motor.gd").new()
var _collision := preload("res://scripts/simulation/cd_collision_world.gd").new()
var _latch := preload("res://scripts/simulation/cd_controller_latch.gd").new()
var _cursor := 0
var _controls := {"held": 0xffffffff, "strafe": 0}
var _rate := 0.0
var _action := 0
var _shot_index := 0
var _requests: Array = []
var _available_slots := 0
var _clock_calibrated := false
var _clock_horizon := -1.0
var _last_state := -1
var _last_origin := Vector2i.ZERO
var _last_proxy := -1
var _fresh_usec := 0
var _camera_pending := 0
var _world_origin := Vector2i.ZERO
var _impulse: Dictionary = {}
# Rebuilt only on authority/input changes; fast advance consumes this ordered
# local plan once. These are presentation commands, never World/AI work.
var _replay_events: Array = []
var _replay_next := 0
var _base_slots := 0
# Camera-only continuity. Canonical prediction/reconciliation, collision and
# shots continue to use motion/player_pose(), with no delayed simulation state.
var _camera_error := Vector2.ZERO
var _camera_error_tick := 0.0
var _camera_collision := preload("res://scripts/simulation/cd_collision_world.gd").new()
var _camera_motor := preload("res://scripts/game/player_motor.gd").new()


func install(
	state: Dictionary, content: RefCounted, server_tick: float = -1.0, rtt_ms: float = 0.0
) -> void:
	if state.owner.is_empty():
		return
	var reset: bool = base.is_empty() or state.epoch != base.epoch or state.owner != base.owner
	if not reset:
		reset = state.get("versus", {}).get("phase", "") != base.get("versus", {}).get("phase", "")
	if not reset:
		reset = reset or (
			int(state.records.fighter.state) != _last_state
			or int(state.records.fighter.proxy) != _last_proxy
		)
		var delta := Vector2i(state.records.motion.x, state.records.motion.y) - _last_origin
		reset = reset or delta.length() > 320
	var previous: Dictionary = player_pose() if not motion.is_empty() else {}
	var previous_camera: Dictionary = _corrected_pose() if not motion.is_empty() else {}
	definition = content
	_collision.level = content.level
	base = state if state.is_read_only() else state.duplicate(true)
	_base_slots = 180 - state.records.actor_system.actors.size()
	for actor: Dictionary in state.records.actor_system.actors:
		if int(actor.kind) == 0:
			_base_slots += 1
	var applied: int = state.get("prediction", {}).get("applied", 0)
	if reset:
		history.clear()
		collisions.clear()
		feedback.reset()
		_clock_calibrated = false
		_clock_horizon = -1.0
		tick = int(state.revision)
		phase = int(state.clock.phase) % T
	else:
		history = history.filter(func(command): return int(command.sequence) > applied)
		tick = maxi(tick, int(state.revision))
	collisions.append(_collision_record(state))
	while collisions.size() > 32:
		collisions.pop_front()
	_last_state = int(state.records.fighter.state)
	_last_proxy = int(state.records.fighter.proxy)
	_last_origin = Vector2i(state.records.motion.x, state.records.motion.y)
	_fresh_usec = 0
	frozen = false
	needs_resync = false
	# Rebase and an accompanying server clock normally reconstruct the same
	# future twice. Calibrate first and replay once. Expired horizons retain the
	# original sequential freeze/recovery and cosmetic side effects.
	var combined := (
		server_tick >= 0
		and tick - int(base.revision) <= MAX_STEPS
		and _clock_target(server_tick, rtt_ms) - int(base.revision) <= MAX_STEPS
	)
	if combined:
		observe_clock(server_tick, rtt_ms, false)
	_rebuild()
	if server_tick >= 0 and not combined:
		observe_clock(server_tick, rtt_ms)
	_preserve_camera({} if reset else previous_camera)
	stats.reconciliations += 1
	if not reset and not previous.is_empty():
		var correction := (
			Vector2(float(motion.x) - float(previous.x), float(motion.y) - float(previous.y))
			. length()
		)
		if correction > 0.01:
			stats.corrections += 1
			stats.max_correction = maxf(float(stats.max_correction), correction)


func input(command: Dictionary) -> void:
	if _vs_stopped(): return
	if base.is_empty() or history.size() >= 512:
		needs_resync = true
		return
	var event := command.duplicate(true)
	event.tick = tick
	# The caller can append unsent mouse events to a packet with the same ID.
	# Keep event rounding/time individually; a received ACK retires the whole ID.
	if (
		not history.is_empty()
		and history.back().sequence == event.sequence
		and history.back().tick == event.tick
		and history.back().controls == event.controls
		and history.back().rate == event.rate
	):
		preload("res://scripts/network/rounded_aim.gd").append(history.back().aim, event.aim)
	else:
		history.append(event)
	# Aim sampled at the current predicted tick cannot change motor steps that
	# have already run. With no pending control edges, apply it immediately and
	# retain the command in history for the next authority reconciliation.
	if (
		not frozen
		and not needs_resync
		and _replay_next == _replay_events.size()
		and event.controls == _controls
		and event.rate == _rate
		and int(motion.state) in [1, 3]
		and int(base.records.actor_system.encounter.mode) == 2
	):
		_apply(event)
		return
	# A control edge may change the next fractional endpoint immediately. Keep
	# the position already shown, using the same bounded, collision-checked
	# correction as packet/clock reconciliation; canonical input remains exact.
	var previous_camera := _corrected_pose()
	_rebuild()
	_preserve_camera(previous_camera)


func observe_clock(server_tick: float, rtt_ms: float, rebuild: bool = true) -> void:
	if base.is_empty():
		return
	# Pong is stamped when the server receives the ping. One RTT beyond that
	# stamp is the owning prediction horizon (one half return, one half input).
	_clock_horizon = server_tick + rtt_ms * 1000.0 / STEP_USEC
	var target := _clock_target(server_tick, rtt_ms)
	if target > tick:
		var previous_camera := _corrected_pose() if rebuild else {}
		tick = target
		_clock_calibrated = true
		if rebuild:
			_rebuild()
			_preserve_camera(previous_camera)


func _clock_target(server_tick: float, rtt_ms: float) -> int:
	var desired := int(floor(server_tick + rtt_ms * 1000.0 / STEP_USEC))
	return (
		tick + mini(desired - tick, 8 if _clock_calibrated else MAX_STEPS)
		if desired > tick
		else tick
	)


func advance_usec(elapsed: int) -> void:
	if _vs_stopped(): return
	if elapsed < 0 or base.is_empty() or int(base.records.actor_system.encounter.mode) != 2:
		return
	_fresh_usec += elapsed
	var motion_elapsed := elapsed
	if _clock_horizon >= 0.0:
		_clock_horizon += float(elapsed) / STEP_USEC
		var ahead := float(tick) + float(phase) / T + float(elapsed) / STEP_USEC - _clock_horizon
		# Loading or an inflated RTT may have moved prediction too far ahead.
		# Let the measured horizon catch up by slewing only this private clock;
		# never rewind motor time, replay World or retime authoritative input.
		motion_elapsed -= clampi(
			roundi(ahead * STEP_USEC), 0, floori(float(elapsed) * CLOCK_RATE_LIMIT)
		)
	phase += motion_elapsed * N
	@warning_ignore("integer_division")
	var steps: int = phase / T
	phase %= T
	var previous_tick := tick
	tick += steps
	if tick - int(base.revision) > MAX_STEPS or _fresh_usec > 600000:
		_rebuild()  # Keep the same bounded freeze/recovery boundary.
	elif steps > 0:
		_replay(previous_tick + 1, tick)
	feedback.sample(float(tick) + float(phase) / T)


func player_pose() -> Dictionary:
	if motion.is_empty():
		return {}
	var pose := Motion.pose(motion)
	if int(pose.state) in [1, 3]:
		pose.angle = fposmod(float(pose.angle) + float(_camera_pending) / 65536.0, 16384.0)
	return pose


## High-refresh camera only: sample the next known local motor displacement.
## No input sampling, AI, weapon events, clock steps or canonical writes occur.
func presentation_pose() -> Dictionary:
	if _vs_stopped(): return player_pose()
	var pose := _corrected_pose()
	if pose.is_empty():
		return pose
	_camera_collision.level = definition.level
	_camera_collision.fractions = _fractions(_collision_view(tick + 1), tick + 1)
	_camera_collision.axis_remainder = null
	pose = preload("res://scripts/presentation/knockback_filter.gd").preview(
		pose, _impulse, (float(tick % 24) + float(phase) / T) / 24.0,
		func(point: Vector2i) -> Dictionary: return _camera_collision.query(point, _cursor)
	)
	return _knockback_view.sample(
		pose, (float(tick) + float(phase) / T) * STEP_USEC / 1000000.0,
		int(_impulse.get("impulse_x", 0)) != 0 or int(_impulse.get("impulse_y", 0)) != 0,
		[base.epoch, base.owner, pose.state, frozen],
		func(point: Vector2i) -> Dictionary: return _camera_collision.query(point, _cursor)
	)


func _corrected_pose() -> Dictionary:
	var pose := _continuous_pose()
	if (
		pose.is_empty()
		or frozen
		or int(pose.state) not in [1, 3]
		or int(base.records.actor_system.encounter.mode) != 2
	):
		return pose
	var age := maxf(0.0, float(tick) + float(phase) / T - _camera_error_tick)
	var error := _camera_error * maxf(0.0, 1.0 - age / 16.0)
	if error.is_zero_approx():
		return pose
	var target := Vector2(float(pose.x), float(pose.y)) + error
	_camera_collision.level = definition.level
	_camera_collision.fractions = _fractions(_collision_view(tick + 1), tick + 1)
	_camera_collision.axis_remainder = _collision.axis_remainder
	if _camera_collision.query(Vector2i(target), _cursor).blocked:
		return pose  # A corrected/closing wall is never smoothed through.
	var collision_view := _collision_view(tick + 1)
	for slot: int in collision_view.body_slots:
		if slot == int(base.records.fighter.proxy) or slot < int(definition.level.dynamic_start):
			continue
		var body: Dictionary = collision_view.actors[slot]
		if absf(target.x - float(body.x)) <= 105.0 and absf(target.y - float(body.y)) <= 105.0:
			return pose
	pose.x = target.x
	pose.y = target.y
	return pose


func _preserve_camera(previous: Dictionary) -> void:
	_camera_error = Vector2.ZERO
	if not previous.is_empty() and not frozen:
		var current := _continuous_pose()
		var error := Vector2(previous.x - current.x, previous.y - current.y)
		if (
			error.length() <= 32.0
			and int(base.records.fighter.impulse_x) == 0
			and int(base.records.fighter.impulse_y) == 0
		):
			_camera_error = error
	_camera_error_tick = float(tick) + float(phase) / T


func _continuous_pose() -> Dictionary:
	var pose := player_pose()
	if (
		pose.is_empty()
		or frozen
		or phase == 0
		or int(pose.state) not in [1, 3]
		or base.is_empty()
		or int(base.records.actor_system.encounter.mode) != 2
	):
		return pose
	# A fractional preview must meet the same next endpoint as _step. On an
	# input boundary that endpoint includes acceleration, release decay and the
	# diagonal cap. Using the old speeds overshoots and then snaps back at rest.
	var next_input := input_state
	if (tick + 1) % 4 == 0:
		next_input = input_state.duplicate()
		next_input.held = _controls.held
		next_input.edge = (int(_controls.held) | ~int(_latch.state.previous)) & 0xffffffff
		next_input = Keyboard.sample(
			next_input, int(_controls.strafe), int(base.continuation.scheme)
		)
	if (
		int(next_input.forward) == 0
		and int(next_input.strafe) == 0
		and int(next_input.turn) == 0
		and _rate == 0.0
	):
		return pose
	var view := _collision_view(tick + 1)
	_camera_collision.level = definition.level
	_camera_collision.fractions = _fractions(view, tick + 1)
	_camera_collision.axis_remainder = _collision.axis_remainder
	var future := motion.duplicate()
	Motion.aim(future, _rate * STEP_USEC / 1000000.0)
	var next: Dictionary = (
		_camera_motor
		. advance(
			future,
			next_input,
			definition.tables,
			6,
			_camera_collision,
			_cursor,
			view.actors,
			definition.catalog,
			int(base.records.fighter.proxy),
			int(definition.level.dynamic_start),
			view.body_slots
		)
		. motion
	)
	var endpoint := Motion.pose(next)
	var fraction := float(phase) / T
	for axis: String in ["x", "y"]:
		if absf(float(endpoint[axis]) - float(pose[axis])) <= 80.0:
			pose[axis] = lerpf(float(pose[axis]), float(endpoint[axis]), fraction)
	# Mouse deltas are already immediate in player_pose(); only the known held
	# angular velocity receives its fractional advance here.
	pose.angle = fposmod(
		(
			float(pose.angle)
			+ (_rate * STEP_USEC / 1000000.0 + float(next_input.turn) / 4.0) * fraction
		),
		16384.0
	)
	return pose


func _rebuild() -> void:
	if base.is_empty():
		return
	var start: int = base.revision
	if tick - start > MAX_STEPS or _fresh_usec > 600000:
		# No unsafe replay through missing dynamic geometry or an unbounded stall.
		tick = start
		phase = 0
		frozen = true
		needs_resync = true
		stats.missing_history += 1
	motion = base.records.motion.duplicate(true)
	input_state = base.records.input_state.duplicate(true)
	weapons = base.records.weapon_state.duplicate(true)
	_latch.state = base.continuation.latch.duplicate()
	_cursor = int(base.continuation.wall_cursor)
	_world_origin = base.continuation.world_origin
	_impulse = {
		"impulse_x": base.records.fighter.impulse_x, "impulse_y": base.records.fighter.impulse_y
	}
	_collision.axis_remainder = base.continuation.collision.axis_remainder
	var receipt: Dictionary = base.get("prediction", {})
	_available_slots = _base_slots
	_controls = receipt.get("controls", {"held": 0xffffffff, "strafe": 0}).duplicate()
	_rate = float(receipt.get("rate", 0.0))
	_action = int(receipt.get("action", 0))
	_shot_index = int(receipt.get("shot_index", 0))
	var events: Array = []
	var last_control_tick := start - 4
	var previous_controls := _controls.duplicate()
	var receipts := {}
	for accepted: Dictionary in receipt.get("receipts", []):
		receipts[accepted.sequence] = accepted.ordinal
		if accepted.sequence == int(receipt.get("applied", 0)):
			last_control_tick = int(accepted.ordinal)
	for command: Dictionary in history:
		var event: Dictionary = command.duplicate()
		if receipts.has(command.sequence):
			event.tick = receipts[command.sequence]
		event.tick = maxi(start, int(event.tick))
		if event.controls != previous_controls:
			event.tick = maxi(int(event.tick), last_control_tick + 4)
			last_control_tick = int(event.tick)
		previous_controls = event.controls.duplicate()
		events.append(event)
	events.sort_custom(
		func(a, b):
			return (
				int(a.tick) < int(b.tick) if a.tick != b.tick else int(a.sequence) < int(b.sequence)
			)
	)
	_replay_events = events
	_replay_next = 0
	_replay(start, tick)


func _replay(first: int, last: int) -> void:
	for ordinal: int in range(first, last + 1):
		if ordinal > int(base.revision) and not frozen:
			_step(ordinal)
		while (
			_replay_next < _replay_events.size()
			and int(_replay_events[_replay_next].tick) <= ordinal
		):
			_apply(_replay_events[_replay_next])
			_replay_next += 1
	_camera_pending = 0
	for index: int in range(_replay_next, _replay_events.size()):
		for delta: int in _replay_events[index].aim:
			_camera_pending += delta
	stats.max_replay = maxi(int(stats.max_replay), tick - int(base.revision))


func _apply(command: Dictionary) -> void:
	if _vs_stopped(): return
	if (int(command.controls.held) & 16) == 0 and (int(_controls.held) & 16) != 0:
		_action = int(command.sequence)
		_shot_index = 0
	_controls = command.controls.duplicate()
	_rate = float(command.rate)
	# Admission already rounds each event to 16.16 individually. Integer sums
	# preserve that rounding and modulo exactly; avoid dozens of float calls on
	# every replay. No inputs are omitted, retimed or folded before admission.
	var fixed_aim := 0
	for delta: int in command.aim:
		fixed_aim += delta
	if not command.aim.is_empty():
		Motion.aim_fixed(motion, fixed_aim)


func _step(ordinal: int) -> void:
	if _vs_stopped(): return
	if int(motion.state) not in [1, 3] or int(base.records.actor_system.encounter.mode) != 2:
		return
	if ordinal % 4 == 0:
		input_state.held = _controls.held
		input_state.edge = _latch.sample(int(_controls.held))
		input_state = Keyboard.sample(
			input_state, int(_controls.strafe), int(base.continuation.scheme)
		)
	Motion.aim(motion, _rate * STEP_USEC / 1000000.0)
	var view := _collision_view(ordinal)
	_collision.fractions = _fractions(view, ordinal)
	var result := _motor.advance(
		motion,
		input_state,
		definition.tables,
		6,
		_collision,
		_cursor,
		view.actors,
		definition.catalog,
		int(base.records.fighter.proxy),
		int(definition.level.dynamic_start),
		view.get("body_slots")
	)
	motion = result.motion
	_cursor = result.cursor
	if ordinal % 24 == 0:
		motion.prev_x = _world_origin.x
		motion.prev_y = _world_origin.y
		if int(motion.forward) == 0:
			motion.walk_phase = 0
		elif int(motion.forward) > 0:
			motion.walk_phase = 1 if int(motion.walk_phase) >= 8 else int(motion.walk_phase) + 1
		else:
			motion.walk_phase = 8 if int(motion.walk_phase) <= 1 else int(motion.walk_phase) - 1
		# Only an already committed impulse is extrapolated, at source cadence.
		var impulse := _impulse.duplicate()
		impulse.x = motion.x
		impulse.y = motion.y
		# Native locomotion and knockback use the same wall geometry context.
		_collision.axis_remainder = null
		impulse = preload("res://scripts/simulation/cd_player_impulse.gd").advance_native(
			impulse, 6, _query
		)
		motion.x = impulse.x
		motion.y = impulse.y
		_impulse = impulse
		_collision.axis_remainder = null
		_world_origin = Vector2i(motion.x, motion.y)
		var controls := _latch.consume()
		_requests = []
		weapons.state = motion.state
		var response := Weapons.advance(
			weapons,
			{
				"elapsed": 6,
				"held": controls.held,
				"edge": controls.edge,
				"special_kind": 24 if int(weapons.special) >= 0 else 0,
				"hit_flag": 64,
				"hit_target": -1,
				"demo": 0,
				"control_scheme": int(base.continuation.scheme),
				"resolution_mode": 1,
				"multiplayer": int(definition.level.get_meta("battle_mode", false))
			},
			definition.tables,
			_emit_cosmetic
		)
		weapons = response.state
		var sounds: Array = []
		for event: Dictionary in response.events:
			if event.kind == "sound":
				sounds.append(int(event.source_id))
		if not _requests.is_empty() or not sounds.is_empty():
			_shot_index += 1
			feedback.predict(
				{
					"epoch": base.epoch,
					"player": base.owner,
					"action": _action,
					"index": _shot_index
				},
				_selected_weapon(),
				_requests,
				sounds,
				motion,
				definition,
				ordinal,
				view.groups
			)
		weapons = Weapons.cycle(weapons, int(controls.edge)).state


func _selected_weapon() -> int:
	return int(weapons.inventory[int(weapons.selected)].kind) if int(weapons.selected) >= 0 else 0


func _emit_cosmetic(request: Dictionary) -> int:
	if _available_slots <= 0:
		return -1
	_available_slots -= 1
	_requests.append(request.duplicate(true))
	return 1  # Presentation handle only; never an authority entity/pool allocation.


static func _collision_record(snapshot: Dictionary) -> Dictionary:
	# This motor cache is distinct from complete replicated state/baselines.
	# Preserve slot order and every field read by PlayerMotor / _fractions,
	# without copying unrelated actor animation/combat fields 32 times.
	var body_slots := PackedInt32Array()
	for index: int in range(snapshot.records.actor_system.actors.size()):
		var kind: int = snapshot.records.actor_system.actors[index].kind
		if kind >= 1 and kind <= 22:
			body_slots.append(index)
	return {
		"body_slots": body_slots,
		"tick": snapshot.revision,
		"groups":
		snapshot.records.groups.map(
			func(group): return {"fraction": group.fraction, "state": group.state}
		),
		"actors":
		snapshot.records.actor_system.actors.map(
			func(actor): return {"kind": actor.kind, "x": actor.x, "y": actor.y}
		)
	}


func _collision_view(ordinal: int) -> Dictionary:
	# Replays normally run beyond the newest view. Search backwards, retaining
	# the same last-admitted view for duplicate revisions and the oldest fallback.
	for index: int in range(collisions.size() - 1, -1, -1):
		var view: Dictionary = collisions[index]
		if int(view.tick) <= ordinal:
			return view
	return collisions[0]


func _fractions(view: Dictionary, ordinal: int) -> Array:
	var result: Array = []
	for group: Dictionary in view.groups:
		var fraction := int(group.fraction)
		# Use committed geometry. A stale closing door gets its conservative
		# closed envelope; an opening prediction never becomes collision geometry.
		if ordinal >= int(view.tick) + 24 and int(group.state) == 3:
			fraction = 0
		result.append(fraction)
	return result


func _query(point: Vector2i) -> Dictionary:
	var contact: Dictionary = _collision.query(point, _cursor)
	_cursor = int(contact.cursor)
	return contact


func _vs_stopped() -> bool:
	return not base.get("versus", {}).is_empty() and base.versus.phase != "playing"
