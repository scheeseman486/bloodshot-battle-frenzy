class_name CdEnemyRandom
extends RefCounted
## Original cumulative-byte random streams used by CD enemy aim/movement.

static func step(random_state: int) -> Dictionary:
	var sum := 0
	var next_seed := 0
	# $02F2E6, $02F306 and $02F3EA accumulate four big-endian seed bytes,
	# writing each partial sum back as a byte. Carry is discarded at each ADD.
	for shift: int in [24, 16, 8, 0]:
		sum = (sum + ((random_state >> shift) & 255)) & 255
		next_seed = (next_seed << 8) | sum
	return {"seed": next_seed, "value": sum - 256 if sum >= 128 else sum}
