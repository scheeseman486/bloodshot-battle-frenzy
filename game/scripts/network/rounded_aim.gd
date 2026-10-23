extends RefCounted
## Packing already-rounded impulses inside one unsent command preserves their
## exact modulo angle. It never merges held-state edges or rounds a raw sum.
const LIMIT := 48
const CYCLE := 16384 * 65536


static func append(target: Array, values: Array) -> void:
	for value: int in values:
		if target.size() < LIMIT:
			target.append(value)
		else:
			# Both operands are already 16.16. Normalize the exact integer sum
			# to a legal signed wire impulse without losing any source rounding.
			target[-1] = posmod(int(target[-1]) + value + CYCLE / 2, CYCLE) - CYCLE / 2
