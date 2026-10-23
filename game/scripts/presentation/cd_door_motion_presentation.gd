class_name CdDoorMotionPresentation
extends RefCounted
## Draw the committed motor command at render time. A first-step offset eases
## activation into this path; collision still consumes CdDoorRules unchanged.
const Doors = preload("res://scripts/simulation/cd_door_rules.gd")
var _groups: Array = []
var _time := 0.0
var _interval := 6.0
var _blocked: Array = []
var _opening_offsets: Dictionary = {}


func synchronize(groups: Array, time: float, interval: int, blocked: Array = []) -> void:
	if groups == _groups and time == _time and float(interval) == _interval and blocked == _blocked:
		return  # Repeated notification at the same boundary must retain its start offset.
	var opening_offsets: Dictionary = {}
	if time >= _time and groups.size() == _groups.size():
		for index: int in range(groups.size()):
			var before: Dictionary = _groups[index]
			var after: Dictionary = groups[index]
			if (
				int(before.state) == Doors.State.CLOSED
				and int(before.fraction) == 0
				and int(after.state) == Doors.State.OPENING
				and int(after.fraction) == Doors.OPEN_STEP
			):
				# Use/advance already committed the first source step. Start artwork
				# at closed and release this offset during one upcoming motor interval.
				opening_offsets[index] = -float(Doors.OPEN_STEP)
	_opening_offsets = opening_offsets
	_groups = groups.duplicate(true)
	_time = time
	_interval = maxf(float(interval), 1.0)
	_blocked = blocked.duplicate()


func sample(groups: Array, time: float, horizon: float = -1.0) -> Array:
	var result := groups.duplicate(true)
	if groups != _groups or time < _time:
		return result
	# The source adds 165 or subtracts 400 per dispatch, independently of elapsed.
	# Divide by this profile's interval, not by a single PAL period. Bound drawing
	# at the next obstruction/command decision even if the driver has clock debt.
	# Offline retains its next-boundary limit. A remote view may continue the
	# already committed motor through a bounded packet gap, without advancing a
	# door rule, opening a closed door or writing collision. New state/obstruction
	# always replaces this program immediately at synchronize().
	var elapsed := clampf(
		time - _time, 0.0, _interval if horizon < 0.0 else maxf(_interval, horizon)
	)
	for index: int in range(result.size()):
		var group: Dictionary = result[index]
		var velocity := 0.0
		if int(group.state) == Doors.State.OPENING:
			velocity = float(Doors.OPEN_STEP) / _interval
		elif int(group.state) == Doors.State.CLOSING and not _blocked.has(index):
			velocity = -float(Doors.CLOSE_STEP) / _interval
		if velocity == 0.0:
			continue
		var start_offset := float(_opening_offsets.get(index, 0.0))
		# Smoothstep gives zero correction velocity at both ends. The underlying
		# motor continues now; its next endpoint is reached without lasting lag.
		var remaining := 1.0 - smoothstep(0.0, _interval, elapsed)
		group.fraction = clampf(
			float(group.fraction) + velocity * elapsed + start_offset * remaining, 0.0, 4096.0
		)
	return result
