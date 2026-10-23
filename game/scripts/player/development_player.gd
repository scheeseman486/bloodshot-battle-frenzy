extends CharacterBody3D
## Inspection controls only. Do not use these speeds, gravity or Godot collision
## rounding as claims about the original game's simulation.

const WALK_SPEED := 2.5
const FLY_SPEED := 5.0
const CameraProfile = preload("res://scripts/presentation/cd_projection.gd")
var free_camera: bool = false
var _yaw: float = 0.0
var _pitch: float = 0.0
@onready var camera: Camera3D = $Camera


func _ready() -> void:
	rotation.y = _yaw
	camera.position.y = CameraProfile.WALL_HEIGHT * 0.5
	$Collision.position.y = CameraProfile.WALL_HEIGHT * 0.4
	$Collision.shape.height = CameraProfile.WALL_HEIGHT * 0.8
	get_viewport().size_changed.connect(_update_projection)
	_update_projection()


func _update_projection() -> void:
	var size := get_viewport().get_visible_rect().size
	# Keep measured horizontal coverage as the square-pixel viewport changes.
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.fov = DisplayGeometry.vertical_fov(CameraProfile.horizontal_fov(), size.x / maxf(size.y, 1.0))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * 0.003
		_pitch = clampf(_pitch - event.relative.y * 0.003, -1.3, 1.3)
		rotation.y = _yaw
		camera.rotation.x = _pitch
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if event.physical_keycode == KEY_TAB:
			free_camera = not free_camera
			velocity = Vector3.ZERO
			# Rejoin at floor height to avoid materializing inside the ceiling.
			if not free_camera:
				position.y = 0


func _physics_process(delta: float) -> void:
	var turn := float(Input.is_physical_key_pressed(KEY_LEFT)) - float(Input.is_physical_key_pressed(KEY_RIGHT))
	_yaw += turn * delta * 1.8
	rotation.y = _yaw
	var strafe := float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
	var forward := float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN)) - float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP))
	var direction := basis * Vector3(strafe, 0, forward).normalized()
	if free_camera:
		direction = camera.global_basis * Vector3(strafe, 0, forward).normalized()
		direction.y += float(Input.is_physical_key_pressed(KEY_SPACE)) - float(Input.is_physical_key_pressed(KEY_CTRL))
		position += direction.limit_length() * FLY_SPEED * delta
		return
	velocity.x = direction.x * WALK_SPEED
	velocity.z = direction.z * WALK_SPEED
	velocity.y -= 9.8 * delta
	move_and_slide()


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
