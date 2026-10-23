@tool
extends EditorPlugin
## Enabled only in the disposable export checkout by tools/export_build.py.
var _exporter: EditorExportPlugin


func _enter_tree() -> void:
	_exporter = preload("res://addons/bloodshot_export/runtime_data_export.gd").new()
	add_export_plugin(_exporter)


func _exit_tree() -> void:
	if _exporter != null:
		remove_export_plugin(_exporter)
	_exporter = null
