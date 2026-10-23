extends Node3D
## Development entry point for original level inspection. Gameplay parity is
## deliberately separate from this native geometry and camera milestone.

func _ready() -> void:
	$Overlay/Panel/Content/Menu.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/main_menu/main_menu.tscn"))
	if not $World.load_original():
		$Overlay/Panel/Content/Status.text = $World.last_error
		$Player.set_physics_process(false)
		return
	$Overlay/Panel/Content/Status.text = "European Mega CD • LEVEL1 • %d original walls" % $World.level.walls.size()
