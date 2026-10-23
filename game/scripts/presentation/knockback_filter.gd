extends RefCounted
## Presentation-only response to already committed damage. Exponential decay is
## measured in seconds, independent of frame rate. Queries never mutate gameplay.
const RESPONSE_SECONDS := 0.04
var _last := Vector2.ZERO
var _error := Vector2.ZERO
var _time := -1.0
var _identity: Array = []
var _active := false


func sample(pose: Dictionary, seconds: float, active: bool, identity: Array, query: Callable) -> Dictionary:
	var result := pose.duplicate()
	var current := Vector2(pose.x, pose.y)
	if _time < 0.0 or identity != _identity or seconds < _time or current.distance_to(_last) > 160.0:
		_error = Vector2.ZERO
	elif active or _active or not _error.is_zero_approx():
		if active or _active:
			_error -= current - _last
		_error *= exp(-maxf(0.0, seconds - _time) / RESPONSE_SECONDS)
		if _error.length() < 0.01:
			_error = Vector2.ZERO
	if _error.length() > 160.0:
		_error = Vector2.ZERO
	_last = current
	_time = seconds
	_identity = identity.duplicate(true)
	_active = active
	# A camera may trail along the committed path, never through a wall/corner.
	var target := current + _error
	var steps := ceili(_error.length() / 8.0)
	for index: int in range(1, steps + 1):
		var point := Vector2i(current.lerp(target, float(index) / steps).round())
		if query.call(point).blocked:
			_error = Vector2.ZERO
			target = current
			break
	result.x = target.x
	result.y = target.y
	return result


## An already confirmed impulse has a deterministic next displacement. Draw
## that collision-checked path throughout its world interval, rather than
## waiting for another coarse shove and easing the resulting position jump.
static func preview(pose: Dictionary, impulse: Dictionary, fraction: float, query: Callable) -> Dictionary:
	var result := pose.duplicate()
	if int(pose.get("state", 1)) not in [1, 3]:
		return result
	var start := {"x": int(pose.x), "y": int(pose.y), "impulse_x": int(impulse.get("impulse_x", 0)), "impulse_y": int(impulse.get("impulse_y", 0))}
	var path: Array = []
	preload("res://scripts/simulation/cd_player_impulse.gd").advance_native(start, 6, query, path)
	var phase := clampf(fraction, 0.0, 1.0) * float(path.size() - 1)
	var index := mini(int(phase), path.size() - 1)
	var next := mini(index + 1, path.size() - 1)
	var point := Vector2(path[index]).lerp(Vector2(path[next]), phase - float(index))
	result.x = float(pose.x) + point.x - float(start.x)
	result.y = float(pose.y) + point.y - float(start.y)
	return result
