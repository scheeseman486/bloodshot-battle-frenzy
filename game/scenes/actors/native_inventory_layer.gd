extends Node3D
## Native multiplayer drops/departures, sharing runtime CD billboard resources.
const ActorScene = preload("res://scenes/actors/cd_actor.tscn")
const Actor = preload("res://scenes/actors/cd_actor.gd")
const Drops = preload("res://scripts/game/native_inventory_drops.gd")
static var _prepared_pickups: Dictionary = {}
var _world: Node3D
var _catalog: Resource
var _materials: Dictionary = {}
var _items: Array[Node3D] = []
var _departures: Array[Node3D] = []
var _noise_materials: Array[ShaderMaterial] = []
var _frames: Dictionary = {}
var _art: Dictionary = {}


func configure(world: Node3D, catalog: Resource) -> void:
	_world = world
	_catalog = catalog
	if world.actor_materials.is_empty():
		world.actor_materials = Actor.materials_for(world.source, world.level, catalog)
	_materials = world.actor_materials
	_frames.clear()
	_art.clear()
	for view: Node3D in _items + _departures:
		remove_child(view)
		view.queue_free()
	_items.clear()
	_departures.clear()
	_noise_materials.clear()
	var pickups := prepare_pickups(world.source,world.level,catalog)
	for kind: int in pickups:
		var recipe: Dictionary = pickups[kind]
		_frames[kind] = recipe.frame
		_art[kind] = recipe.art
		if not _materials.has(int(recipe.frame)):
			var ink: ShaderMaterial = recipe.material.duplicate()
			ink.set_shader_parameter("palette_texture", _world.palette.texture)
			_materials[int(recipe.frame)] = ink
	# Four full inventories fit without allocating scene nodes during a death.
	for index: int in range(128):
		_items.append(_new_view())
	for index: int in range(16):
		_departures.append(_new_view())
		var material := ShaderMaterial.new()
		material.shader = preload("res://shaders/native_departure.gdshader")
		_noise_materials.append(material)


func _new_view() -> Node3D:
	var view: Node3D = ActorScene.instantiate()
	add_child(view)
	view.visible = false
	view.configure(_world.source, _world.level, _catalog, _materials)
	return view


func present(state: Dictionary) -> void:
	var items: Array = state.get("items", [])
	var departures: Array = state.get("departures", [])
	while _items.size() < items.size(): _items.append(_new_view())
	for index: int in range(_items.size()):
		var view: Node3D = _items[index]
		view.visible = index < items.size()
		if not view.visible:
			continue
		var item: Dictionary = items[index]
		if not _frames.has(item.kind):
			_frames[item.kind] = Drops.frame_for_kind(_catalog, item.kind)
		if view.get_meta("pickup_kind", -1) != item.kind:
			var art := _pickup_art(int(item.kind))
			view.configure(_world.source, art.level, art.catalog, _materials)
			view.set_meta("pickup_kind", item.kind)
		view.present({"kind": item.kind, "frame": _frames[item.kind],
			"x": item.x, "y": item.y, "height": 128}, _world)
		# Fallback pixels use this world's live palette, including countdown and
		# hit flashes; their source level's palette must not become a frozen bank.
		var material: ShaderMaterial = _materials[int(_frames[item.kind])]
		if material.get_shader_parameter("palette_texture") != _world.palette.texture:
			material.set_shader_parameter("palette_texture", _world.palette.texture)
		view.position.y += float(item.z) * Actor.PIXEL_HEIGHT
	for index: int in range(_departures.size()):
		var view: Node3D = _departures[index]
		view.visible = index < departures.size()
		if not view.visible:
			continue
		var row: Dictionary = departures[index]
		view.present({"kind": 20, "frame": row.frame, "x": row.x, "y": row.y, "height": 128,
			"player_colour": int(row.get("player_colour", 0))}, _world)
		var sprite: Sprite3D = view.get_node("Billboard")
		var noise := _noise_materials[index]
		var original: ShaderMaterial = _materials[int(row.frame)]
		for parameter: String in ["source_indices", "palette_texture", "armour_mask", "armour_ramps", "armour_original", "has_armour_mask"]:
			noise.set_shader_parameter(parameter, original.get_shader_parameter(parameter))
		noise.set_shader_parameter("departure_phase", clampf(row.age / Drops.DEPARTURE_SECONDS, 0, 1))
		sprite.material_override = noise


func _pickup_art(kind: int) -> Dictionary:
	if _art.has(kind):
		return _art[kind]
	var frame := Drops.frame_for_kind(_catalog, kind)
	var result := {"level": _world.level, "catalog": _catalog}
	# Some CD levels omit unused key pixels. Drops carried from another map
	# still need original artwork: resolve another runtime CD level, never export.
	if int(_catalog.frames[frame].offset) <= 0:
		for number: int in range(1, 17):
			var level: Resource = _world.source.load_cd_level("/LEVEL%d.LEV" % number)
			var catalog: Resource = _world.source.load_cd_actor_catalog(level)
			if int(catalog.frames[frame].offset) > 0:
				result = {"level": level, "catalog": catalog}
				break
	_art[kind] = result
	return result


## Finite fallback recipes are resolved once at launch, including keys whose
## source pixels are omitted by this map. No cross-map search happens on death.
static func prepare_pickups(source: RefCounted, level: Resource, catalog: Resource) -> Dictionary:
	var key: String = level.source_sha256 + ":" + catalog.source_sha256
	if _prepared_pickups.has(key): return _prepared_pickups[key]
	var recipes := {}
	for kind: int in range(29,46):
		var frame := Drops.frame_for_kind(catalog,kind)
		if frame == 0: continue
		var art := {"level":level, "catalog":catalog}
		if int(catalog.frames[frame].offset) <= 0:
			for number: int in range(1,17):
				var original_level: Resource = source.load_cd_level("/LEVEL%d.LEV" % number)
				var original_catalog: Resource = source.load_cd_actor_catalog(original_level)
				if int(original_catalog.frames[frame].offset)>0:
					art = {"level":original_level, "catalog":original_catalog}
					break
		var materials := Actor.prepare_materials(source,art.level,art.catalog)
		if materials.has(frame):
			recipes[kind] = {"frame":frame, "art":art, "material":materials[frame]}
	_prepared_pickups[key] = recipes
	return recipes
