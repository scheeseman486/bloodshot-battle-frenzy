class_name CdResponsiveDriver
extends "res://scripts/simulation/cd_prototype_driver.gd"
## Fast authoritative player motion; original input and combat clocks stay fixed.
## No prediction, rewind, rollback, resimulation or render-driven gameplay.
const Motion = preload("res://scripts/simulation/cd_responsive_motion.gd")
var _world_origin := Vector2i.ZERO
# Optional human look velocity in angle units/second. Recorded controllers leave
# this empty. Sampling on the fast rational clock keeps aim independent of FPS.
var aim_rate: Callable


func configure(
	gameplay: RefCounted,
	controls: Callable,
	visibility: Callable = Callable(),
	profile: Resource = DEFAULT_PROFILE
) -> bool:
	if not super.configure(gameplay, controls, visibility, profile):
		return false
	clock.configure_ratio(
		int(timing_profile.input_numerator) * Motion.SUBSTEPS, int(timing_profile.input_denominator)
	)
	_world_origin = Vector2i(session.motion.x, session.motion.y)
	if session.has_method("sync_world_origin"):
		session.sync_world_origin(_world_origin)
	return true


func advance_usec(elapsed: int, budget: int = 32) -> int:
	# The public budget remains in input periods, as in the reference driver.
	return clock.advance(elapsed, budget * Motion.SUBSTEPS)


func _sample(index: int) -> void:
	if session.has_method("begin_atomic"):
		session.begin_atomic()
	_sample_body(index)
	if session.has_method("end_atomic"):
		session.end_atomic()


func _sample_body(index: int) -> void:
	@warning_ignore("integer_division")
	var sample_index := index / Motion.SUBSTEPS
	if index % Motion.SUBSTEPS == 0:
		session.sample_controls(_admitted_controls(sample_index))
	if aim_rate.is_valid():
		var seconds := (
			float(timing_profile.input_denominator)
			/ (float(timing_profile.input_numerator) * Motion.SUBSTEPS)
		)
		aim_units(float(aim_rate.call()) * seconds)
	session.advance_responsive_motion(int(timing_profile.samples_per_update))
	if index % (Motion.SUBSTEPS * int(timing_profile.samples_per_update)) == 0:
		# Player has already moved to this boundary. Never move it a second time.
		# Blast direction reads the previous WORLD position, not a position from
		# the last 5ms player step. Fast steps cannot redefine this combat input.
		session.motion.prev_x = _world_origin.x
		session.motion.prev_y = _world_origin.y
		session.step(int(timing_profile.samples_per_update), _visibility, false)
		_world_origin = Vector2i(session.motion.x, session.motion.y)
		if session.has_method("sync_world_origin"):
			session.sync_world_origin(_world_origin)
		updated.emit()


func aim_units(delta: float) -> void:
	Motion.aim(session.motion, delta)


func player_pose() -> Dictionary:
	# Fast player state is already authoritative. Drawing its last substep
	# would add another ~5ms of latency to motion and damage knockback.
	return Motion.pose(session.motion)


## Fraction of the current world interval, for bounded forward motion paths.
## This reports time only; the driver never forecasts or commits future gameplay.
func world_phase() -> float:
	if timing_profile == null:
		return 0.0
	var period := Motion.SUBSTEPS * int(timing_profile.samples_per_update)
	return clampf((float(clock.tick_count % period) + clock.subtick_fraction()) / period, 0.0, 1.0)


## Retained for historical interpolation audits and source timing diagnostics.
func interpolation_fraction() -> float:
	return world_phase()


## PAL elapsed-time units for visual-only playback, not animation-entry count.
## Each ordinary source entry holds six of these units. Synchronization uses
## the exact current tick; drawing includes its fractional remainder. Keeping
## those separate prevents catch-up batches from timestamping every event late.
func animation_frame_time(include_fraction: bool = true) -> float:
	var fraction := clock.subtick_fraction() if include_fraction else 0.0
	return (float(clock.tick_count) + fraction) / Motion.SUBSTEPS


func sync_checkpoint_origin() -> void:
	_world_origin = session.player.world_origin
