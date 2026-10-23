class_name CdTextNoise
extends RefCounted
## MAINOS $FF1384..FF140A: masked 0/1/4/5 inks; zero is transparent.
## Hardware HV/boot-ROM entropy is supplied explicitly, independent of gameplay RNG.


static func word(original: int, previous: int, entropy: int, hv: int) -> int:
	if original == 0:
		return 0
	var result := (previous + entropy + hv) & 0x5555
	for shift: int in [0, 4, 8, 12]:
		if ((original >> shift) & 15) == 0:
			result &= ~(15 << shift)
	return result


static func generate(
	original: PackedByteArray, entropy: PackedByteArray, phase: int
) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(original.size())
	var accumulator := 0
	var entropy_at := 0
	for at: int in range(0, original.size(), 2):
		var mask := (int(original[at]) << 8) | int(original[at + 1])
		if mask == 0:
			accumulator = 0
		else:
			var seed := (
				(int(entropy[entropy_at % entropy.size()]) << 8)
				| int(entropy[(entropy_at + 1) % entropy.size()])
			)
			# Native deterministic substitute for the hardware HV counter. The
			# accumulation, zero-word reset and per-nibble masking are unchanged.
			var hv := (phase * 0x9e37 + entropy_at * 0x169) & 65535
			accumulator = word(mask, accumulator, seed, hv)
			entropy_at += 2
		result[at] = (accumulator >> 8) & 255
		result[at + 1] = accumulator & 255
	return result
