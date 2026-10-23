@tool
class_name Rnc2Decoder
extends RefCounted
## Bounded RNC method-2 byte/bit stream decoder for original CD slide records.
## CRC-16 validates both compressed and expanded spans. Overlapping references
## copy forward, as required by the format. Invalid input produces no resource.
var _bytes := PackedByteArray()
var _at := 0
var _bits := 0
var _left := 0
var _valid := true


static func crc16(bytes: PackedByteArray) -> int:
	var crc := 0
	for value: int in bytes:
		crc ^= value
		for bit: int in range(8):
			crc = (crc >> 1) ^ (0xa001 if (crc & 1) != 0 else 0)
	return crc


func decode(data: PackedByteArray, offset: int = 0) -> PackedByteArray:
	if (
		offset < 0
		or offset + 18 > data.size()
		or data.slice(offset, offset + 4) != PackedByteArray([82, 78, 67, 2])
	):
		return PackedByteArray()
	var size := _u32(data, offset + 4)
	var packed := _u32(data, offset + 8)
	if size <= 0 or size > 131072 or packed <= 0 or offset + 18 + packed > data.size():
		return PackedByteArray()
	_bytes = data.slice(offset + 18, offset + 18 + packed)
	if crc16(_bytes) != _u16(data, offset + 14):
		return PackedByteArray()
	_at = 0
	_left = 0
	_valid = true
	_number(2)
	var output := PackedByteArray()
	var ended := false
	for command: int in range(size * 8 + 1024):
		if not _valid or output.size() > size:
			break
		if _bit() == 0:
			output.append(_byte())
			continue
		var length := 0
		var high := 0
		var has_high := true
		if _bit() == 0:
			length = 4 + _bit()
			if _bit() != 0:
				length = (length - 1) * 2 + _bit()
				if length == 9:
					var count := (_number(4) + 3) * 4
					if output.size() + count > size:
						break
					for literal: int in range(count):
						output.append(_byte())
					continue
		elif _bit() == 0:
			length = 2
			has_high = false
		elif _bit() == 0:
			length = 3
		else:
			length = _byte()
			if length == 0:
				if _bit() != 0:
					continue
				ended = true
				break
			length += 8
		if has_high and _bit() != 0:
			high = _bit()
			if _bit() != 0:
				high = (high * 2 + _bit()) | 4
				if _bit() == 0:
					high = high * 2 + _bit()
			elif high == 0:
				high = 2 + _bit()
		var distance := high * 256 + _byte() + 1
		if distance > output.size() or output.size() + length > size:
			break
		for copy: int in range(length):
			output.append(output[output.size() - distance])
	if not ended or not _valid or output.size() != size or crc16(output) != _u16(data, offset + 12):
		return PackedByteArray()
	return output


func _byte() -> int:
	if _at >= _bytes.size():
		_valid = false
		return 0
	var value := int(_bytes[_at])
	_at += 1
	return value


func _bit() -> int:
	if _left == 0:
		_bits = _byte()
		_left = 8
	_left -= 1
	return (_bits >> _left) & 1


func _number(count: int) -> int:
	var result := 0
	for bit: int in range(count):
		result = result * 2 + _bit()
	return result


static func _u16(data: PackedByteArray, at: int) -> int:
	return (int(data[at]) << 8) | int(data[at + 1])


static func _u32(data: PackedByteArray, at: int) -> int:
	return (_u16(data, at) << 16) | _u16(data, at + 2)
