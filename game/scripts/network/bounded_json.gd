extends RefCounted
## Preflight byte/depth limits before the engine's primitive JSON parser. Quoted
## brackets and escaped quotes are data, never structural nesting or a bypass.


static func decode(
	bytes: PackedByteArray, maximum: int, depth_limit: int = 6, whitespace: bool = false
) -> Variant:
	if bytes.is_empty() or bytes.size() > maximum:
		return null
	var depth := 0
	var quoted := false
	var escaped := false
	for byte: int in bytes:
		if byte < 32 or byte > 126:
			if not whitespace or quoted or byte not in [9, 10, 13]:
				return null
		if quoted:
			if escaped:
				escaped = false
			elif byte == 92:
				escaped = true
			elif byte == 34:
				quoted = false
		elif byte == 34:
			quoted = true
		elif byte in [91, 123]:
			depth += 1
			if depth > depth_limit:
				return null
		elif byte in [93, 125]:
			depth -= 1
			if depth < 0:
				return null
	if quoted or depth != 0:
		return null
	return JSON.parse_string(bytes.get_string_from_ascii())
