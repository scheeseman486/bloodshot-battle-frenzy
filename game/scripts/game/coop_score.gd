extends RefCounted
## Native co-op competition. Original shared power-rating/reward rules are intact.
const FIELDS := [
	"damage",
	"kills",
	"taken",
	"deaths",
	"campaign_deaths",
	"reactor",
	"friendly",
	"doofus",
	"banked",
	"speedy",
	"slowpoke",
	"cremated"
]
const LIMIT := 2147483647
const REACTOR_BONUS := 500
const DOOFUS_PENALTY := 500
const FRENZY_BONUS := 1000
const SPEEDY_BONUS := 250
const SLOWPOKE_PENALTY := 100
const CREMATED_PENALTY := 500


static func initial() -> Dictionary:
	var result := {}
	for field: String in FIELDS:
		result[field] = 0
	return result


static func valid_stats(value: Variant) -> bool:
	if not value is Dictionary or value.size() != FIELDS.size() or not value.has_all(FIELDS):
		return false
	for field: String in FIELDS:
		if (
			not value[field] is int
			or value[field] < (-LIMIT if field == "banked" else 0)
			or value[field] > LIMIT
		):
			return false
	return (
		value.speedy <= 1
		and value.slowpoke <= 1
		and value.cremated <= 1
		and not (value.slowpoke == 1 and value.cremated == 1)
		and (value.speedy == 0 or value.reactor > 0)
		and value.doofus <= 1
		and value.campaign_deaths >= value.deaths
		and value.reactor <= value.damage
	)


static func bonuses(stats: Dictionary, reactor_max: int, lives: int, final: bool, companion: bool = false) -> Dictionary:
	return {
		"speedy": 0 if companion else SPEEDY_BONUS * int(stats.speedy),
		"slowpoke": -SLOWPOKE_PENALTY * int(stats.slowpoke),
		"cremated": -CREMATED_PENALTY * int(stats.cremated),
		"reactor": REACTOR_BONUS if not companion and reactor_max > 0 and stats.reactor == reactor_max else 0,
		"lives": lives * 100 if final and not companion else 0,
		"frenzy": FRENZY_BONUS if final and not companion and stats.campaign_deaths == 0 else 0,
		"friendly": -int(stats.friendly),
		"doofus": -DOOFUS_PENALTY * int(stats.doofus)
	}


static func points(stats: Dictionary, awards: Dictionary) -> int:
	var result := int(stats.damage) + 100 * int(stats.kills)
	for value: int in awards.values():
		result += value
	return result


static func rows(players: Array, final: bool = false) -> Array:
	var result := []
	var reactor_max := 0
	for player: RefCounted in players:
		if not player.level_stats.is_empty() and not player.world.bots.is_bot(player.player_ref()):
			reactor_max = maxi(reactor_max, int(player.level_stats.reactor))
	for player: RefCounted in players:
		if player.level_stats.is_empty():
			continue
		var awards := bonuses(
			player.level_stats, reactor_max, maxi(0, int(player.fighter.lives)), final, player.world.bots.is_bot(player.player_ref())
		)
		result.append(
			{
				"reference": player.player_ref(),
				"seat": player.seat,
				"stats": player.level_stats.duplicate(true),
				"lives": maxi(0, int(player.fighter.lives)),
				"bonuses": awards,
				"points": points(player.level_stats, awards),
				"total": int(player.level_stats.banked) + points(player.level_stats, awards),
				"rank": 0
			}
		)
		if player.world.bots.is_bot(player.player_ref()): result.back().controller="bot"
		if not player.public_name.is_empty(): result.back().name = player.public_name
	var order := "total" if final else "points"
	result.sort_custom(
		func(a, b): return a[order] > b[order] if a[order] != b[order] else a.seat < b.seat
	)
	for index: int in range(result.size()):
		result[index].rank = (
			result[index - 1].rank
			if index > 0 and result[index][order] == result[index - 1][order]
			else index + 1
		)
	return result


static func valid_rows(value: Variant, final: bool = false) -> bool:
	# Already frozen cards from older bot saves remain immutable historical
	# results. Accept a complete old-policy card, never mix policies per row.
	return _valid_rows(value, final, false) or _valid_rows(value, final, true)


static func _valid_rows(value: Variant, final: bool, legacy: bool) -> bool:
	if not value is Array or value.is_empty() or value.size() > 4:
		return false
	var reactor_max := 0
	for row: Variant in value:
		if (
			not row is Dictionary
			or row.size() != 8 + int(row.has("controller")) + int(row.has("name"))
			or not row.has_all(
				["reference", "seat", "stats", "lives", "bonuses", "points", "total", "rank"]
			)
		):
			return false
		if row.has("name") and not preload("res://scripts/network/network_settings.gd").valid_name(row.name): return false
		if row.has("controller") and row.controller not in ["human","bot"]: return false
		if not valid_stats(row.stats) or not row.lives is int or row.lives < 0 or row.lives > 32767:
			return false
		if legacy or row.get("controller", "human") != "bot":
			reactor_max = maxi(reactor_max, int(row.stats.reactor))
	var seats := []
	var identities := []
	var previous: Dictionary = {}
	var order := "total" if final else "points"
	var doofus_count := 0
	var speedy_count := 0
	var slowpoke_count := 0
	for index: int in range(value.size()):
		var row: Dictionary = value[index]
		if not row.seat is int or row.seat < 0 or row.seat > 3 or row.seat in seats:
			return false
		if (
			not row.reference is Dictionary
			or row.reference.size() != 2
			or not row.reference.has_all(["id", "generation"])
		):
			return false
		for field: String in ["id", "generation"]:
			if (
				not row.reference[field] is int
				or row.reference[field] < 1
				or row.reference[field] > 0xffffffff
			):
				return false
		if not row.bonuses is Dictionary:
			return false
		for award_value: Variant in row.bonuses.values():
			if not award_value is int:
				return false
		var awards := bonuses(row.stats, reactor_max, row.lives, final, not legacy and row.get("controller", "human") == "bot")
		if (
			row.reference.id in identities
			or not row.points is int
			or not row.total is int
			or row.total != int(row.stats.banked) + row.points
			or row.bonuses != awards
			or row.points != points(row.stats, awards)
			or not row.rank is int
		):
			return false
		var tied: bool = not previous.is_empty() and previous[order] == row[order]
		if row.rank != (previous.rank if tied else index + 1):
			return false
		if (
			not previous.is_empty()
			and (previous[order] < row[order] or (tied and previous.seat > row.seat))
		):
			return false
		doofus_count += row.stats.doofus
		if legacy or row.get("controller", "human") != "bot":
			speedy_count += row.stats.speedy
		slowpoke_count += row.stats.slowpoke
		seats.append(row.seat)
		identities.append(row.reference.id)
		previous = row
	return doofus_count <= 1 and speedy_count <= 1 and slowpoke_count <= 1


static func initial_world() -> Dictionary:
	return {"mine_claimed": false, "evacuation": {}}


static func valid_world(value: Variant) -> bool:
	if (
		not value is Dictionary
		or value.size() != 2
		or not value.has_all(["mine_claimed", "evacuation"])
	):
		return false
	if not value.mine_claimed is bool or not value.evacuation is Dictionary:
		return false
	var escape: Dictionary = value.evacuation
	if escape.is_empty():
		return true
	if (
		escape.size() != 4
		or not escape.has_all(["active", "eligible", "contributors", "arrivals"])
		or not escape.active is bool
	):
		return false
	for field: String in ["eligible", "contributors", "arrivals"]:
		if not escape[field] is Array or escape[field].size() > 4:
			return false
		var identities := []
		for reference: Variant in escape[field]:
			if (
				not reference is Dictionary
				or reference.size() != 2
				or not reference.has_all(["id", "generation"])
			):
				return false
			for key: String in ["id", "generation"]:
				if not reference[key] is int or reference[key] < 1 or reference[key] > 0xffffffff:
					return false
			if (
				reference.id in identities
				or (field != "eligible" and reference not in escape.eligible)
			):
				return false
			identities.append(reference.id)
	return true
