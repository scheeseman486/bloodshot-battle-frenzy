extends "res://scripts/frontend/cd_small_menu_view.gd"
## Native confirmation. Opening input cannot accept; Cancel is selected initially.
signal cancelled
signal confirmed
var _done := false


func _ready() -> void:
	initial_menu = "exit_confirmation"
	allow_attract = false
	super._ready()
	menu_state.selected = 1
	_resolve_row(0)


func menu_definition(name: String) -> Dictionary:
	return {
		"row": 10,
		"items":
		[
			{"native": "Cancel", "choices": 0, "address": 0},
			{"native": "Exit Game", "choices": 0, "address": 0}
		]
	}


func small_menu_heading() -> String:
	return "Exit Game?"


func small_menu_footer() -> String:
	return "Esc / B / RMB: cancel"


func _activate(row: int) -> void:
	if _done:
		return
	_done = true
	_transitioning = true
	if row == 2:
		confirmed.emit.call_deferred()
	else:
		cancelled.emit.call_deferred()


func _go_back() -> void:
	_activate(1)


func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton and event.button_index in [JOY_BUTTON_B, JOY_BUTTON_START]:
		if event.pressed:
			_go_back()
		get_viewport().set_input_as_handled()
		return
	super._input(event)
