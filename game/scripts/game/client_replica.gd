class_name CdClientReplica
extends RefCounted
## Detached current records consumed by HUD/camera/views. No rules, world,
## collision callbacks, AI, RNG, authoritative clock or gameplay mutation API.
var level: Resource
var tables: Resource
var motion: Dictionary = {}
var fighter: Dictionary = {}
var input_state: Dictionary = {}
var weapon_state: Dictionary = {}
var keys: Array = []
var groups: Array = []
var blocked_doors: Array = []
var palette_state: Dictionary = {}
var actor_system: Dictionary = {}
var vs_state: Dictionary = {}
var last_events: Array = []
var update_count := 0
var countdown_expired := false
var demo_mode := false
var _sight: Dictionary = {}
var _actor_source: Array = []


func install(snapshot: Dictionary) -> void:
	vs_state = snapshot.get("versus", {}).duplicate(true)
	for key: String in snapshot.records:
		var value: Variant = snapshot.records[key]
		if key == "actor_system":
			var actors: Array = (
				actor_system.get("actors", [])
				if is_same(_actor_source, value.actors)
				else value.actors.duplicate(true)
			)
			_actor_source = value.actors
			actor_system = {"actors": actors}
			for field: String in value:
				if field != "actors":
					actor_system[field] = value[field].duplicate(true)
		else:
			set(key, value.duplicate(true) if value is Dictionary or value is Array else value)
	_sight = snapshot.sight.duplicate(true)


func weapon_sight(_all_sights: bool = true) -> Dictionary:
	return _sight.duplicate(true)


func is_complete() -> bool:
	return int(actor_system.encounter.mode) == 3


func is_game_over() -> bool:
	return int(actor_system.encounter.mode) == 0
