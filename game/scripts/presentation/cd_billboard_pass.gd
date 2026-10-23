extends CanvasLayer
## Native Forward+ billboard composition. Both cameras share the same World3D,
## transforms and projection. Walls/doors occlude actors in the second view;
## floor/ceiling polygons keep their true depth in the main view only.
## No geometry, artwork anchors or sprite positions are changed.
const Layers = preload("res://scripts/presentation/cd_render_layers.gd")
var _camera: Camera3D
var _viewport: Viewport
var _projection: Array = []


func configure(camera: Camera3D) -> void:
	_projection.clear()
	_camera = camera
	_viewport = camera.get_viewport()
	$View.world_3d = _viewport.find_world_3d()
	_camera.cull_mask = Layers.WALLS | Layers.SURFACES
	$View/Camera.cull_mask = Layers.BILLBOARD_OCCLUDERS | Layers.BILLBOARDS
	$Image.texture = $View.get_texture()
	process_priority = 100  # Follow the campaign's presentation update.
	sync_camera()


func _process(_delta: float) -> void:
	if is_instance_valid(_camera):
		sync_camera()


func sync_camera() -> void:
	var dimensions := Vector2i(_viewport.get_visible_rect().size).max(Vector2i(2, 2))
	if $View.size != dimensions:
		$View.size = dimensions
	var view: Camera3D = $View/Camera
	if view.global_transform != _camera.global_transform:
		view.global_transform = _camera.global_transform
	var projection := [
		_camera.projection,
		_camera.keep_aspect,
		_camera.fov,
		_camera.size,
		_camera.frustum_offset,
		_camera.h_offset,
		_camera.v_offset,
		_camera.near,
		_camera.far,
		_camera.attributes
	]
	if projection == _projection:
		return
	_projection = projection
	view.projection = _camera.projection
	view.keep_aspect = _camera.keep_aspect
	view.fov = _camera.fov
	view.size = _camera.size
	view.frustum_offset = _camera.frustum_offset
	view.h_offset = _camera.h_offset
	view.v_offset = _camera.v_offset
	view.near = _camera.near
	view.far = _camera.far
	view.attributes = _camera.attributes
