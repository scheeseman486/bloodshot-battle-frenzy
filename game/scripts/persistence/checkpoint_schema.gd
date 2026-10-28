class_name CdCheckpointSchema
extends RefCounted
## Reviewed record definitions exported from the architecture contract. Structural,
## range, content and reference validation precedes all candidate construction.
var last_error := ""
var definition: RefCounted
var _scalar_rules: Dictionary = {}
var data: Dictionary = JSON.parse_string(
	FileAccess.get_file_as_string("res://resources/persistence/checkpoint_schema.json")
)
var records: Dictionary:
	get:
		return data.records


func _need(condition: bool, message: String) -> bool:
	if not condition and last_error.is_empty():
		last_error = message
	return condition


func _shape(value: Variant, names: Array, where: String) -> bool:
	if not _need(value is Dictionary, where + ": expected record"):
		return false
	return _need(
		value.size() == names.size() and names.all(func(key): return value.has(key)),
		where + ": missing or unknown fields"
	)


func _int(value: Variant, low: int, high: int, where: String) -> bool:
	return _need(value is int and value >= low and value <= high, where + ": integer out of range")


func validate_envelope(state: Dictionary) -> bool:
	last_error = ""
	if not _shape(
		state,
		[
			"manifest",
			"timing",
			"world",
			"players",
			"system",
			"system_collision",
			"last_context_bound"
		],
		"checkpoint"
	):
		return false
	if not _shape(
		state.manifest, ["edition", "rules", "shell", "level", "level_sha256"], "manifest"
	):
		return false
	if not _int(state.manifest.level, -3, 16, "manifest.level") or state.manifest.level == 0:
		return false
	if not _need(
		(
			state.manifest.edition == "European Mega CD"
			and state.manifest.rules == data.rules
			and state.manifest.shell == data.shell
			and state.manifest.level_sha256 == (data.arenas[str(-int(state.manifest.level))]
				if int(state.manifest.level) < 0 else data.levels[str(state.manifest.level)])
		),
		"Original European CD content manifest mismatch"
	):
		return false
	if not _shape(
		state.timing,
		["profile", "numerator", "denominator", "samples", "multiplier", "ordinal", "phase"],
		"timing"
	):
		return false
	var timing: Dictionary = state.timing
	if (
		not _int(timing.numerator, 53203424, 53203424, "input clock numerator")
		or not _int(timing.denominator, 1070460, 1070460, "input clock denominator")
	):
		return false
	if (
		not _int(timing.samples, 2, 6, "timing.samples")
		or not _int(timing.multiplier, 1, 4, "timing.multiplier")
	):
		return false
	if not _need(
		(
			timing.samples in [2, 6]
			and timing.multiplier in [1, 4]
			and timing.numerator == 53203424
			and timing.denominator == 1070460
			and (
				timing.profile
				== "europe-cd-logical-%s-v1" % ("six" if timing.samples == 6 else "two")
			)
		),
		"Unsupported timing policy"
	):
		return false
	return (
		_int(timing.ordinal, 0, 0x7fffffffffffffff, "clock ordinal")
		and _int(timing.phase, 0, 0x7fffffffffffffff, "clock remainder/debt")
	)


func validate(state: Dictionary, source_definition: RefCounted) -> bool:
	if not validate_envelope(state):
		return false
	definition = source_definition
	if not _need(
		(
			definition != null
			and definition.catalog != null
			and definition.level.source_sha256 == state.manifest.level_sha256
			and definition.tables.source_sha256 == data.shell
			and definition.catalog.source_sha256 == data.shell
		),
		"Runtime CD definition mismatch"
	):
		return false
	if (
		not _shape(
			state.world,
			(
				data.world_fields
				+ (["music_restart_delay"] if state.world is Dictionary and state.world.has("music_restart_delay") else [])
				+ (["vs_state"] if state.world is Dictionary and state.world.has("vs_state") else [])
				+ (["bots"] if state.world is Dictionary and state.world.has("bots") else [])
				+ (["loot_state"] if state.world is Dictionary and state.world.has("loot_state") else [])
				+ (
					["score_state"]
					if state.world is Dictionary and state.world.has("score_state")
					else []
				)
			),
			"world"
		)
		or not _shape(state.system, data.system_fields, "actor system")
	):
		return false
	if not _need(state.players is Array and state.players.size() <= 4, "Player count exceeds four"):
		return false
	var world: Dictionary = state.world
	var system: Dictionary = state.system
	if world.has("music_restart_delay") and not _int(world.music_restart_delay,1,100,"Music retry delay"):
		return false
	if world.has("bots") and not _need(world.has("loot_state") and preload("res://scripts/game/bot_runtime.gd").valid(world.bots,state.players), "Invalid native bot continuation"): return false
	if not _need(world.has("vs_state") == definition.level.get_meta("battle_mode", false), "Missing or unexpected VS continuation"):
		return false
	if world.has("vs_state") and not _need(preload("res://scripts/game/vs_match.gd").valid(world.vs_state, definition), "Invalid native VS state"):
		return false
	if world.has("vs_state"):
		var bot_rows: Array = world.get("bots",{}).get("rows",[])
		for entry: Dictionary in world.vs_state.rows:
			if entry.active and not _need((entry.get("controller","human")=="bot")==bot_rows.any(func(bot): return bot.reference==entry.reference),"VS controller identity mismatch"): return false
	if world.has("loot_state") and not _need(
		preload("res://scripts/game/native_inventory_drops.gd").valid(world.loot_state, definition),
		"Invalid native inventory drops"
	):
		return false
	if (
		world.has("score_state")
		and not _need(
			preload("res://scripts/game/coop_score.gd").valid_world(world.score_state),
			"Invalid co-op score state"
		)
	):
		return false
	if not _need(
		world.groups is Array and world.groups.size() == definition.level.moving_groups.size(),
		"Door count differs from original level"
	):
		return false
	for group: Variant in world.groups:
		if not _record("door", group):
			return false
	if not _record("palette", world.palette_state):
		return false
	for key: String in [
		"countdown_expired", "demo_mode", "stop_when_exhausted", "_initial_proxy_claimed"
	]:
		if not _need(world[key] is bool, "world." + key + ": expected boolean"):
			return false
	if (
		not _int(world.update_count, 0, 0x7fffffffffffffff, "world update")
		or not _int(world._next_player_id, 1, 0x100000000, "next player id")
	):
		return false
	if not _need(
		world._seat_generations is Array and world._seat_generations.size() == 4,
		"Seat generation count"
	):
		return false
	for generation: Variant in world._seat_generations:
		if not _int(generation, 0, 0xffffffff, "seat generation"):
			return false
	if not _need(
		(
			system.actors is Array
			and system.actors.size() >= definition.catalog.actors.size()
			and system.actors.size() <= 180
		),
		"Actor pool bound"
	):
		return false
	if not _need(
		(
			system.entity_generations is Array
			and system.entity_generations.size() == system.actors.size()
		),
		"Actor generation count"
	):
		return false
	if not _need(system.actors.all(func(actor): return actor is Dictionary), "Actor record type"):
		return false
	for generation: Variant in system.entity_generations:
		if not _int(generation, 1, 0xffffffff, "actor generation"):
			return false
	if not _int(system.epoch, 1, 0x7fffffffffffffff, "authority epoch"):
		return false
	for key: String in ["movement_seed", "attack_seed"]:
		if not _int(system[key], 0, 0xffffffff, key):
			return false
	if not _int(system._update, 0, 65535, "source update word"):
		return false
	if not _int(system.geometry_remainder, -2147483648, 2147483647, "arithmetic history"):
		return false
	if not _int(system._dynamic_start, 0, 179, "Dynamic actor prefix"):
		return false
	if not _need(
		system._dynamic_start == definition.level.dynamic_start,
		"Actor dispatch prefix differs from media"
	):
		return false
	if not _record("encounter", system.encounter) or not _record("boss_clock", system.boss_clock):
		return false
	if not _need(system.boss_centre is Vector2i, "Boss centre type"):
		return false
	if (
		not _int(system.control_scheme, 0, 2, "actor control scheme")
		or not _need(
			system.demo_mode is bool and system.legacy_single_player is bool, "Actor flags"
		)
	):
		return false
	var ids := {}
	var handles := {}
	var seats := {}
	for row: Variant in state.players:
		if not _shape(
			row,
			(
				data.player_fields
				+ ["latch", "visibility", "collision", "keys_bound", "weapons_bound"]
				+ (["level_stats"] if row is Dictionary and row.has("level_stats") else [])
			),
			"player"
		):
			return false
		if (
			row.has("level_stats")
			and not _need(
				preload("res://scripts/game/coop_score.gd").valid_stats(row.level_stats),
				"Invalid co-op stats"
			)
		):
			return false
		if (
			not _int(row.id, 1, 0xffffffff, "player id")
			or not _int(row.generation, 1, 0xffffffff, "player generation")
			or not _int(row.seat, 0, 3, "player seat")
		):
			return false
		if not _int(row.handle, 0, 0xfffffffe, "player handle"):
			return false
		if not _need(
			(
				not ids.has(row.id)
				and not seats.has(row.seat)
				and row.id < world._next_player_id
				and row.handle == row.id - 1
				and row.generation == world._seat_generations[row.seat]
			),
			"Duplicate/inconsistent player identity"
		):
			return false
		ids[row.id] = row.generation
		seats[row.seat] = true
		handles[row.handle] = row
		for pair: Array in [
			["motion", "motion"],
			["fighter", "fighter"],
			["input_state", "input"],
			["weapon_state", "weapons"],
			["latch", "latch"],
			["visibility", "visibility_history"]
		]:
			if not _record(pair[1], row[pair[0]]):
				return false
		if not _keys(row.keys) or not _collision(row.collision, world.groups.size()):
			return false
		if (
			not _slot(row.fighter.proxy, system.actors.size(), "fighter proxy")
			or not _wall(row.wall_cursor)
		):
			return false
		if not _need(
			(
				row.world_origin is Vector2i
				and row._native_keyboard_controls is bool
				and row.keys_bound is bool
				and row.weapons_bound is bool
			),
			"Player continuation types"
		):
			return false
		if not _int(row.control_scheme, 0, 2, "player control scheme"):
			return false
		for key: String in ["_query_remainder", "_door_remainder"]:
			if not _int(row[key], -2147483648, 2147483647, key):
				return false
		if not _indices(row._sightings, system.actors.size(), false):
			return false
	var expected: Array = state.players.map(func(row): return row.handle)
	var ordered: Array = state.players.duplicate()
	ordered.sort_custom(func(a, b): return a.seat < b.seat)
	if not _need(state.players == ordered, "Player seat order"):
		return false
	# Contexts are absent before the first world pass, or after disconnect; a
	# retained unbound last context is valid continuation history.
	if not _need(
		(
			system.player_contexts is Dictionary
			and system._player_order is Array
			and system._player_order.size() == system.player_contexts.size()
			and system._player_order.all(func(handle): return system.player_contexts.has(handle))
			and system._player_order.size() == _unique_size(system._player_order)
		),
		"Actor player-context order"
	):
		return false
	for handle: Variant in system.player_contexts:
		if not _need(handle is int and handles.has(handle), "Unknown player context"):
			return false
		if not _record("actor_context", system.player_contexts[handle]):
			return false
	for key: String in ["player_proxies", "participant_refs", "player_schemes"]:
		if not _need(
			system[key] is Dictionary and system[key].size() == handles.size(),
			"Participant binding count: " + key
		):
			return false
		for handle: Variant in handles:
			if not _need(system[key].has(handle), "Missing participant binding"):
				return false
	for handle: Variant in handles:
		var row: Dictionary = handles[handle]
		if not _shape(
			system.participant_refs[handle], ["id", "generation"], "participant reference"
		):
			return false
		if (
			not _int(system.participant_refs[handle].id, 1, 0xffffffff, "reference id")
			or not _int(
				system.participant_refs[handle].generation, 1, 0xffffffff, "reference generation"
			)
		):
			return false
		if not _need(
			system.participant_refs[handle] == {"id": row.id, "generation": row.generation},
			"Participant reference mismatch"
		):
			return false
		if (
			not _slot(system.player_proxies[handle], system.actors.size(), "proxy")
			or not _int(system.player_schemes[handle], 0, 2, "scheme binding")
		):
			return false
		var proxy: int = system.player_proxies[handle]
		if (
			proxy >= 0
			and not _need(
				int(system.actors[proxy].get("kind", 0)) == 20, "Live proxy points to another kind"
			)
		):
			return false
		if row.keys_bound or row.weapons_bound:
			if not _need(system.player_contexts.has(handle), "Missing aliased player context"):
				return false
			var context: Dictionary = system.player_contexts[handle]
			if not _need(
				(
					(not row.keys_bound or context.has("keys"))
					and (not row.weapons_bound or context.has("weapons"))
				),
				"Missing aliased context inventory"
			):
				return false
			if (
				row.keys_bound
				and not _need(row.keys == system.player_contexts[handle].keys, "Key alias mismatch")
			):
				return false
			if (
				row.weapons_bound
				and not _need(
					row.weapon_state == system.player_contexts[handle].weapons,
					"Weapon alias mismatch"
				)
			):
				return false
	if not _record("actor_context", system._last_player_state):
		return false
	if not _need(
		state.last_context_bound is bool and system._current_player is int,
		"Last context binding type"
	):
		return false
	if (
		state.last_context_bound
		and not _need(
			(
				system.player_contexts.has(system._current_player)
				and system._last_player_state == system.player_contexts[system._current_player]
			),
			"Last context alias mismatch"
		)
	):
		return false
	var batched := _validate_actor_batch(system.actors)
	if batched < 0:
		return false
	for actor: Variant in system.actors:
		if batched == 0 and not _record("actor", actor):
			return false
		if int(actor.get("kind", 0)) >= 1 and int(actor.get("kind", 0)) <= 19:
			for key: String in ["target", "seen"]:
				if not _need(actor[key] == -1 or handles.has(actor[key]), "Stale actor " + key):
					return false
		if (
			not _int(actor.kind, 0, 48, "actor kind")
			or not _int(
				actor.wall_cursor, -1, definition.level.walls.size() - 1, "actor wall cursor"
			)
		):
			return false
		if (
			actor.frame != 0
			and not _need(definition.catalog.frames.has(actor.frame), "Unknown CD frame id")
		):
			return false
		if (
			actor.cursor != 0
			and not _need(
				definition.catalog.animations.has(actor.cursor), "Unknown CD animation cursor"
			)
		):
			return false
		if (
			actor.parameter != 0
			and not _need(
				definition.catalog.parameters.has(actor.parameter), "Unknown CD parameter id"
			)
		):
			return false
		if (
			actor.kind >= 1
			and actor.kind <= 19
			and not _need(
				definition.catalog.parameters.has(actor.parameter), "Enemy parameter missing"
			)
		):
			return false
	if world.has("vs_state") and not _need(preload("res://scripts/game/vs_match.gd").valid_bindings(world.vs_state, system.actors, system.entity_generations, state.players, definition), "Invalid VS actor/player bindings"):
		return false
	if not _indices(system.active, system.actors.size(), true):
		return false
	for slot: int in system.active:
		if not _need(
			int(system.actors[slot].kind) in range(1, 20) and int(system.actors[slot].target) >= 0,
			"Inactive/stale enemy in active order"
		):
			return false
	if not _owners(system, world._next_player_id):
		return false
	if not _collision(state.system_collision, world.groups.size()):
		return false
	if not _indices(world.blocked_doors, world.groups.size(), true):
		return false
	if not _need(world.demo_state is Dictionary, "Demo continuation record"):
		return false
	if not world.demo_state.is_empty():
		var demo: Dictionary = world.demo_state
		if not _shape(
			demo,
			["pointer", "reader", "action_cursor", "world_calls", "finished"],
			"demo continuation"
		):
			return false
		if not _shape(demo.reader, ["cursor", "remaining", "held", "edge"], "demo reader"):
			return false
		for key: String in demo.reader:
			if not _int(demo.reader[key], 0, 65535, "demo reader scalar"):
				return false
		if (
			not _int(demo.pointer, 0x8000, 0x80000, "demo content pointer")
			or not _int(demo.action_cursor, 0, 65535, "demo action cursor")
			or not _int(demo.world_calls, 0, 943, "demo world call")
		):
			return false
		if not _need(
			(
				demo.finished is bool
				and world.demo_mode
				and state.players.size() == 1
				and state.timing.multiplier == 1
				and state.timing.samples == 6
			),
			"Demo continuation mode"
		):
			return false
	if not _need(
		world.demo_actions is Array and world.demo_actions.size() <= 256, "Demo action limit"
	):
		return false
	for action: Variant in world.demo_actions:
		if not _shape(action, ["kind", "actor", "target", "update"], "demo action"):
			return false
		if not _need(
			(
				action.kind in ["activate", "remove"]
				and action.actor is int
				and action.actor >= 0
				and action.actor < system.actors.size()
				and action.target is int
				and (action.target == -1 or handles.has(action.target))
				and action.update is int
			),
			"Invalid demo action"
		):
			return false
	if not _need(
		system.projectile_launches is Dictionary and system.projectile_launches.size() <= 180,
		"Projectile continuity count"
	):
		return false
	for slot: Variant in system.projectile_launches:
		if (
			not _int(slot, 0, system.actors.size() - 1, "launch slot")
			or not _record("projectile_launch", system.projectile_launches[slot])
		):
			return false
	if not _int(system._projectile_generation, 0, 0x7fffffffffffffff, "launch generation"):
		return false
	if not _need(
		world.campaign_state is Dictionary and world.presentation_state is Dictionary,
		"Campaign/presentation records required"
	):
		return false
	if (
		not world.campaign_state.is_empty()
		and not _need(
			world.campaign_state.get("level_number") == (0 if int(state.manifest.level) < 0 else state.manifest.level),
			"Campaign/media level mismatch"
		)
	):
		return false
	return (
		preload("res://scripts/persistence/checkpoint_attachments.gd").new().validate(
			world.campaign_state, world.presentation_state, self
		)
		and _events(world)
		and _commands(world, handles, state.timing.ordinal)
		and _admission(world.admission_state, handles, state.timing)
	)


func _record(name: String, value: Variant) -> bool:
	# Larger flat owner records dominate remote validation. Keep the same
	# descriptors/required keys and the portable path for compound/future types.
	if (
		(
			name
			in [
				"motion",
				"fighter",
				"input",
				"door",
				"encounter",
				"key",
				"latch",
				"palette",
				"weapon",
				"boss_clock"
			]
		)
		and ClassDB.class_exists("BloodshotPrimitiveCodec")
	):
		var fields: Dictionary = records[name].fields
		var cached: Dictionary = _scalar_rules.get(name, {})
		if cached.is_empty() or cached.fields != fields:
			cached = {"fields": fields.duplicate(true), "rules": _owner_scalar_rules(fields)}
			_scalar_rules[name] = cached
		if not cached.rules.is_empty():
			return _need(
				ClassDB.instantiate("BloodshotPrimitiveCodec").validate_scalar_records(
					[value], cached.rules, data.required[name]
				),
				name + ": invalid scalar record"
			)
	return _record_portable(name, value)


## Executable reference for ranges, compound records and extension-free tools.
func _record_portable(name: String, value: Variant) -> bool:
	if not _need(value is Dictionary, name + ": record required"):
		return false
	if name in ["actor_context", "visibility_history"] and value.is_empty():
		return true
	var fields: Dictionary = records[name].fields
	if not _need(
		data.required[name].all(func(key): return value.has(key)), name + ": missing required field"
	):
		return false
	for key: Variant in value:
		if not _need(
			(key is String or key is StringName) and fields.has(key),
			name + ": unknown field " + str(key)
		):
			return false
		var type: String = fields[key].type
		var item: Variant = value[key]
		if key == "keys":
			if not _keys(item):
				return false
		elif key == "weapons":
			if not _record("weapons", item):
				return false
		elif key == "inventory":
			if not _need(item is Array and item.size() == 18, "Weapon inventory length"):
				return false
			for weapon: Variant in item:
				if not _record("weapon", weapon):
					return false
		elif name == "visibility_history":
			if not _need(
				item is Array and (item.size() in [0, 4] if key == "bounds" else item.size() == 2),
				"Visibility history bounds"
			):
				return false
			for number: Variant in item:
				if not _int(number, -2147483648, 2147483647, "visibility number"):
					return false
		elif type == "bool":
			if not _need(item is bool, name + "." + key + ": boolean required"):
				return false
		elif type == "legacy_bool_int":
			if not _need(item is bool or (item is int and item in [0, 1]), "Actor view flag"):
				return false
		else:
			var low := -32768
			var high := 32767
			match type:
				"u2":
					low = 0
					high = 3
				"u14":
					low = 0
					high = 16383
				"u16":
					low = 0
					high = 65535
				"u18":
					low = 0
					high = 262143
				"u32", "content_id_u32":
					low = 0
					high = 0xffffffff
				"u64":
					low = 0
					high = 0x7fffffffffffffff
				"s32_fixed16":
					low = -2147483648
					high = 2147483647
				"optional<PlayerRef>":
					low = -1
					high = 0xffffffff - 1
				"OwnerRef":
					low = -0x100000000
					high = 179
				"optional<EntityRef>":
					low = -1
					high = 179
				"optional<WallIndex>":
					low = -1
					high = definition.level.walls.size() - 1
			if not _int(item, low, high, name + "." + key):
				return false
	return true


func _keys(value: Variant) -> bool:
	if not _need(value is Array and value.size() == 9, "Key inventory length"):
		return false
	for key: Variant in value:
		if not _record("key", key):
			return false
	return true


func _wall(value: Variant) -> bool:
	return _int(value, 0, definition.level.walls.size() - 1, "wall cursor")


func _slot(value: Variant, count: int, where: String) -> bool:
	return _int(value, -1, count - 1, where)


func _indices(value: Variant, count: int, unique: bool) -> bool:
	if not _need(value is Array and value.size() <= 8192, "Index array required"):
		return false
	var seen := {}
	for index: Variant in value:
		if not _int(index, 0, count - 1, "index"):
			return false
		if unique and not _need(not seen.has(index), "Duplicate ordered index"):
			return false
		seen[index] = true
	return true


func _collision(value: Variant, count: int) -> bool:
	if not _shape(value, ["fractions", "axis_remainder"], "collision history"):
		return false
	if not _need(
		value.fractions is Array and value.fractions.size() in [0, count], "Collision fractions"
	):
		return false
	for number: Variant in value.fractions:
		if not _int(number, -32768, 32767, "collision fraction"):
			return false
	return (
		value.axis_remainder == null
		or _int(value.axis_remainder, -2147483648, 2147483647, "collision arithmetic")
	)


func _owners(system: Dictionary, next_id: int) -> bool:
	if not _need(
		system.projectile_owners is Dictionary and system.projectile_owners.size() <= 180,
		"Owner table"
	):
		return false
	for slot: Variant in system.projectile_owners:
		if not _int(slot, 0, system.actors.size() - 1, "owner slot"):
			return false
		var owner: Variant = system.projectile_owners[slot]
		if not _need(owner is Dictionary and owner.has("tag"), "Tagged owner required"):
			return false
		if owner.tag == "none":
			if not _shape(owner, ["tag"], "empty owner"):
				return false
			continue
		if not _shape(owner, ["tag", "reference"], "owner"):
			return false
		var ref: Variant = owner.reference
		if owner.tag == "player":
			if not _shape(ref, ["id", "generation"], "owner player ref"):
				return false
			if (
				not _int(ref.id, 1, next_id - 1, "owner id")
				or not _int(ref.generation, 1, 0xffffffff, "owner generation")
			):
				return false
		elif owner.tag == "actor":
			if not _shape(ref, ["epoch", "slot", "generation"], "owner entity ref"):
				return false
			if not _int(ref.epoch, system.epoch, system.epoch, "Owner epoch mismatch"):
				return false
			if (
				not _int(ref.slot, 0, system.actors.size() - 1, "owner actor slot")
				or not _int(
					ref.generation,
					1,
					int(system.entity_generations[ref.slot]),
					"owner actor generation"
				)
			):
				return false
		else:
			return _need(false, "Unknown owner tag")
	return true


func _events(world: Dictionary) -> bool:
	if not _int(world.event_sequence, 0, 0x7fffffffffffffff, "event sequence"):
		return false
	return _need(
		world.pending_events is Array and world.pending_events.is_empty(),
		"Schema 1 durable effects must be committed before capture"
	)


func _unique_size(values: Array) -> int:
	var unique := {}
	for value: Variant in values:
		unique[value] = true
	return unique.size()


func _commands(world: Dictionary, handles: Dictionary, ordinal: int) -> bool:
	if not _need(
		(
			world.pending_commands is Array
			and world.pending_commands.size() <= 256
			and world.accepted_controls is Dictionary
			and world.accepted_controls.size() <= 4
		),
		"Command queue bounds"
	):
		return false
	for handle: Variant in world.accepted_controls:
		if not _need(handle is int and handles.has(handle), "Accepted controls target"):
			return false
		if not _controls(world.accepted_controls[handle]):
			return false
	var previous := ordinal + 1
	for command: Variant in world.pending_commands:
		if not _shape(command, ["player", "ordinal", "controls", "aim_events"], "pending command"):
			return false
		if not _shape(command.player, ["id", "generation"], "command participant"):
			return false
		if not _int(command.player.id, 1, 0xffffffff, "command player"):
			return false
		if not _int(command.player.generation, 1, 0xffffffff, "command generation"):
			return false
		var handle: int = command.player.id - 1
		if not _need(
			handles.has(handle) and handles[handle].generation == command.player.generation,
			"Stale command participant"
		):
			return false
		if not _int(command.ordinal, previous, 0x7fffffffffffffff, "command time"):
			return false
		previous = command.ordinal
		if not _controls(command.controls):
			return false
		if not _need(
			command.aim_events is Array and command.aim_events.size() <= 64, "Command aim bound"
		):
			return false
		for delta: Variant in command.aim_events:
			if not _int(delta, -1073741823, 1073741823, "quantized aim event"):
				return false
	return true


func _controls(value: Variant) -> bool:
	if value is int:
		return _int(value, 0, 0xffffffff, "held input")
	return (
		_shape(value, ["held", "strafe"], "native controls")
		and _int(value.held, 0, 0xffffffff, "held controls")
		and _int(value.strafe, -1, 1, "strafe controls")
	)


func _admission(state: Variant, handles: Dictionary, timing: Dictionary) -> bool:
	if not _shape(
		state,
		["queue", "controls", "rates", "next_sequence", "applied", "source_visibility"],
		"input admission"
	):
		return false
	if not _need(state.source_visibility is bool, "admission visibility policy"):
		return false
	if (
		not _int(state.next_sequence, 1, 0x7fffffffffffffff, "admission sequence")
		or not _int(state.applied, 0, state.next_sequence - 1, "applied sequence")
	):
		return false
	if not _need(state.queue is Array and state.queue.size() <= 4096, "admission queue limit"):
		return false
	for table: String in ["controls", "rates"]:
		if not _need(
			state[table] is Dictionary and state[table].size() <= 4, "admission participant table"
		):
			return false
		for handle: Variant in state[table]:
			if not _need(handle is int and handles.has(handle), "admission participant"):
				return false
			if table == "controls" and not _controls(state[table][handle]):
				return false
			if (
				table == "rates"
				and not _need(
					(
						state[table][handle] is float
						and is_finite(state[table][handle])
						and absf(state[table][handle]) <= 65536.0
					),
					"admitted aim rate"
				)
			):
				return false
	var previous: int = timing.ordinal
	var offset := 0
	var sequence: int = state.applied
	@warning_ignore("integer_division")
	var last: int = timing.ordinal + timing.phase / (int(timing.denominator) * 1000000)
	var residue: int = timing.phase % (int(timing.denominator) * 1000000)
	for event: Variant in state.queue:
		if not _shape(
			event,
			["player", "ordinal", "offset", "sequence", "controls", "rate", "aim"],
			"admitted event"
		):
			return false
		if not _shape(event.player, ["id", "generation"], "admitted player"):
			return false
		if (
			not _int(event.player.id, 1, 0xffffffff, "admitted player id")
			or not _int(event.player.generation, 1, 0xffffffff, "admitted generation")
		):
			return false
		var handle: int = event.player.id - 1
		if not _need(
			handles.has(handle) and handles[handle].generation == event.player.generation,
			"stale admitted player"
		):
			return false
		if (
			not _int(event.ordinal, timing.ordinal + 1, last, "admitted ordinal")
			or not _int(event.offset, 0, int(timing.denominator) * 1000000 - 1, "admitted residue")
		):
			return false
		if not _need(
			(
				event.ordinal >= previous
				and (event.ordinal > previous or event.offset >= offset)
				and (event.ordinal < last or event.offset <= residue)
			),
			"admission timestamp order"
		):
			return false
		if (
			not _int(event.sequence, sequence + 1, state.next_sequence - 1, "admission order")
			or not _controls(event.controls)
		):
			return false
		if not _need(
			(
				event.rate is float
				and is_finite(event.rate)
				and absf(event.rate) <= 65536.0
				and event.aim is Array
				and event.aim.size() <= 64
			),
			"admitted aim"
		):
			return false
		for delta: Variant in event.aim:
			if not _int(delta, -1073741823, 1073741823, "admitted aim event"):
				return false
		previous = event.ordinal
		offset = event.offset
		sequence = event.sequence
	return true


## -1 invalid, 0 portable fallback, 1 native scalar batch. Ranges are derived
## from the same reviewed descriptors; dynamic reference/content checks remain
## in validate(), and no checkpoint is trusted merely because it was captured.
func _validate_actor_batch(actors: Array) -> int:
	if not ClassDB.class_exists("BloodshotPrimitiveCodec"):
		return 0
	var rules := {}
	for field: String in records.actor.fields:
		var type: String = records.actor.fields[field].type
		var low := -32768
		var high := 32767
		match type:
			"u2":
				low = 0
				high = 3
			"s16":
				pass
			"content_id_u32":
				low = 0
				high = 0xffffffff
			"legacy_bool_int":
				low = 0
				high = 1
			"OwnerRef":
				low = -0x100000000
				high = 179
			"optional<PlayerRef>":
				low = -1
				high = 0xfffffffe
			"optional<WallIndex>":
				low = -1
				high = definition.level.walls.size() - 1
			_:
				return 0
		rules[field] = {"low": low, "high": high, "bool_int": type == "legacy_bool_int"}
	return (
		1
		if _need(
			ClassDB.instantiate("BloodshotPrimitiveCodec").validate_scalar_records(
				actors, rules, data.required.actor
			),
			"Invalid checkpoint actor scalar record"
		)
		else -1
	)


static func _owner_scalar_rules(fields: Dictionary) -> Dictionary:
	var rules := {}
	for field: String in fields:
		var low := -32768
		var high := 32767
		match fields[field].type:
			"s16":
				pass
			"u14":
				low = 0
				high = 16383
			"u16":
				low = 0
				high = 65535
			"u18":
				low = 0
				high = 262143
			"content_id_u32", "u32":
				low = 0
				high = 0xffffffff
			"s32_fixed16":
				low = -2147483648
				high = 2147483647
			"optional<EntityRef>":
				low = -1
				high = 179
			_:
				return {}
		rules[field] = {"low": low, "high": high, "bool_int": false}
	return rules
