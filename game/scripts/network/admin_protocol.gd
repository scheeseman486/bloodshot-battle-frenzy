extends RefCounted
## Small, uncompressed ASCII JSON grammar on its own encrypted ENet channel.
## No Variant/object decoder, console text, scripts, downloads or arbitrary paths.
const VERSION := 1
const CHANNEL := 5
const MAX_BYTES := 1000
const ACTIONS := [
	"status",
	"players",
	"bans",
	"slots",
	"mode",
	"map",
	"lobby",
	"limit",
	"rematch",
	"kick",
	"ban",
	"unban",
	"bot_count",
	"bot_difficulty",
	"bot_remove",
	"revive_bot",
	"save",
	"load"
]
const Bans = preload("res://scripts/network/player_bans.gd")


static func text(value: Variant, limit: int) -> bool:
	if not value is String or value.length() > limit:
		return false
	for index: int in range(value.length()):
		if value.unicode_at(index) < 32 or value.unicode_at(index) > 126:
			return false
	return true


static func pack(value: Dictionary) -> PackedByteArray:
	var result := JSON.stringify(value).to_ascii_buffer()
	return result if result.size() <= MAX_BYTES else PackedByteArray()


static func unpack(bytes: PackedByteArray) -> Dictionary:
	var value: Variant = preload("res://scripts/network/bounded_json.gd").decode(bytes, MAX_BYTES)
	return value if value is Dictionary else {}


static func whole(value: Variant, low: int = 0, high: int = 2147483647) -> bool:
	return (
		(value is int or value is float)
		and is_finite(value)
		and value >= low
		and value <= high
		and int(value) == value
	)


static func valid_reference(value: Variant) -> bool:
	return (
		value is Dictionary
		and value.size() == 2
		and value.has_all(["id", "generation"])
		and whole(value.id, 1)
		and whole(value.generation, 1)
	)


static func argument(action: String, value: Variant) -> bool:
	match action:
		"status", "players", "bans", "slots":
			return whole(value, 0, 171)  # paginated records
		"lobby", "rematch":
			return value == null
		"mode":
			return value is String and value in ["coop", "versus"]
		"map":
			if not value is String:
				return false
			return (
				value in ["lobby", "arena-1", "arena-2", "arena-3"]
				or value in range(1, 17).map(func(n): return "level-%d" % n)
			)
		"limit":
			return whole(value) and int(value) in [5, 10, 15, 20, 30, 50]
		"bot_count":
			return whole(value, 0, 3)
		"bot_difficulty":
			return whole(value, 0, 2)
		"save", "load":
			return whole(value, 1, 5)
		"kick", "ban", "bot_remove", "revive_bot":
			return valid_reference(value)
		"unban":
			return Bans.valid_key(value)
	return false


static func epoch(value: Variant) -> bool:
	return (
		value is String
		and value.length() <= 19
		and value.is_valid_int()
		and int(value) > 0
		and str(int(value)) == value
	)


static func request(value: Dictionary) -> bool:
	return (
		value.size() == 7
		and value.has_all(["v", "type", "session", "id", "epoch", "action", "value"])
		and whole(value.v, VERSION, VERSION)
		and value.type is String
		and value.type == "request"
		and Bans.valid_key(value.session)
		and whole(value.id, 1)
		and epoch(value.epoch)
		and value.action is String
		and value.action in ACTIONS
		and argument(value.action, value.value)
	)
