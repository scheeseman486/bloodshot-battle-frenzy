class_name CdSnapshotCodec
extends RefCounted
## Public projection and recursive changed-field patches. Omission is unchanged;
## removal is explicit. Actor slots (including vacant slots) and generations stay
## complete. No interest filtering, hidden enemy decisions, RNG or asset bytes.
const Wire = preload("res://scripts/network/value_codec.gd")
const Schema = preload("res://scripts/persistence/checkpoint_schema.gd")
const MAX_RAW := 1024 * 1024
var last_error := ""
# Local reviewed schema/range cache; never part of replicated or saved state.
var _validation_schema := Schema.new()
var _actor_rules: Dictionary = {}


func manifest(definition: RefCounted) -> Dictionary:
	return {
		"protocol": 16 if definition.get_meta("session_flow", false) else 6,
		"input_compression":
		int(preload("res://scripts/network/command_codec.gd").compression_available()),
		"schema": 4,
		"rules": "europe-cd-native-six-responsive-v1",
		"edition": "European Mega CD",
		"shell": definition.tables.source_sha256,
		"level": definition.level.source_path,
		"level_sha256": definition.level.source_sha256,
		"timing": "europe-cd-logical-six-v1"
	}


func project(
	server: RefCounted, reference: Dictionary = {}, share_frozen: bool = false
) -> Dictionary:
	var player: RefCounted = server.world.resolve_player(reference)
	# Internal transport may share the recursively frozen authority view. Public
	# callers retain the historical fully writable, detached projection contract.
	var result: Dictionary = server.snapshot(player).duplicate(not share_frozen)
	if share_frozen:
		result.segments = result.segments.duplicate()
	for slot: int in result.segments:
		var segment: Dictionary = result.segments[slot].duplicate()
		result.segments[slot] = segment
		segment.identity = {
			"epoch": result.epoch, "slot": slot, "generation": server._path_generations[slot]
		}
		segment.start = server._path_tick
		@warning_ignore("integer_division")
		segment.until = (server._path_tick / 24 + 1) * 24
	result.party = preload("res://scripts/game/coop_campaign.gd").describe(server)
	if server.world.definition.get_meta("session_flow", false) and int(result.party.level) == 0:
		var lobby: bool = server.world.level.source_path == "/NATIVE/LOBBY"
		result.party.session = {"mode": "coop" if lobby else "versus", "lobby": lobby,
			"map": "lobby" if lobby else "arena-" + server.world.level.source_path.trim_prefix("/ARENA").trim_suffix(".LEV")}
	result.manifest = manifest(server.world.definition)
	result.owner = reference.duplicate()
	var handle: int = player.handle if player != null else -1
	result.prediction = {
		"applied": 0,
		"finalized": 0,
		"action": 0,
		"shot_index": 0,
		"receipts": [],
		"controls":
		(
			server
			. world
			. admission_state
			. controls
			. get(handle, {"held": 0xffffffff, "strafe": 0})
			. duplicate()
		),
		"rate": float(server.world.admission_state.rates.get(handle, 0.0))
	}
	result.continuation = {}
	if player != null:
		result.continuation = {
			"latch": player.latch.state.duplicate(),
			"visibility": player.actor_visibility._previous.duplicate(true),
			"sightings": player._sightings.duplicate(true),
			"wall_cursor": player.wall_cursor,
			"query_remainder": player._query_remainder,
			"door_remainder": player._door_remainder,
			"world_origin": player.world_origin,
			"scheme": player.control_scheme,
			"native_keyboard": player._native_keyboard_controls,
			"collision":
			{
				"fractions": player._collision.fractions.duplicate(),
				"axis_remainder": player._collision.axis_remainder
			}
		}
	result.clock = {
		"ordinal": server.world.clock.tick_count,
		"phase": server.world.clock._phase,
		"numerator": server.world.clock._numerator,
		"threshold": server.world.clock._threshold
	}
	result.roster = []
	for row: RefCounted in server.world.players:
		# Other inventories, input windows and visibility history are private.
		result.roster.append(
			{
				"reference": row.player_ref(),
				"seat": row.seat,
				"motion": row.motion.duplicate(true),
				"state": row.fighter.state,
				"proxy": row.fighter.proxy
			}
		)
		if not row.public_name.is_empty(): result.roster.back().name = row.public_name
		if server.world.bots.is_bot(row.player_ref()): result.roster.back().controller="bot"
	# Existing public actor impulse words carry confirmed human motion intent.
	# Copy only changed proxy records: frozen source actors and checkpoints must
	# retain their original actor fields. No private fighter record is exposed.
	var changed_proxies := false
	for participant: RefCounted in server.world.players:
		var proxy: int = participant.fighter.proxy
		if proxy < 0 or int(participant.fighter.state) != 1:
			continue
		var actor: Dictionary = result.records.actor_system.actors[proxy]
		if int(actor.kind) != 20:
			continue
		if int(actor.impulse_x) == int(participant.fighter.impulse_x) and int(actor.impulse_y) == int(participant.fighter.impulse_y):
			continue
		if not changed_proxies:
			result.records = result.records.duplicate()
			result.records.actor_system = result.records.actor_system.duplicate()
			result.records.actor_system.actors = result.records.actor_system.actors.duplicate()
			changed_proxies = true
		var projected := actor.duplicate()
		projected.impulse_x = participant.fighter.impulse_x
		projected.impulse_y = participant.fighter.impulse_y
		result.records.actor_system.actors[proxy] = projected
	return result


func digest(state: Dictionary) -> String:
	return Wire.new().canonical_hash(state)


func pack(state: Dictionary) -> PackedByteArray:
	var wire := Wire.new()
	var raw := wire.encode(state)
	last_error = wire.last_error
	if raw.size() > MAX_RAW:
		last_error = "Replicated state exceeds 1 MiB"
		return PackedByteArray()
	return raw


func unpack(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() > MAX_RAW:
		last_error = "Replicated state exceeds 1 MiB"
		return {}
	var wire := Wire.new()
	var state: Dictionary = wire.decode(bytes)
	last_error = wire.last_error
	return state


func difference(before: Variant, after: Variant) -> Dictionary:
	if ClassDB.class_exists("BloodshotPrimitiveCodec"):
		var native: Object = ClassDB.instantiate("BloodshotPrimitiveCodec")
		if native.has_method("difference"):
			return native.difference(before, after)
	return _difference(before, after)


## Portable oracle retained for differential regression and extension-free tools.
func _difference(before: Variant, after: Variant) -> Dictionary:
	if typeof(before) == typeof(after) and before == after:
		return {}
	if before is Dictionary and after is Dictionary:
		var patch := {"op": "map", "remove": [], "items": {}}
		for key: Variant in before:
			if not after.has(key):
				patch.remove.append(key)
		for key: Variant in after:
			var child := (
				_difference(before[key], after[key])
				if before.has(key)
				else {"op": "set", "value": after[key]}
			)
			if not child.is_empty():
				patch.items[key] = child
		return patch
	if before is Array and after is Array and before.size() == after.size():
		# The bounded receipt window shifts after each applied input. Replacing its
		# complete two-field rows is smaller than 64 nested index/map operations.
		if (
			after.size() > 8
			and after[0] is Dictionary
			and after[0].size() == 2
			and after[0].has_all(["sequence", "ordinal"])
		):
			return {"op": "set", "value": after}
		var patch := {"op": "array", "items": {}}
		for index: int in range(after.size()):
			var child := _difference(before[index], after[index])
			if not child.is_empty():
				patch.items[index] = child
		return patch
	return {"op": "set", "value": after}


func apply(before: Variant, patch: Dictionary, depth: int = 0) -> Variant:
	if depth == 0:
		last_error = ""
	var detached: Variant = (
		before.duplicate(true) if before is Dictionary or before is Array else before
	)
	return _apply_owned(detached, patch, depth)


## Internal transport path: validated immutable baselines may share unchanged
## branches. Public apply() still returns a fully detached writable tree.
func apply_frozen(before: Variant, patch: Dictionary) -> Variant:
	if (
		(before is Dictionary or before is Array)
		and before.is_read_only()
		and ClassDB.class_exists("BloodshotPrimitiveCodec")
	):
		var native: Object = ClassDB.instantiate("BloodshotPrimitiveCodec")
		if native.has_method("apply_frozen"):
			var result: Dictionary = native.apply_frozen(before, patch)
			last_error = result.error
			return result.value
	return apply(before, patch)


func _apply_owned(before: Variant, patch: Dictionary, depth: int) -> Variant:
	if depth > 24:
		last_error = "Patch nesting limit"
		return null
	if patch.is_empty():
		return before
	if patch.get("op") == "set" and patch.size() == 2 and patch.has("value"):
		return (
			patch.value.duplicate(true)
			if patch.value is Dictionary or patch.value is Array
			else patch.value
		)
	var result: Variant
	if (
		patch.get("op") == "map"
		and patch.size() == 3
		and before is Dictionary
		and patch.get("remove") is Array
		and patch.get("items") is Dictionary
	):
		result = before
		for key: Variant in patch.remove:
			if not result.has(key) or patch.items.has(key):
				last_error = "Invalid explicit removal"
				return null
			result.erase(key)
	elif (
		patch.get("op") == "array"
		and patch.size() == 2
		and before is Array
		and patch.get("items") is Dictionary
	):
		result = before
	else:
		last_error = "Invalid patch shape"
		return null
	for key: Variant in patch.items:
		if (
			not patch.items[key] is Dictionary
			or (result is Array and (not key is int or key < 0 or key >= result.size()))
		):
			last_error = "Invalid changed-field index"
			return null
		result[key] = _apply_owned(
			result.get(key) if result is Dictionary else result[key], patch.items[key], depth + 1
		)
		if not last_error.is_empty():
			return null
	return result


func validate(state: Dictionary, definition: RefCounted) -> bool:
	last_error = "Invalid replicated state"
	var keys := [
		"epoch",
		"revision",
		"watermark",
		"pending_aim",
		"phase",
		"animation_time",
		"boundary_time",
		"segments",
		"sight",
		"records",
		"manifest",
		"owner",
		"roster",
		"prediction",
		"continuation",
		"clock",
		"party"
	]
	if state.has("loot"):
		if not definition.get_meta("session_flow", false): return false
		keys.append("loot")
		if not preload("res://scripts/game/native_inventory_drops.gd").valid(state.loot, definition):
			return false
	if state.has("versus"):
		if not definition.get_meta("session_flow", false): return false
		keys.append("versus")
		if not preload("res://scripts/game/vs_match.gd").valid(state.versus, definition, true): return false
	if definition.get_meta("session_flow", false) and definition.level.get_meta("battle_mode", false) and not state.has("versus"): return false
	if definition.get_meta("session_flow", false) and not state.has("loot"):
		return false
	if (
		state.size() != keys.size()
		or not state.has_all(keys)
		or state.manifest != manifest(definition)
	):
		return false
	for key: String in ["epoch", "revision", "watermark", "pending_aim"]:
		if not state[key] is int or (key != "pending_aim" and state[key] < 0):
			return false
	for key: String in ["phase", "animation_time", "boundary_time"]:
		if not state[key] is float or not is_finite(state[key]) or state[key] < 0:
			return false
	if (
		state.phase > 1
		or not state.owner is Dictionary
		or not state.roster is Array
		or state.roster.size() > 4
		or not state.records is Dictionary
		or not state.segments is Dictionary
		or not state.sight is Dictionary
	):
		return false
	var records: Dictionary = state.records
	if (
		not records.has_all(
			[
				"motion",
				"fighter",
				"input_state",
				"keys",
				"weapon_state",
				"groups",
				"blocked_doors",
				"palette_state",
				"last_events",
				"countdown_expired",
				"update_count",
				"demo_mode",
				"actor_system"
			]
		)
		or records.size() != 13
	):
		return false
	if (
		not state.prediction is Dictionary
		or state.prediction.size() != 7
		or not state.prediction.has_all(
			["applied", "finalized", "controls", "rate", "action", "shot_index", "receipts"]
		)
	):
		return false
	var ack: Dictionary = state.prediction
	for key: String in ["applied", "finalized", "action", "shot_index"]:
		if not ack[key] is int or ack[key] < 0:
			return false
	if (
		ack.applied > ack.finalized
		or not ack.controls is Dictionary
		or not preload("res://scripts/game/input_admission.gd").valid_controls(ack.controls)
		or not ack.rate is float
		or not is_finite(ack.rate)
		or absf(ack.rate) > 65536.0
		or not ack.receipts is Array
		or ack.receipts.size() > 64
	):
		return false
	for item: Variant in ack.receipts:
		if (
			not item is Dictionary
			or item.size() != 2
			or not item.get("sequence") is int
			or item.sequence < 1
			or item.sequence > ack.finalized
			or not item.get("ordinal") is int
			or item.ordinal < 0
		):
			return false
	var schema: RefCounted = _validation_schema
	schema.last_error = ""
	schema.definition = definition
	if (
		not state.clock is Dictionary
		or state.clock.size() != 4
		or not state.clock.has_all(["ordinal", "phase", "numerator", "threshold"])
	):
		return false
	for value: Variant in state.clock.values():
		if not value is int or value < 0:
			return false
	if (
		state.clock.ordinal != state.revision
		or state.clock.numerator != 53203424 * 4
		or state.clock.threshold != 1070460 * 1000000
	):
		return false
	if not state.continuation is Dictionary:
		return false
	var own: Dictionary = state.continuation
	if state.owner.is_empty():
		if not own.is_empty():
			return false
	else:
		if (
			own.size() != 10
			or not own.has_all(
				[
					"latch",
					"visibility",
					"sightings",
					"wall_cursor",
					"query_remainder",
					"door_remainder",
					"world_origin",
					"scheme",
					"native_keyboard",
					"collision"
				]
			)
		):
			return false
		if (
			not schema._record("latch", own.latch)
			or not schema._record("visibility_history", own.visibility)
			or not schema._collision(own.collision, definition.level.moving_groups.size())
			or not own.world_origin is Vector2i
			or not own.sightings is Array
			or own.sightings.size() > 180
			or not own.native_keyboard is bool
		):
			return false
		for key: String in ["wall_cursor", "query_remainder", "door_remainder", "scheme"]:
			if not own[key] is int or own[key] < -2147483648 or own[key] > 2147483647:
				return false
		if (
			own.wall_cursor < -1
			or own.wall_cursor >= definition.level.walls.size()
			or own.scheme < 0
			or own.scheme > 2
		):
			return false
	if not preload("res://scripts/game/coop_campaign.gd").valid(state.party):
		return false
	var seen := {}
	var seats := {}
	var owned: bool = state.owner.is_empty()
	for row: Variant in state.roster:
		if (
			not row is Dictionary
			or row.size() != 5 + int(row.has("controller")) + int(row.has("name"))
			or not row.has_all(["reference", "seat", "motion", "state", "proxy"])
		):
			return false
		if row.has("name") and not preload("res://scripts/network/network_settings.gd").valid_name(row.name): return false
		if row.has("controller") and row.controller not in ["human","bot"]: return false
		if row.get("controller","human")=="bot" and row.reference==state.owner: return false
		if (
			not _reference(row.reference)
			or not row.seat is int
			or row.seat < 0
			or row.seat > 3
			or seen.has(row.reference.id)
			or seats.has(row.seat)
			or not row.state is int
			or row.state < 0
			or row.state > 4
			or not row.proxy is int
			or row.proxy < -1
			or row.proxy >= 180
			or not schema._record("motion", row.motion)
		):
			return false
		seen[row.reference.id] = true
		seats[row.seat] = true
		owned = owned or row.reference == state.owner
	if not owned:
		return false
	for pair: Array in [
		["motion", "motion"],
		["fighter", "fighter"],
		["input_state", "input"],
		["weapon_state", "weapons"]
	]:
		if (
			not records[pair[0]] is Dictionary
			or (not state.owner.is_empty() and not schema._record(pair[1], records[pair[0]]))
			or (state.owner.is_empty() and not records[pair[0]].is_empty())
		):
			return false
	if not records.keys is Array or (not state.owner.is_empty() and not schema._keys(records.keys)):
		return false
	if (
		not records.groups is Array
		or records.groups.size() != definition.level.moving_groups.size()
		or not records.blocked_doors is Array
		or not records.palette_state is Dictionary
		or not schema._record("palette", records.palette_state)
		or not records.last_events is Array
		or records.last_events.size() > 2048
		or not records.countdown_expired is bool
		or not records.demo_mode is bool
		or not records.update_count is int
		or records.update_count < 0
	):
		return false
	for group: Variant in records.groups:
		if not schema._record("door", group):
			return false
	for door: Variant in records.blocked_doors:
		if not door is int or door < 0 or door >= records.groups.size():
			return false
	if not state.sight.is_empty():
		if not state.sight.get("visible") is bool:
			return false
		if (
			state.sight.visible
			and (
				state.sight.size() != 3
				or not state.sight.get("frame") is int
				or state.sight.frame < 0
				or state.sight.frame > 11
				or not state.sight.get("position") is Vector2i
			)
		):
			return false
	var system: Variant = records.actor_system
	if (
		not system is Dictionary
		or system.size() != 4
		or not system.has_all(["actors", "encounter", "projectile_launches", "entity_generations"])
		or not system.actors is Array
		or system.actors.size() > 180
		or not system.entity_generations is Array
		or system.entity_generations.size() != system.actors.size()
		or not system.projectile_launches is Dictionary
		or not schema._record("encounter", system.encounter)
	):
		return false
	# Reuse reviewed field types/ranges but require only the public actor fields.
	schema.data.required.actor = schema.data.required.actor.filter(
		func(key):
			return schema.records.actor.fields[key].get("replication", "public") != "server_only"
	)
	var batched := ClassDB.class_exists("BloodshotPrimitiveCodec")
	if batched and _actor_rules.is_empty():
		_actor_rules = _public_scalar_rules(schema.records.actor.fields)
	batched = batched and not _actor_rules.is_empty()
	if batched:
		var scalar_records: Array = system.actors.duplicate()
		for segment: Variant in state.segments.values():
			scalar_records.append(segment.get("source") if segment is Dictionary else null)
		if not ClassDB.instantiate("BloodshotPrimitiveCodec").validate_scalar_records(
			scalar_records, _actor_rules, schema.data.required.actor
		):
			return false
	for index: int in range(system.actors.size()):
		var actor: Variant = system.actors[index]
		if (
			not actor is Dictionary
			or (not batched and not schema._record("actor", actor))
			or not system.entity_generations[index] is int
			or system.entity_generations[index] < 0
		):
			return false
		if not batched:
			for key: String in actor:
				if schema.records.actor.fields[key].get("replication", "public") == "server_only":
					return false
	for slot: Variant in state.segments:
		if (
			not slot is int
			or slot < 0
			or slot >= system.actors.size()
			or not state.segments[slot] is Dictionary
		):
			return false
		var segment: Dictionary = state.segments[slot]
		if (
			segment.size() != 6
			or not segment.has_all(["source", "launch", "identity", "start", "until"])
			or (not batched and not schema._record("actor", segment.source))
			or not segment.launch is Dictionary
		):
			return false
		if (
			not segment.identity is Dictionary
			or (
				segment.identity
				!= {
					"epoch": state.epoch,
					"slot": slot,
					"generation": system.entity_generations[slot]
				}
			)
			or not segment.start is int
			or not segment.until is int
			or segment.start < 0
			or segment.start > state.revision
			or segment.until <= segment.start
			or segment.until > segment.start + 24
		):
			return false
		if (
			not segment.launch.is_empty()
			and not schema._record("projectile_launch", segment.launch)
		):
			return false
		if not batched:
			for key: Variant in segment.source:
				if schema.records.actor.fields[key].get("replication", "public") == "server_only":
					return false
		if segment.has("end"):
			if (
				not segment.end is Dictionary
				or not segment.end.has_all(["x", "y"])
				or segment.end.size() > 3
			):
				return false
			for key: Variant in segment.end:
				if (
					key not in ["x", "y", "height"]
					or not segment.end[key] is int
					or segment.end[key] < -32768
					or segment.end[key] > 32767
				):
					return false
		elif segment.has("path"):
			var path: Variant = segment.path
			if (
				not path is Dictionary
				or path.size() != 3
				or not path.get("velocity") is Vector3
				or not path.velocity.is_finite()
				or not path.get("duration") is float
				or path.duration <= 0
				or path.duration > 6
				or not path.get("limit") is float
				or path.limit < 0
				or path.limit > 1
			):
				return false
		else:
			return false
	for slot: Variant in system.projectile_launches:
		if (
			not slot is int
			or slot < 0
			or slot >= system.actors.size()
			or not schema._record("projectile_launch", system.projectile_launches[slot])
		):
			return false
	if state.has("versus") and not preload("res://scripts/game/vs_match.gd").valid_bindings(state.versus, system.actors, system.entity_generations, state.roster, definition, true): return false
	last_error = ""
	return true


func _reference(value: Variant) -> bool:
	return (
		value is Dictionary
		and value.size() == 2
		and value.has_all(["id", "generation"])
		and value.id is int
		and value.generation is int
		and value.id > 0
		and value.id <= 0xffffffff
		and value.generation > 0
		and value.generation <= 0xffffffff
	)


static func _public_scalar_rules(fields: Dictionary) -> Dictionary:
	var rules := {}
	for field: String in fields:
		var descriptor: Dictionary = fields[field]
		if descriptor.get("replication", "public") == "server_only":
			continue
		# An unfamiliar future field type takes the existing validated fallback.
		if descriptor.type not in ["s16", "content_id_u32", "OwnerRef", "legacy_bool_int", "u2"]:
			return {}
		var unsigned: bool = descriptor.type == "content_id_u32"
		var owner: bool = descriptor.type == "OwnerRef"
		rules[field] = {
			"low": 0 if unsigned else (-0x100000000 if owner else -32768),
			"high": 0xffffffff if unsigned else (179 if owner else 32767),
			"bool_int": descriptor.type == "legacy_bool_int"
		}
		if descriptor.type == "legacy_bool_int":
			rules[field].low = 0
			rules[field].high = 1
		elif descriptor.type == "u2":
			rules[field].low = 0
			rules[field].high = 3
	return rules
