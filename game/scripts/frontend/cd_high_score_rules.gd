class_name CdHighScoreRules
extends RefCounted
## European CD score search $31ABC and initials dispatcher $31D32.
const CAPACITY := 7


static func qualification(rows: Array, level: int, power: int, cheated: bool = false) -> int:
	if cheated or level < 1 or level > 16:
		return -1
	for index: int in range(CAPACITY):
		if index >= rows.size():
			return index
		var row: Dictionary = rows[index]
		if (
			level > int(row.level)
			or (level == int(row.level) and _signed(power) > _signed(int(row.power)))
		):
			return index
	return -1


static func entry_action(edge: int) -> int:
	# Increment has priority over decrement, which has priority over A/B/C.
	if (edge & 9) != 9:
		return 1
	if (edge & 6) != 6:
		return -1
	return 2 if (edge & 0x70) != 0x70 else 0


static func letter(code: int, direction: int) -> int:
	return 65 + posmod(code - 65 + direction, 26)


static func _signed(value: int) -> int:
	return ((value + 0x80000000) & 0xffffffff) - 0x80000000
