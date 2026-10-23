extends RefCounted
## Code-authored native spaces; all wall/sprite/palette artwork stays CD-backed.
## Geometry identity never impersonates a verified original level hash.
const REVISION := "native-session-room-v1"
const SPAWNS := [Vector2i(-640, -640), Vector2i(640, -640), Vector2i(-640, 640), Vector2i(640, 640)]


static func build(source: RefCounted) -> Dictionary:
	var art: Resource = source.load_cd_level("/LEVEL1.LEV")
	if art == null:
		return {}
	var level := preload("res://scripts/assets/cd_level_data.gd").new()
	level.source_path = "/NATIVE/LOBBY"
	level.source_bytes = art.source_bytes
	level.palette = art.palette
	level.spawn = SPAWNS[0]
	level.spawn_angle = 32
	level.dynamic_start = 0
	level.countdown_seconds = 0
	level.set_meta("art_level", art)
	level.set_meta("battle_mode", false)
	var spawns: Array = []
	for seat: int in range(4):
		spawns.append({"position": SPAWNS[seat], "angle": [32, 224, 96, 160][seat]})
	level.set_meta("native_spawns", spawns)
	# Short ordered segments preserve the source integer collision search window.
	var corners := [
		Vector2i(-1280, -1280), Vector2i(1280, -1280), Vector2i(1280, 1280), Vector2i(-1280, 1280)
	]
	for side: int in range(4):
		_edge(level, art.walls[0], corners[side], corners[(side + 1) % 4])
	level.walls.sort_custom(func(a: Dictionary, b: Dictionary): return a.start.y < b.start.y)
	level.source_sha256 = (
		(REVISION + level.source_path + art.source_sha256 + JSON.stringify([level.walls, spawns]))
		. sha256_text()
	)
	var original: Resource = source.load_cd_actor_catalog(art)
	if original == null:
		return {}
	var catalog := preload("res://scripts/assets/cd_actor_catalog.gd").new()
	# Resource.duplicate does not copy these unexported runtime fields. Reuse
	# prepared CD content without decoding media again or editing the cache.
	for property: Dictionary in original.get_property_list():
		if (int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
			var value: Variant = original.get(property.name)
			catalog.set(
				property.name,
				value.duplicate(true) if value is Array or value is Dictionary else value
			)
	catalog.actors.clear()
	catalog.level_sha256 = level.source_sha256
	return {"level": level, "tables": source.load_cd_behaviour_tables(), "catalog": catalog}


static func _edge(level: Resource, texture: Dictionary, start: Vector2i, finish: Vector2i) -> void:
	var count := maxi(absi(finish.x - start.x), absi(finish.y - start.y)) / 256
	for step: int in range(count):
		var a := Vector2i(Vector2(start).lerp(Vector2(finish), float(step) / count))
		var b := Vector2i(Vector2(start).lerp(Vector2(finish), float(step + 1) / count))
		var wall: Dictionary = texture.duplicate()
		wall.start = a if a.y <= b.y else b
		wall.finish = b if a.y <= b.y else a
		wall.motion_kind = 0
		wall.motion_group = 0
		wall.motion_delta = Vector2i.ZERO
		level.walls.append(wall)
