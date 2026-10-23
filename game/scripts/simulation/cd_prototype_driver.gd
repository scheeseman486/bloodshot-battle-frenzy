class_name CdPrototypeDriver
extends RefCounted
## Deterministic native driver using an explicit normalized CD timing profile.
## The stock campaign has variable cadence; its recorded schedules remain a
## separate oracle. Reference rendering costs never control this native clock.
const Clock = preload("res://scripts/simulation/reference_clock.gd")
const INPUT_NUMERATOR := 53203424
const INPUT_DENOMINATOR := 313 * 3420
const DEFAULT_PROFILE = preload("res://resources/simulation/cd_logical_six.tres")
signal updated

var clock := Clock.new()
var session: RefCounted
var _controls: Callable
var _visibility: Callable
var timing_profile: Resource


func configure(
	gameplay: RefCounted,
	controls: Callable,
	visibility: Callable = Callable(),
	profile: Resource = DEFAULT_PROFILE
) -> bool:
	if profile == null or not profile.is_valid():
		return false
	timing_profile = profile.duplicate(true)
	session = gameplay
	_controls = controls
	_visibility = visibility
	clock.configure_ratio(
		int(timing_profile.input_numerator), int(timing_profile.input_denominator)
	)
	if not clock.tick.is_connected(_sample):
		clock.tick.connect(_sample)
	if session.has_method("bind_driver_clock"):
		session.bind_driver_clock(clock, timing_profile)
	return true


func advance_usec(elapsed: int, budget: int = 32) -> int:
	return clock.advance(elapsed, budget)


func _sample(index: int) -> void:
	if session.has_method("begin_atomic"):
		session.begin_atomic()
	_sample_body(index)
	if session.has_method("end_atomic"):
		session.end_atomic()


func _sample_body(index: int) -> void:
	if timing_profile == null:
		# Preserve a live editor session when this field is added by hot reload.
		timing_profile = DEFAULT_PROFILE.duplicate(true)
	session.sample_controls(_admitted_controls(index))
	if index % int(timing_profile.samples_per_update) == 0:
		session.step(int(timing_profile.samples_per_update), _visibility)
		updated.emit()


## Fraction between the two latest world states. Presentation reads it without
## advancing simulation, consuming RNG or writing collision/AI state.
func interpolation_fraction() -> float:
	if timing_profile == null:
		return 0.0
	var period := int(timing_profile.samples_per_update)
	return clampf((float(clock.tick_count % period) + clock.subtick_fraction()) / period, 0.0, 1.0)


func attach_checkpoint(
	gameplay: RefCounted, controls: Callable, visibility: Callable = Callable()
) -> bool:
	# Unlike configure(), attachment never resets restored time, latches or state.
	session = gameplay
	_controls = controls
	_visibility = visibility
	clock = session.world.clock
	timing_profile = session.world.timing_profile
	session.bind_driver_clock(clock, timing_profile)
	if not clock.tick.is_connected(_sample):
		clock.tick.connect(_sample)
	if has_method("sync_checkpoint_origin"):
		call("sync_checkpoint_origin")
	return true


func _admitted_controls(index: int) -> Variant:
	if (
		session.has_method("begin_atomic")
		and session.world.accepted_controls.has(session.player.handle)
	):
		return session.world.accepted_controls[session.player.handle]
	return _controls.call(index)
