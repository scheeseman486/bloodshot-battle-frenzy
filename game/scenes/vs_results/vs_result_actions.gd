extends "res://scripts/frontend/cd_small_menu_view.gd"
## Result verbs reuse the ordinary menu renderer, reveal, cues and dispatcher.
## The parent owns input routing so modal menus cannot dispatch an event twice.
signal completed(action: String)
signal back_requested


func _ready() -> void:
	initial_menu = "vs_results"
	allow_attract = false
	super._ready()
	background.hide()
	set_process_input(false)
	menu_state.selected = 1
	_resolve_row(0)


func menu_definition(_name: String) -> Dictionary:
	return {"row": 23, "items": [
		{"native":"Rematch", "choices":0, "address":0},
		{"native":"Go to Lobby", "choices":0, "address":0}]}


func _layout_small_rows() -> void:
	super._layout_small_rows()
	for index: int in range(row_origins.size()):
		row_origins[index].y = 191 + index * 14


func _process(delta: float) -> void:
	if is_visible_in_tree() and can_process():
		super._process(delta)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not can_process(): return
	if event is InputEventJoypadButton and event.button_index in [JOY_BUTTON_B, JOY_BUTTON_START]:
		if event.pressed: _go_back()
		get_viewport().set_input_as_handled()
		return
	super._input(event)


func _activate(row: int) -> void:
	if _transitioning or row not in [1, 2]: return
	_transitioning = true
	completed.emit.call_deferred("rematch" if row == 1 else "lobby")


func _go_back() -> void:
	_reset_controls_edges()
	back_requested.emit.call_deferred()


func development_shortcut(_event: InputEvent) -> bool:
	return false
