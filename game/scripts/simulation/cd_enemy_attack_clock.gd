class_name CdEnemyAttackClock
extends RefCounted
## Distance-dependent attack eligibility, sub-CPU $02F250..$02F2C2.

static func advance(counter: int, kind: int, distance: int, scale: int, elapsed: int, attack_gate: int) -> Dictionary:
	var threshold := _word(distance + 1300)
	var accumulated := _word(counter * scale)
	# SUB.W followed by BGT is a signed comparison of its operands, including
	# the CPU overflow flag. Comparing a wrapped subtraction result with zero
	# would give the opposite answer for captured counters around 660.
	if threshold > accumulated:
		return {"counter": _word(counter + elapsed), "attempt": false}
	# Kind 4 can consume/reset the clock without requesting a projectile.
	# Allocation, aim, animation and actual damage are separate boundaries.
	return {"counter": 0, "attempt": kind != 4 or attack_gate == 0}


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
