class_name NativeBootDisclaimer
extends RefCounted
## Owner-requested native notice, replacing only the SEGA startup image.
const NOTICE := "This port is not licensed by SEGA, Acclaim or Domark."
const LINES := [
	"Bloodshot - Battle Frenzy",
	"Headache Edition",
	"This port is not licensed by",
	"SEGA, Acclaim or Domark."
]
const ROWS := [0, 1, 3, 4]


static func measure(catalog: RefCounted, text: String) -> float:
	var width := 0.0
	for index: int in range(text.length()):
		width += catalog.advance(text.unicode_at(index))
	return width


static func layout(catalog: RefCounted) -> Array[Dictionary]:
	var lines: Array[Dictionary] = []
	# A five-row block, including the blank row, centered in the 224px source frame.
	for index: int in range(LINES.size()):
		var width := measure(catalog, LINES[index])
		lines.append(
			{
				"text": LINES[index],
				"x": (256.0 - width) * 0.5,
				"baseline": 90.0 + ROWS[index] * 12.0,
				"width": width,
				"color": Color.RED if index == 1 else Color.WHITE
			}
		)
	return lines
