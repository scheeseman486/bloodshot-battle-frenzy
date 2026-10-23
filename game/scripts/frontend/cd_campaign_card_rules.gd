class_name CdCampaignCardRules
extends RefCounted
## European CD card wait $315FA..3166E and post-game tally $3193A..31952.


static func ready(clock: int, deadline: int, edge: int, writing: bool) -> bool:
	# A/B/C/Start skip immediately, including while writing. The deadline starts
	# when the page is queued; writing can extend it, rather than restart it.
	return (edge & 0xf0) != 0xf0 or (not writing and _word(clock) >= _word(deadline))


static func power_rating(tally: int) -> int:
	tally &= 0xffffffff
	if tally >= 0x80000000:
		return 0
	@warning_ignore("integer_division")
	var quotient := tally / 25
	# DIVS.W leaves D0 unchanged on quotient overflow. MULS.W then uses its
	# original low word; this is observable in the CD's final rating routine.
	return (_word(tally if quotient > 32767 else quotient) * 5) & 0xffffffff


static func destination(level: int) -> String:
	assert(level >= 1 and level <= 16)
	return "ending" if level == 16 else "interlevel"


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
