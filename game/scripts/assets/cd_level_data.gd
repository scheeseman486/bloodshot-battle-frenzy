@tool
class_name CdLevelData
extends Resource
## Original level translation. Only rebuildable user caches may persist it;
## original level data and decoded artwork are never shipped with the project.

var walls: Array[Dictionary] = []
var placements: Array[Dictionary] = []
var moving_groups: Array[Dictionary] = []
var dynamic_start: int
var spawn: Vector2i
var countdown_seconds: int
var spawn_angle: int = 0
var palette: PackedColorArray
var source_bytes: PackedByteArray
var source_path: String
var source_sha256: String
