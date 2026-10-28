@tool
extends Node3D
## Build native polygons and collision directly from original CD wall segments.
## Generated nodes have no scene owner: saving the scene never saves ripped data.

const WallAtlas = preload("res://scripts/presentation/cd_wall_atlas.gd")
const BillboardOccluder = preload("res://scripts/presentation/cd_billboard_occluder.gd")
const Layers = preload("res://scripts/presentation/cd_render_layers.gd")
const Source = preload("res://scripts/assets/original_asset_source.gd")
const CameraProfile = preload("res://scripts/presentation/cd_projection.gd")
const UNITS_PER_METRE := 256.0
const WALL_HEIGHT := CameraProfile.WALL_HEIGHT

static var _prepared: Dictionary = {}
static var preparation_builds := 0

var source := Source.new()
var level: Resource
var palette: RefCounted
var last_error: String = ""
var wall_surface_count: int = 0
var collision_faces := PackedVector3Array()
var moving_chunks: Array[Dictionary] = []
var actor_materials: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		load_original.call_deferred()


func point(position_2d: Vector2i) -> Vector3:
	return visual_point(Vector2(position_2d))


## Presentation may interpolate sub-unit positions; simulation retains integers.
func visual_point(position_2d: Vector2) -> Vector3:
	# Source +Y is forward at the starting heading. Godot looks along -Z.
	# Preserve source +X as camera-right instead of reflecting the entire map.
	return Vector3(
		float(position_2d.x - level.spawn.x) / UNITS_PER_METRE,
		0,
		-float(position_2d.y - level.spawn.y) / UNITS_PER_METRE
	)


func load_original(level_path: String = "/LEVEL1.LEV") -> bool:
	last_error = ""
	level = null
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	wall_surface_count = 0
	collision_faces = PackedVector3Array()
	moving_chunks.clear()
	actor_materials = {}
	if not source.mount(Source.configured_disc_path()):
		last_error = source.last_error
		return false
	if level_path == "/NATIVE/LOBBY":
		var definition := preload("res://scripts/game/world_definition.gd").new()
		if definition.load_manifest(source, {"level": level_path}):
			level = definition.level
	elif level_path.begins_with("/ARENA"):
		level = source.load_cd_arena(level_path)
	else:
		level = source.load_cd_level(level_path)
	if level == null:
		last_error = source.last_error
		return false
	palette = source.load_cd_palette(level)
	if palette == null:
		last_error = source.last_error
		return false
	if _prepared.has(level.source_sha256):
		_install_prepared(_prepared[level.source_sha256])
		return true
	var atlas := WallAtlas.new()
	if not atlas.build(source, level):
		last_error = atlas.last_error
		return false
	var wall_material := ShaderMaterial.new()
	wall_material.shader = preload("res://shaders/cd_palette_wall.gdshader")
	wall_material.set_shader_parameter("source_indices", atlas.texture)
	wall_material.set_shader_parameter("palette_texture", palette.texture)
	var surfaces: Dictionary = {}
	var minimum := Vector3.ZERO
	var maximum := Vector3.ZERO
	for index: int in range(level.walls.size()):
		var wall: Dictionary = level.walls[index]
		var a := point(wall.start)
		var b := point(wall.finish)
		if a.is_equal_approx(b):
			continue
		minimum = minimum.min(a).min(b)
		maximum = maximum.max(a).max(b)
		var group := int(wall.motion_group) if int(wall.motion_kind) != 0 else -1
		var delta: Vector2i = wall.motion_delta if group >= 0 else Vector2i.ZERO
		# Texture changes no longer split native draws or duplicate door bodies.
		# Independent motors/deltas still retain separate meshes and collision.
		var key := Vector3i(group, delta.x, delta.y)
		if not surfaces.has(key):
			var builder := SurfaceTool.new()
			builder.begin(Mesh.PRIMITIVE_TRIANGLES)
			builder.set_material(wall_material)
			surfaces[key] = {
				"builder": builder, "group": group, "delta": delta, "faces": PackedVector3Array()
			}
		var top := Vector3.UP * WALL_HEIGHT
		var vertices := PackedVector3Array([a + top, b + top, b, a + top, b, a])
		var uvs := PackedVector2Array(
			[
				Vector2(0, 0),
				Vector2(1, 0),
				Vector2(1, 1),
				Vector2(0, 0),
				Vector2(1, 1),
				Vector2(0, 1)
			]
		)
		var surface: SurfaceTool = surfaces[key].builder
		for i: int in range(6):
			surface.set_uv(atlas.uv(index, uvs[i]))
			# CD $389C6 sorts projected endpoints before sampling columns;
			# only the map's pointer flag reverses the artwork. Backfaces need
			# their own reflected UVs inside this wall's atlas region.
			surface.set_uv2(atlas.uv(index, Vector2(1.0 - uvs[i].x, uvs[i].y)))
			surface.add_vertex(vertices[i])
		collision_faces.append_array(vertices)
		surfaces[key].faces.append_array(vertices)
	var mesh := ArrayMesh.new()
	var static_faces := PackedVector3Array()
	for entry: Dictionary in surfaces.values():
		var surface: SurfaceTool = entry.builder
		surface.generate_normals()
		if int(entry.group) < 0:
			surface.commit(mesh)
			static_faces.append_array(entry.faces)
		else:
			var moving := MeshInstance3D.new()
			moving.name = "MovingWall_%d_%d" % [entry.group, moving_chunks.size()]
			moving.mesh = surface.commit()
			add_child(moving)
			BillboardOccluder.attach(moving)
			var moving_shape := ConcavePolygonShape3D.new()
			moving_shape.backface_collision = true
			moving_shape.set_faces(entry.faces)
			# Physics is a sibling: the visual motor must never drag collision.
			var collision := _add_collision(
				"MovingWallCollision_%d" % moving_chunks.size(), moving_shape
			)
			moving_chunks.append(
				{"node": moving, "collision": collision, "group": entry.group, "delta": entry.delta}
			)
	var walls := MeshInstance3D.new()
	walls.name = "OriginalWallPolygons"
	walls.mesh = mesh
	add_child(walls)
	BillboardOccluder.attach(walls)
	wall_surface_count = mesh.get_surface_count() + moving_chunks.size()
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(static_faces)
	_add_collision("OriginalWallCollision", shape)
	# Native surfaces remain real geometry for future floor/ceiling textures.
	# Their depth belongs to the main view, not the separate billboard pass.
	var floor_size := Vector2(maximum.x - minimum.x + 2, maximum.z - minimum.z + 2)
	for height: float in [0.0, WALL_HEIGHT]:
		var plane := MeshInstance3D.new()
		plane.layers = Layers.SURFACES
		plane.name = "Floor" if height == 0 else "Ceiling"
		plane.position = (minimum + maximum) * 0.5 + Vector3(0, height, 0)
		var plane_mesh := PlaneMesh.new()
		plane_mesh.size = floor_size
		var material := ShaderMaterial.new()
		material.shader = preload("res://shaders/cd_palette_surface.gdshader")
		material.set_shader_parameter("palette_texture", palette.texture)
		# CD $37E94 fills the lower underlay with tile 233, bank 2, colour 5
		# (37). Its transparent upper area exposes backdrop colour 0.
		material.set_shader_parameter("color_index", 37 if height == 0 else 0)
		plane_mesh.material = material
		plane.mesh = plane_mesh
		add_child(plane)
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(floor_size.x, 0.1, floor_size.y)
	var floor_body := _add_collision("FloorCollision", floor_shape)
	floor_body.position = (minimum + maximum) * 0.5 - Vector3(0, 0.05, 0)
	return _capture_prepared()


func set_palette_bank(bank: int) -> void:
	if palette == null or bank == int(palette.bank):
		return
	palette.set_bank(bank)


## Collision preserves the exact source shift/rounding. Visual fractions are
## evaluated independently and retain sub-unit precision, including depth proxies.
func set_door_states(groups: Array, visual_groups: Array = []) -> void:
	for chunk: Dictionary in moving_chunks:
		var index := int(chunk.group)
		var fraction := int(groups[index].fraction)
		var delta: Vector2i = chunk.delta
		var offset := Vector2i((delta.x * fraction) >> 12, (delta.y * fraction) >> 12)
		var position_3d := Vector3(
			float(offset.x) / UNITS_PER_METRE, 0, -float(offset.y) / UNITS_PER_METRE
		)
		chunk.collision.position = position_3d
		if visual_groups.is_empty():
			chunk.node.position = position_3d
		else:
			var visual_offset := Vector2(delta) * float(visual_groups[index].fraction) / 4096.0
			chunk.node.position = Vector3(
				visual_offset.x / UNITS_PER_METRE, 0, -visual_offset.y / UNITS_PER_METRE
			)


func _add_collision(node_name: String, shape: Shape3D, parent: Node = null) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)
	if parent == null:
		parent = self
	parent.add_child(body)
	return body


## Packed native geometry stays in RAM only. Mesh/shape resources are immutable;
## nodes, door transforms and palette-bound materials belong to each attachment.
func _capture_prepared() -> bool:
	var template := Node3D.new()
	for child: Node in get_children():
		var copy := child.duplicate(0)
		template.add_child(copy)
		_own_geometry(copy, template)
	var packed := PackedScene.new()
	if packed.pack(template) != OK:
		template.free()
		last_error = "Could not prepare native map geometry"
		return false
	template.free()
	var motors := []
	for chunk: Dictionary in moving_chunks:
		motors.append({"node": NodePath(chunk.node.name), "collision": NodePath(chunk.collision.name),
			"group":chunk.group, "delta":chunk.delta})
	_prepared[level.source_sha256] = {"scene":packed, "motors":motors,
		"faces":collision_faces.duplicate(), "surfaces":wall_surface_count}
	preparation_builds += 1
	return true


func _own_geometry(node: Node, template: Node) -> void:
	node.owner = template
	for child: Node in node.get_children(): _own_geometry(child, template)


func _install_prepared(prepared: Dictionary) -> void:
	var template: Node = prepared.scene.instantiate()
	var materials := {}
	for child: Node in template.get_children():
		_own_geometry(child, null)
		template.remove_child(child)
		add_child(child)
		_bind_palette(child, materials)
	template.free()
	collision_faces = prepared.faces.duplicate()
	wall_surface_count = prepared.surfaces
	for motor: Dictionary in prepared.motors:
		moving_chunks.append({"node":get_node(motor.node), "collision":get_node(motor.collision),
			"group":motor.group, "delta":motor.delta})


func _bind_palette(node: Node, materials: Dictionary) -> void:
	if node is MeshInstance3D and node.mesh != null:
		var original: Material = node.get_active_material(0) if node.mesh.get_surface_count() > 0 else null
		if original is ShaderMaterial and original.get_shader_parameter("palette_texture") != null:
			var key := original.get_instance_id()
			if not materials.has(key):
				materials[key] = original.duplicate()
				materials[key].set_shader_parameter("palette_texture", palette.texture)
			node.material_override = materials[key]
	for child: Node in node.get_children(): _bind_palette(child, materials)
