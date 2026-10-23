extends Node3D
## Reconciles source actor slots with independently inspectable native scenes.
const ActorScene = preload("res://scenes/actors/cd_actor.tscn")
var views: Array[Node3D] = []
var _world: Node3D
var _catalog: Resource
var _materials: Dictionary = {}


func configure(world: Node3D, catalog: Resource) -> void:
	_world = world
	_catalog = catalog
	for view: Node3D in views:
		remove_child(view)
		view.queue_free()
	views.clear()
	if world.actor_materials.is_empty():
		world.actor_materials = preload("res://scenes/actors/cd_actor.gd").materials_for(world.source, world.level, catalog)
	_materials = world.actor_materials
	# The original pool is bounded at 180. Instantiate during map attachment,
	# rather than pausing the first gameplay draw or a later projectile birth.
	while views.size() < 180:
		_add_view()


func present(actors: Array, presentation_tick: float = 0.0) -> void:
	while views.size() < actors.size():
		_add_view()
	for index: int in range(views.size()):
		if index < actors.size():
			views[index].present(actors[index], _world, presentation_tick)
		else:
			views[index].visible = false


func _add_view() -> void:
	var view := ActorScene.instantiate()
	view.name = "Actor_%03d" % views.size()
	view.visible = false
	add_child(view)
	view.configure(_world.source, _world.level, _catalog, _materials)
	views.append(view)
