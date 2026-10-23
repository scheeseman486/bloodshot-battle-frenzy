extends RefCounted
## Reversible presentation only. IDs survive local reconciliation; never run hit
## callbacks, grant rewards or write the canonical client's inventory/actor pool.
signal cue(request: Dictionary)
const Factory = preload("res://scripts/simulation/cd_projectile_factory.gd")
const VisualFlight = preload("res://scripts/network/projectile_visual_flight.gd")
var shots: Dictionary = {}
# Reordering may deliver confirmation/audio before the local legal boundary.
# Keep bounded receipts so that later presentation cannot duplicate that shot.
var _receipts: Dictionary = {}
var now_tick := 0
var stats := {"provisional": 0, "confirmed": 0, "rejected": 0, "duplicate_audio": 0}


func key(identity: Dictionary) -> String:
	return (
		"%d:%d:%d:%d:%d"
		% [
			identity.epoch,
			identity.player.id,
			identity.player.generation,
			identity.action,
			identity.index
		]
	)


func predict(
	identity: Dictionary,
	weapon: int,
	requests: Array,
	sounds: Array,
	motion: Dictionary,
	definition: RefCounted,
	tick: int,
	groups: Array
) -> void:
	var id := key(identity)
	if shots.has(id):
		return
	var actors: Array = []
	for request: Dictionary in requests:
		if request.kind != "projectile":
			continue
		var phase := ((int(motion.angle) >> 6) + int(request.get("spread", 0))) & 255
		var empty: Dictionary = {}
		# Factory overwrites the fields it uses; empty canonical scalar defaults
		# keep visual-only records compatible with the existing billboard presenter.
		for field: String in [
			"kind",
			"x",
			"y",
			"height",
			"frame",
			"cursor",
			"timer",
			"vx",
			"vy",
			"gravity",
			"wall_cursor",
			"parameter"
		]:
			empty[field] = 0
		var parameters: Dictionary = definition.tables.projectile_weapons[0x3a710 + weapon * 22]
		var actor: Dictionary = Factory.create(
			empty,
			{
				"x": motion.x,
				"y": motion.y,
				"height": 45,
				"dx": int(definition.tables.sine[phase]),
				"dy": int(definition.tables.cosine[phase]),
				"speed_offset": int(request.get("speed_offset", 0)),
				"owner": -2,
				"wall_cursor": 0
			},
			parameters,
			{
				"demo_flag": 0,
				"control_scheme": 1,
				"resolution": 1,
				"multiplayer": 0,
				"targeting_owner": 0
			}
		)
		actors.append({"program": VisualFlight.create(actor, groups, definition)})
	shots[id] = {
		"identity": identity.duplicate(true),
		"weapon": weapon,
		"tick": tick,
		"confirmed": false,
		"actors": actors,
		"entities": [],
		"sounds": sounds.duplicate(),
		"played": not sounds.is_empty()
	}
	stats.provisional += 1
	var heard: Array = _receipts.get(id, {}).get("heard", [])
	for source_id: int in sounds:
		if source_id not in heard:
			cue.emit({"kind": "sample", "source_id": source_id})
	if _receipts.has(id):
		var receipt: Dictionary = _receipts[id]
		if bool(receipt.get("confirmed", false)):
			confirm(identity, receipt.weapon, receipt.entities, receipt.ordinal)
		_receipts.erase(id)
	_trim()


func confirm(identity: Dictionary, weapon: int, entities: Array, ordinal: int = 0) -> void:
	var id := key(identity)
	if not shots.has(id):
		var receipt := _receipt(id)
		receipt.confirmed = true
		receipt.weapon = weapon
		receipt.entities = entities.duplicate(true)
		receipt.ordinal = ordinal
		return
	var shot: Dictionary = shots[id]
	if shot.weapon != weapon:
		shots.erase(id)
		stats.rejected += 1
		return
	if not shot.confirmed:
		stats.confirmed += 1
	shot.confirmed = true
	if entities.is_empty() and not shot.actors.is_empty():
		shot.actors.clear()
		stats.rejected += 1  # Authority pool/target decision rejected only the artwork.
	shot.entities = entities.duplicate(true)
	shot.server_tick = ordinal
	# Real authoritative projectiles replace these; no second projectile is born.
	# Keep provisional artwork until a matching authoritative entity is installed.


func authority_audio(identity: Dictionary, source_id: int) -> void:
	var receipt := _receipt(key(identity))
	if source_id not in receipt.heard:
		receipt.heard.append(source_id)


func _receipt(id: String) -> Dictionary:
	if not _receipts.has(id):
		_receipts[id] = {"tick": now_tick, "heard": [], "confirmed": false}
	while _receipts.size() > 64:
		_receipts.erase(_receipts.keys().front())
	return _receipts[id]


func suppress_audio(identity: Dictionary, source_id: int) -> bool:
	var shot: Dictionary = shots.get(key(identity), {})
	if not shot.is_empty() and shot.played and source_id in shot.sounds:
		stats.duplicate_audio += 1
		return true
	return false


func sample(tick: float, installed: Dictionary = {}) -> Array:
	now_tick = int(tick)
	for id: String in _receipts.keys():
		if now_tick - int(_receipts[id].tick) > 150:
			_receipts.erase(id)
	var result: Array = []
	for id: String in shots.keys():
		var shot: Dictionary = shots[id]
		if tick - float(shot.tick) > 150:
			if not shot.confirmed:
				stats.rejected += 1
			shots.erase(id)
			continue
		if shot.confirmed and not installed.is_empty():
			var present := true
			for entity: Array in shot.entities:
				var slot: int = entity[0]
				present = (
					present
					and slot < installed.records.actor_system.actors.size()
					and installed.records.actor_system.entity_generations[slot] == entity[1]
				)
			if present:
				shot.actors.clear()
				continue
		# Keep known private flight visible across the input/confirmation round trip.
		# Original wall/gravity rules bound contact; no hit/explosion is invented.
		for item: Dictionary in shot.actors:
			var actor: Dictionary = VisualFlight.sample(item.program, tick - float(shot.tick))
			if not actor.is_empty():
				result.append(actor)
	return result


func reset() -> void:
	shots.clear()
	_receipts.clear()


func _trim() -> void:
	while shots.size() > 64:
		shots.erase(shots.keys().front())


func attach_confirmed(
	shown: Array, installed: Dictionary, definition: RefCounted, server_tick: float
) -> void:
	for shot: Dictionary in shots.values():
		if not shot.confirmed or not shot.has("server_tick"):
			continue
		for entity: Array in shot.entities:
			var slot: int = entity[0]
			var system: Dictionary = installed.records.actor_system
			if (
				slot >= system.actors.size()
				or system.entity_generations[slot] != entity[1]
				or int(system.actors[slot].kind) not in [24, 25, 26, 27, 28]
			):
				continue
			var source: Dictionary = system.actors[slot]
			var start: float = shot.server_tick
			var segment: Dictionary = installed.segments.get(slot, {})
			if not segment.is_empty() and segment.source == source:
				start = float(segment.start)
			var cache: Dictionary = shot.get("authority_programs", {})
			shot.authority_programs = cache
			var entry: Dictionary = cache.get(slot, {})
			if (
				entry.is_empty()
				or entry.source != source
				or entry.groups != installed.records.groups
				or entry.start != start
			):
				entry = {
					"source": source,
					"groups": installed.records.groups,
					"start": start,
					"program": VisualFlight.create(source, installed.records.groups, definition)
				}
				cache[slot] = entry
			var actor: Dictionary = VisualFlight.sample(entry.program, server_tick - start)
			if not actor.is_empty():
				shown[slot] = actor
