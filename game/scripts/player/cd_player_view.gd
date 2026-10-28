extends Node3D
## Presentation only: original integer position/heading comes from the session.
const CameraProfile = preload("res://scripts/presentation/cd_projection.gd")
var _view_rect := Rect2()
var _widescreen := false
var _fov := 70.0
const Display = preload("res://scripts/presentation/display_geometry.gd")
const Settings = preload("res://scripts/presentation/cd_display_settings.gd")


func _ready() -> void:
	$Camera.position.y = CameraProfile.WALL_HEIGHT * 0.5
	get_viewport().size_changed.connect(_update_projection)
	_update_projection()


func present(motion: Dictionary, world: Node3D) -> void:
	position = world.visual_point(Vector2(float(motion.x), float(motion.y)))
	rotation.y = -float(motion.angle) * TAU / 16384.0


func set_view_rect(rect: Rect2, wide: bool = false) -> void:
	var fov := Settings.field_of_view()
	if rect == _view_rect and wide == _widescreen and fov == _fov:
		return
	_view_rect = rect
	_widescreen = wide
	_fov = fov
	_update_projection()


func _update_projection() -> void:
	_fov = Settings.field_of_view()
	# 70 is the native setting's reference; its default preserves the measured
	# CD projection exactly. Aspect expansion stays independent of user FOV.
	var horizontal := rad_to_deg(
		2.0 * atan(tan(deg_to_rad(CameraProfile.horizontal_fov()) * 0.5) / Settings.focal_scale())
	)
	var size := get_viewport().get_visible_rect().size
	$Camera.keep_aspect = Camera3D.KEEP_HEIGHT
	if _widescreen:
		# Keep the calibrated vertical world framing. Wider outputs reveal more
		# horizontal geometry; polygons always render with square output pixels.
		$Camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		$Camera.fov = Display.vertical_fov(
			horizontal, 224.0 * CameraProfile.SOURCE_PIXEL_ASPECT / 160.0
		)
		return
	if _view_rect.size.x <= 0.0 or _view_rect.size.y <= 0.0:
		$Camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		$Camera.fov = Display.vertical_fov(horizontal, size.x / maxf(size.y, 1.0))
		return
	# Render native polygons into the source window with an off-axis frustum.
	# This moves the projection centre, not the camera or world geometry. The
	# source artwork is independently aspect-corrected by its own 2D layout.
	var full_width: float = (
		2.0 * $Camera.near * tan(deg_to_rad(horizontal) * 0.5) * size.x / _view_rect.size.x
	)
	var full_height: float = full_width * size.y / maxf(size.x, 1.0)
	var centre := _view_rect.get_center() / size
	$Camera.set_frustum(
		full_height,
		Vector2((0.5 - centre.x) * full_width, (centre.y - 0.5) * full_height),
		$Camera.near,
		$Camera.far
	)
