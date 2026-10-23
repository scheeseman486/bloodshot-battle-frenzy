extends RefCounted
## Public live presentation, separate from frozen results and private inventory.
## VS counters live for one authority world epoch, never in campaign saves.
const Score = preload("res://scripts/game/coop_score.gd")
var kills: Dictionary = {}


func reset() -> void:
	kills.clear()


func record_kill(shooter: Dictionary, victim: Dictionary) -> void:
	if shooter == victim or shooter.is_empty() or victim.is_empty():
		return
	var key := _key(shooter)
	kills[key] = mini(Score.LIMIT, int(kills.get(key, 0)) + 1)


func project(players: Array, versus: bool, pings: Dictionary, host: Dictionary) -> Array:
	var result := []
	var retained := {}
	for player: RefCounted in players:
		var reference: Dictionary = player.player_ref()
		var key := _key(reference)
		if kills.has(key):
			retained[key] = kills[key]
		var points := int(kills.get(key, 0)) if versus else coop_total(player.level_stats, player.world!=null and player.world.bots.is_bot(reference))
		# Fixed seat colours are stable through respawn and shared with the HUD icons.
		result.append([int(reference.id), int(reference.generation), player.seat,
			player.seat, points, -3 if player.world!=null and player.world.bots.is_bot(reference) else (-2 if reference == host else int(pings.get(player.seat, -1)))])
	kills = retained
	return result


static func coop_total(stats: Dictionary, companion: bool = false) -> int:
	if stats.is_empty():
		return 0
	# A zero reactor maximum excludes the provisional leader award; final=false
	# excludes final lives/frenzy. Already settled evacuation/mine penalties remain.
	return int(stats.banked) + Score.points(stats, Score.bonuses(stats, 0, 0, false, companion))


static func _key(reference: Dictionary) -> String:
	return "%d:%d" % [int(reference.id), int(reference.generation)]


static func valid_rows(value: Variant) -> bool:
	if not value is Array or value.size() > 4:
		return false
	var identities := []
	var seats := []
	for row: Variant in value:
		if not row is Array or row.size() != 6:
			return false
		for field: Variant in row:
			if not field is int:
				return false
		if (row[0] < 1 or row[0] > 0xffffffff or row[1] < 1 or row[1] > 0xffffffff
			or row[2] < 0 or row[2] > 3 or row[3] != row[2]
			or row[4] < -(1 << 48) or row[4] > (1 << 48) or row[5] < -3 or row[5] > 60000):
			return false
		if row[0] in identities or row[2] in seats:
			return false
		identities.append(row[0])
		seats.append(row[2])
	return true
