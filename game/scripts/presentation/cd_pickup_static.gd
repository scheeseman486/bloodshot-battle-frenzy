@tool
class_name CdPickupStatic
extends RefCounted
## Visual-only translation of CD $00C58A. Original entropy words remain on media.
const Data = preload("res://scripts/assets/cd_level_decoder.gd")
const ENTROPY_OFFSET := 0x403a
const ENTROPY_SIZE := 318


static func half(shell: PackedByteArray, offset: int, timers: Array) -> PackedByteArray:
	var result := PackedByteArray()
	if (
		shell.size() < ENTROPY_OFFSET + ENTROPY_SIZE
		or offset < 0
		or offset > 254
		or offset % 2 != 0
		or timers.size() != 32
	):
		return result
	result.resize(64)
	var accumulator := offset
	for index: int in range(32):
		accumulator = (
			(
				accumulator
				+ Data._u16(shell, ENTROPY_OFFSET + offset + index * 2)
				+ int(timers[index])
			)
			& 0xffff
		)
		var word := (accumulator & 0x2222) * 3
		result[index * 2] = word >> 8
		result[index * 2 + 1] = word & 255
	return result


## Source noise depends on instruction timing and a free-running 12-bit CD
## stopwatch. Native presentation has no console CPU: derive its visual entropy
## from elapsed PAL periods instead, without sharing or advancing gameplay RNG.
## 50 MHz / 1536 is the original stopwatch rate; the inner loop costs 58
## sub-CPU cycles (384 cycles per stopwatch count). Both halves share this phase.
static func parameters(time: float) -> Array[Dictionary]:
	var period := maxi(int(floor(time)), 0)
	var seconds := float(period) * (313.0 * 3420.0) / 53203424.0
	var timer := int(floor(seconds * 50000000.0 / 1536.0))
	var result: Array[Dictionary] = []
	for side: int in range(2):
		var initial := (timer + side * 13) & 0xfff
		# The source's incoming D2 is caller scratch, not a stored random seed.
		# A stable phase supplies the native equivalent and supports skipped frames.
		var offset := (initial + period) & 0xfe
		var timers: Array[int] = []
		for index: int in range(32):
			timers.append((timer + side * 13 + int(floor(float(index * 58) / 384.0))) & 0xfff)
		result.append({"offset": offset, "timers": timers})
	return result
