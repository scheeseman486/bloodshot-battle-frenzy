class_name CdGameClient
extends RefCounted
## Application view/input role. Only commands cross the authority boundary.
signal audio_requested(request: Dictionary)
signal world_updated
const Motion = preload("res://scripts/simulation/cd_responsive_motion.gd")
var _knockback_view := preload("res://scripts/presentation/knockback_filter.gd").new()
var _view_collision := preload("res://scripts/simulation/cd_collision_world.gd").new()
var session := preload("res://scripts/game/client_replica.gd").new()
var link: RefCounted
var reference: Dictionary
var epoch := 0
var revision := 0
var phase := 0.0
var animation_time := 0.0
var boundary_time := 0.0
var segments: Dictionary = {}
var _segment_source: Dictionary = {}
var _event_watermark := 0
var _last_update := -1
var _last_controls: Dictionary = {}
var _last_rate := 0.0
var events: Array = []
var _pending_aim := 0
# Optional remote view policy; offline stays on the immediate canonical motor.
var prediction: RefCounted


func command(controls: Dictionary, rate: float = 0.0, deltas: Array = []) -> bool:
	if controls == _last_controls and rate == _last_rate and deltas.is_empty():
		return true
	if not link.submit(controls, rate, deltas):
		return false
	_last_controls = controls.duplicate(true)
	_last_rate = rate
	return true


func receive(snapshot: Dictionary) -> void:
	if epoch != int(snapshot.epoch):
		epoch = snapshot.epoch
		_event_watermark = snapshot.watermark
		_last_update = -1
		events.clear()
	revision = snapshot.revision
	phase = snapshot.phase
	animation_time = snapshot.animation_time
	boundary_time = snapshot.boundary_time
	_pending_aim = snapshot.pending_aim
	if not is_same(_segment_source, snapshot.segments):
		segments = snapshot.segments.duplicate(true)
		_segment_source = snapshot.segments
	session.install(snapshot)
	if _last_update != session.update_count:
		_last_update = session.update_count
		world_updated.emit()


func receive_event(event: Dictionary) -> void:
	if event.epoch != epoch or int(event.sequence) <= _event_watermark:
		return
	_event_watermark = event.sequence
	if event.has("audience") and event.audience != reference:
		return
	events.append(event.duplicate(true))
	if events.size() > 256:
		events.pop_front()
	if event.category == "audio":
		audio_requested.emit(event.payload.duplicate(true))


func player_pose() -> Dictionary:
	if prediction != null and not prediction.motion.is_empty():
		return prediction.player_pose()
	var pose := Motion.pose(session.motion)
	if int(pose.state) in [1, 3]:
		pose.angle = fposmod(float(pose.angle) + float(_pending_aim) / 65536.0, 16384.0)
	return pose


## Offline camera shares the network knockback filter; aiming/gameplay still
## read player_pose(), so smoothing never delays damage or movement authority.
func presentation_pose() -> Dictionary:
	if prediction != null and not prediction.motion.is_empty():
		return prediction.presentation_pose()
	var pose := player_pose()
	_view_collision.level = session.level
	_view_collision.fractions = session.groups.map(func(group: Dictionary) -> int: return int(group.fraction))
	pose = preload("res://scripts/presentation/knockback_filter.gd").preview(
		pose, session.fighter, phase,
		func(point: Vector2i) -> Dictionary: return _view_collision.query(point),
		[session.level, _view_collision.fractions], _knockback_view.path_cache
	)
	return _knockback_view.sample(
		pose, animation_time * 1070460.0 / 53203424.0,
		int(session.fighter.impulse_x) != 0 or int(session.fighter.impulse_y) != 0,
		[epoch, reference, pose.state, session.demo_mode],
		func(point: Vector2i) -> Dictionary: return _view_collision.query(point)
	)
