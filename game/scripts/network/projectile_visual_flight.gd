extends RefCounted
## Bounded private flight for owning-player artwork. Pure CD flight math never
## tests live targets, creates effects, spends ammo or writes authority state.
const Flight = preload("res://scripts/simulation/cd_projectile_flight.gd")
const Path = preload("res://scripts/presentation/cd_projectile_motion_path.gd")
const MAX_TICKS := 150.0


static func create(actor: Dictionary, groups: Array, definition: RefCounted) -> Dictionary:
	var source := actor.duplicate(true)
	source.wall_cursor = 0
	return {
		"segments": [],
		"next": source,
		"fractions": groups.map(func(group): return int(group.fraction)),
		"definition": definition
	}


static func sample(program: Dictionary, age: float) -> Dictionary:
	if age < 0.0 or age >= MAX_TICKS:
		return {}
	var index := int(age / 24.0)
	var definition: RefCounted = program.definition
	while program.segments.size() <= index:
		var source: Dictionary = program.next
		if source.is_empty():
			return {}
		var path := Path.build(source, 6, definition.level, program.fractions, definition.catalog)
		if path.is_empty():
			return {}
		program.segments.append({"actor": source, "path": path})
		var next: Dictionary = (
			Flight
			. advance(
				source,
				6,
				definition.level,
				program.fractions,
				[],
				[],
				_ignore_hit,
				definition.catalog
			)
			. state
		)
		program.next = (
			next if int(next.kind) == int(source.kind) and float(path.limit) >= 1.0 else {}
		)
	var segment: Dictionary = program.segments[index]
	var phase := fmod(age, 24.0) / 24.0
	if phase >= float(segment.path.limit) and float(segment.path.limit) < 1.0:
		return {}  # Approach known contact, then await the real authoritative event.
	var actor: Dictionary = segment.actor.duplicate(true)
	Path.sample(actor, segment.path, phase)
	return actor


static func _ignore_hit(_target: int) -> bool:
	return true
