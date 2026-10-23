@tool
extends EditorPlugin

var _dock: Control

func _enter_tree() -> void:
	# The browser is taller than a typical editor dock. Its scroll wrapper keeps
	# that content minimum from pushing the entire editor below the window.
	_dock = preload("res://addons/original_assets/dock.tscn").instantiate()
	_dock.name = "Original CD"
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)

func _exit_tree() -> void:
	if is_instance_valid(_dock):
		remove_control_from_docks(_dock)
		_dock.queue_free()
