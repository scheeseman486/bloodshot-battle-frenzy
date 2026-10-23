class_name CdDemoDriver
extends "res://scripts/simulation/cd_prototype_driver.gd"
## Recorded CD inputs count WORLD calls, not video frames. UI/audio presentation
## keeps its independent PAL clock; the accepted native six-sample policy remains.
const Playback = preload("res://scripts/frontend/cd_demo_playback.gd")
const Motion = preload("res://scripts/simulation/cd_responsive_motion.gd")
var recording: Dictionary
var reader: Dictionary:
	get:
		return session.world.demo_state.reader
	set(value):
		session.world.demo_state.reader = value
var action_cursor: int:
	get:
		return int(session.world.demo_state.action_cursor)
	set(value):
		session.world.demo_state.action_cursor = value
var world_calls: int:
	get:
		return int(session.world.demo_state.world_calls)
	set(value):
		session.world.demo_state.world_calls = value
var finished: bool:
	get:
		return bool(session.world.demo_state.finished)
	set(value):
		session.world.demo_state.finished = value


func configure(
	gameplay: RefCounted,
	controls: Callable,
	visibility: Callable = Callable(),
	profile: Resource = DEFAULT_PROFILE
) -> bool:
	assert(int(recording.level) == 11, "Co-op recordings are deferred until multiplayer is rebuilt")
	if not super.configure(gameplay, controls, visibility, profile):
		return false
	session.world.demo_recording = recording
	session.world.demo_state = {
		"pointer": int(recording.pointer),
		"reader": {"cursor": 0, "remaining": 0, "held": 0, "edge": 0},
		"action_cursor": 0,
		"world_calls": 0,
		"finished": false
	}
	session.fighter.grace = 20
	session.fighter.map_timer = 150
	return true


func _sample(index: int) -> void:
	if session.has_method("begin_atomic"):
		session.begin_atomic()
	_sample_body(index)
	if session.has_method("end_atomic"):
		session.end_atomic()


func _sample_body(index: int) -> void:
	var before: int = session.update_count
	preload("res://scripts/frontend/cd_demo_continuation.gd").advance(
		session.world, index, {session.player.id: _visibility}
	)
	if session.update_count != before:
		updated.emit()


func player_pose() -> Dictionary:
	return Motion.pose(session.motion)


func world_phase() -> float:
	return interpolation_fraction()


func animation_frame_time(include_fraction: bool = true) -> float:
	return float(clock.tick_count) + (clock.subtick_fraction() if include_fraction else 0.0)
