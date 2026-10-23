class_name CdWorldDefinition
extends RefCounted
## Shared runtime CD metadata. Mutable simulation never writes these resources.
## Construction needs no world scene, textures, camera or audio worker.
var level: Resource
var tables: Resource
var catalog: Resource


func configure(
	original_level: Resource, original_tables: Resource, original_catalog: Resource
) -> void:
	assert(original_level != null and original_tables != null)
	level = original_level
	tables = original_tables
	catalog = original_catalog


func load_from_source(source: RefCounted, number: int = 1) -> bool:
	if number < 1 or number > 16:
		return false
	var loaded: Resource = source.load_cd_level("/LEVEL%d.LEV" % number)
	if loaded == null:
		return false
	var behaviour: Resource = source.load_cd_behaviour_tables()
	var actors: Resource = source.load_cd_actor_catalog(loaded)
	if behaviour == null or actors == null:
		return false
	configure(loaded, behaviour, actors)
	return true


## Native session maps have separate identities; original CD loading stays strict.
func load_map(source: RefCounted, identifier: String) -> bool:
	if identifier == "lobby":
		var built: Dictionary = preload("res://scripts/game/native_session_maps.gd").build(source)
		if built.is_empty():
			return false
		configure(built.level, built.tables, built.catalog)
		return true
	if identifier.begins_with("arena-") and identifier.trim_prefix("arena-").is_valid_int():
		var loaded: Resource = source.load_cd_arena(
			"/ARENA%d.LEV" % int(identifier.trim_prefix("arena-"))
		)
		if loaded == null:
			return false
		var actors: Resource = source.load_cd_actor_catalog(loaded)
		var behaviour: Resource = source.load_cd_behaviour_tables()
		if actors == null or behaviour == null:
			return false
		configure(loaded, behaviour, actors)
		return true
	if identifier.begins_with("level-") and identifier.trim_prefix("level-").is_valid_int():
		return load_from_source(source, int(identifier.trim_prefix("level-")))
	return false


func load_manifest(source: RefCounted, manifest: Dictionary) -> bool:
	var path := str(manifest.get("level", ""))
	var loaded := false
	if path == "/NATIVE/LOBBY":
		loaded = load_map(source, "lobby")
	elif path.begins_with("/ARENA"):
		loaded = load_map(source, "arena-" + path.trim_prefix("/ARENA").trim_suffix(".LEV"))
	else:
		loaded = load_from_source(source, int(path.trim_prefix("/LEVEL").trim_suffix(".LEV")))
	if loaded:
		set_meta("session_flow", manifest.get("protocol", 6) in [9, 10, 11, 12, 13, 14, 15])
	return loaded
