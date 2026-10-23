extends RefCounted
## Host-private, bounded session ledger. Client payloads never supply counters.
const Score = preload("res://scripts/game/coop_score.gd")
const Live = preload("res://scripts/game/live_score_tally.gd")
const Versus = preload("res://scripts/game/vs_match.gd")
const CAPACITY := 64
var records: Dictionary = {}
var attached: Dictionary = {}
var campaign := 1
var level := ""


func world_changed(world: RefCounted) -> void:
	attached.clear()
	var path: String = world.level.source_path
	if path.begins_with("/LEVEL") and not level.is_empty() and not level.begins_with("/LEVEL"):
		campaign += 1  # Explicitly starting another campaign resets old totals.
	level = path


func remember(world: RefCounted, reference: Dictionary, principal: Dictionary, frozen: Array = []) -> void:
	if principal.is_empty(): return
	var player: RefCounted = world.resolve_player(reference)
	if player == null: return
	attached.erase(_reference_key(reference))
	var previous: Dictionary = records.get(principal.key, {})
	var record := {"epoch": world.actor_system.epoch, "level": world.level.source_path,
		"campaign": campaign, "stats": player.level_stats.duplicate(true), "versus": {}}
	for result: Dictionary in frozen:
		if result.reference == reference: record.settled_total = int(result.total)
	if not record.has("settled_total") and previous.get("epoch", -1) == record.epoch and previous.has("settled_total") and not frozen.is_empty():
		record.settled_total = previous.settled_total
	if not world.vs_state.is_empty(): record.versus = Versus.row(world, player.handle).duplicate(true)
	# A lobby has no contribution ledger. Preserve the previous campaign record
	# until a new campaign is explicitly selected; never retain an avatar/slot.
	if record.stats.is_empty() and record.versus.is_empty() and not previous.is_empty(): return
	records.erase(principal.key)
	records[principal.key] = record
	while records.size() > CAPACITY: records.erase(records.keys().front())


func attach(world: RefCounted, player: RefCounted, principal: Dictionary, restore: bool) -> void:
	if principal.is_empty(): return
	attached[_reference_key(player.player_ref())] = principal.key
	player.public_name = principal.name
	var current := Versus.row(world, player.handle)
	if not current.is_empty() and not player.public_name.is_empty(): current.name = player.public_name
	var record: Dictionary = records.get(principal.key, {}) if restore else {}
	if record.is_empty(): return
	if not current.is_empty():
		if record.epoch != world.actor_system.epoch or record.versus.is_empty() or world.vs_state.phase == "results": return
		for field: String in ["kills", "deaths", "suicides", "awards"]: current[field] = record.versus[field]
		current.streak = 0
		# Replace the inactive incarnation; a reconnect must not duplicate standings.
		var old: Dictionary = record.versus.reference
		world.vs_state.rows = world.vs_state.rows.filter(func(row): return row.reference != old)
	elif not player.level_stats.is_empty() and not record.stats.is_empty() and record.campaign == campaign:
		if record.epoch == world.actor_system.epoch:
			player.level_stats = record.stats.duplicate(true)
		else:
			# A same-map replacement/retry never banks a failed attempt's points.
			player.level_stats.banked = clampi(int(record.stats.banked) if record.level == world.level.source_path else int(record.get("settled_total", Live.coop_total(record.stats))), -Score.LIMIT, Score.LIMIT)
			player.level_stats.campaign_deaths = int(record.stats.campaign_deaths)


func carry_score(world: RefCounted, reference: Dictionary, previous: int) -> int:
	var record: Dictionary = records.get(attached.get(_reference_key(reference), ""), {})
	if record.get("epoch", -1) == world.actor_system.epoch and record.has("settled_total"):
		return clampi(int(record.settled_total), -Score.LIMIT, Score.LIMIT)
	return previous


func reset_campaign() -> void:
	records.clear()
	attached.clear()
	campaign += 1


func retry(world: RefCounted) -> void:
	for record: Dictionary in records.values():
		if record.campaign != campaign or record.stats.is_empty(): continue
		var stats := Score.initial()
		stats.banked = record.stats.banked
		stats.campaign_deaths = record.stats.campaign_deaths
		record.stats = stats
		record.level = world.level.source_path
		record.erase("settled_total")


static func _reference_key(reference: Dictionary) -> String:
	return "%d:%d" % [int(reference.id), int(reference.generation)]
