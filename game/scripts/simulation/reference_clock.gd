class_name ReferenceClock
extends RefCounted
## Integer timebase for deterministic behaviour tests. Tick rate must be supplied
## by a measured reference profile. Presentation FPS never controls simulation.

signal tick(index: int)

var tick_count: int = 0
var _numerator: int = 0
var _threshold: int = 1000000
var _phase: int = 0

func configure_ratio(numerator: int, denominator: int) -> bool:
	if numerator <= 0 or denominator <= 0 or numerator > denominator * 1000:
		return false
	_numerator = numerator
	_threshold = denominator * 1000000
	_phase = 0
	tick_count = 0
	return true


func configure(hz: int) -> bool:
	return configure_ratio(hz, 1)


func advance(elapsed_usec: int, budget: int = 8) -> int:
	if _numerator == 0 or elapsed_usec < 0 or budget < 0:
		return 0
	# Accumulate rational tick units: 60Hz does not require rounded 16667us steps.
	_phase += elapsed_usec * _numerator
	var executed: int = 0
	while _phase >= _threshold and executed < budget:
		_phase -= _threshold
		tick_count += 1
		executed += 1
		tick.emit(tick_count)
	# Unexecuted ticks remain in _phase; a slow render frame never loses AI work.
	return executed


func subtick_fraction() -> float:
	return clampf(float(_phase) / float(_threshold), 0.0, 1.0)
