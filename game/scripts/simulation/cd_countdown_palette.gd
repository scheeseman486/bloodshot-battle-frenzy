class_name CdCountdownPalette
extends RefCounted
## Original input-clock palette state, $00C168..$00C32A. Normal level palette is
## bank 0; SHELL's two countdown banks are 1 and 2. It freezes outside countdown.


static func advance(state: Dictionary, active: bool, expired: bool = false) -> Dictionary:
	var result := state.duplicate(true)
	if not active:
		return result
	var phase := int(state.phase)
	if phase == 0:
		result.bank = 1
	elif phase == 80:
		result.bank = 2
	elif phase == 100:
		phase = -1
	result.phase = phase + 1
	if expired:
		result.bank = 0
	return result
