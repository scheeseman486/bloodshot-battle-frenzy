class_name CdActorAnimation
extends RefCounted
## Original $03A3E0..$03A45E frame hold, in PAL elapsed-time units.
const FRAME_PERIOD_TICKS := 6


## Frame data selection, sub-CPU $03A3E0..$03A45E. Cursor names the current
## frame entry; the actor update caller adds four before requesting the next one.
static func select(state: Dictionary, request: int, catalog: Resource) -> Dictionary:
	var result := state.duplicate(true)
	for guard: int in range(32):
		if request == 0:
			result.cursor = 0
			result.timer = 0
			return {"state": result, "deleted": false}
		assert(catalog.animations.has(request), "Invalid original animation data cursor")
		var value := int(catalog.animations[request])
		if value == 0:
			request = 0
		elif value == 0xffffffff:
			assert(catalog.animations.has(request + 4))
			request = int(catalog.animations[request + 4])
		elif value == 0xfffffffe:
			# $0335EE clears the whole actor record. Other fields, when present,
			# must also clear; target/seen use native -1 for source null pointers.
			for key: String in result:
				result[key] = -1 if key == "target" or key == "seen" else 0
			return {"state": result, "deleted": true}
		else:
			assert(catalog.frames.has(value), "Unknown original animation frame")
			result.frame = value
			result.cursor = request
			result.timer = FRAME_PERIOD_TICKS
			return {"state": result, "deleted": false}
	assert(false, "Animation data loop exceeds the validated bound")
	return {"state": result, "deleted": false}
