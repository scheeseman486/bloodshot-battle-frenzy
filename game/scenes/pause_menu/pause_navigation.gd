extends "res://scripts/frontend/cd_small_menu_view.gd"
## Native pause pages reuse the frontend's renderer and complete input dispatcher.
signal resumed
signal main_menu_requested
var host: Control
var campaign: Node3D
var _scores: Control
var slots := preload("res://scripts/persistence/save_slots.gd").new()
var _slot := 1
var _slot_page := "save_slots"
var _status := ""
var _failure := ""


func _ready() -> void:
	initial_menu = "pause"
	allow_attract = false
	super._ready()


func menu_definition(name: String) -> Dictionary:
	if name == "pause":
		var items: Array = []
		for label: String in ["New Game", "Save Game", "Load Game", "Options", "Quit to Main Menu"]:
			items.append({"native": label, "choices": 0, "address": 0})
		return {"row": 3, "items": items}
	if name in ["save_slots", "load_slots", "delete_slots"]:
		var items: Array = []
		for number: int in range(1, slots.COUNT + 1):
			var info: Dictionary = slots.describe(number)
			var detail := (
				"Empty"
				if not info.exists
				else ("Level %d" % info.level if info.valid else "Invalid save")
			)
			items.append({"native": "Slot %d - %s" % [number, detail], "choices": 0, "address": 0})
		items.append(
			{
				"native": "Delete a save" if name != "delete_slots" else "Back to slots",
				"choices": 0,
				"address": 0
			}
		)
		items.append({"native": "Back", "choices": 0, "address": 0})
		return {"row": 3, "items": items}
	if name in ["overwrite_save", "delete_save"]:
		return {
			"row": 6,
			"items":
			[
				{"native": "Cancel", "choices": 0, "address": 0},
				{
					"native":
					(
						"Overwrite slot %d" % _slot
						if name == "overwrite_save"
						else "Delete slot %d" % _slot
					),
					"choices": 0,
					"address": 0
				}
			]
		}
	if name == "save_error":
		var items: Array = []
		var line := ""
		for word: String in _failure.split(" "):
			if line.length() + word.length() > 38:
				items.append({"native": line, "choices": 0, "address": 0})
				line = ""
			line += ("" if line.is_empty() else " ") + word
		if not line.is_empty():
			items.append({"native": line, "choices": 0, "address": 0})
		items.append({"native": "Back", "choices": 0, "address": 0})
		return {"row": 3, "items": items}
	return super.menu_definition(name)


func open_menu(name: String) -> void:
	var target := "pause" if name == "main" else name
	super.open_menu(target)
	if background != null:
		background.visible = not uses_small_font()
	if target == "pause":
		$Audio.stop_all()


func _interactive() -> bool:
	return is_instance_valid(host) and host.active and host.accepts_controls and not host._done


func _tick() -> void:
	if not _interactive() or is_instance_valid(_scores):
		return
	super._tick()
	if is_instance_valid(campaign):
		var hud: Control = campaign.get_node("OriginalHud/Hud")
		if hud.widescreen != Display.widescreen():
			campaign.set_widescreen(Display.widescreen())


func _activate(row: int) -> void:
	if page == "pause":
		match row:
			1, 5:
				_transitioning = true
				main_menu_requested.emit.call_deferred()
			2:
				open_menu("save_slots")
			3:
				open_menu("load_slots")
			4:
				open_menu("options")
				$Audio.play_track(3, true)
	elif page in ["save_slots", "load_slots", "delete_slots"]:
		if row == 7:
			open_menu("pause")
		elif row == 6:
			if page == "delete_slots":
				open_menu(_slot_page)
			else:
				_slot_page = page
				open_menu("delete_slots")
		elif row >= 1 and row <= slots.COUNT:
			_slot = row
			if page == "save_slots":
				_slot_page = page
				if slots.describe(row).exists:
					open_menu("overwrite_save")
				else:
					_save_slot()
			elif page == "delete_slots":
				if slots.describe(row).exists:
					open_menu("delete_save")
			else:
				_slot_page = page
				_load_slot()
	elif page in ["overwrite_save", "delete_save"]:
		if row == 2:
			if page == "overwrite_save":
				_save_slot()
			elif slots.delete(_slot):
				_status = "Slot %d deleted" % _slot
				open_menu("delete_slots")
			else:
				_show_failure(slots.last_error)
		else:
			open_menu(_slot_page)
	elif page == "save_error":
		open_menu(_slot_page)
	elif page == "options" and row == 4:
		menu_state.chosen = 0
		if not Flow.Scores.shared().rows.is_empty():
			_scores = load(Flow.SCORE_SCENE).instantiate()
			_scores.store = Flow.Scores.shared()
			_scores.phase = "writing"
			# Do not consume a queued request belonging to another frontend path.
			_scores.use_flow_request = false
			_scores.completed.connect(_scores_closed)
			add_child(_scores)
			_reset_controls_edges()
	else:
		super._activate(row)


func _scores_closed() -> void:
	if is_instance_valid(_scores):
		_scores.queue_free()
	_scores = null
	_reset_controls_edges()
	open_menu("options")


func open_controls() -> void:
	if is_instance_valid(_controls_menu):
		return
	_reset_controls_edges()
	_controls_menu = ControlsMenu.instantiate()
	if is_instance_valid(campaign):
		_controls_menu.input_settings = campaign.input_settings
		_controls_menu.save_handler = campaign.configure_controls
	_controls_menu.closed.connect(_controls_closed)
	add_child(_controls_menu)


func _go_back() -> void:
	_reset_controls_edges()
	if page == "pause":
		resumed.emit.call_deferred()
	elif page in ["overwrite_save", "delete_save", "save_error", "delete_slots"]:
		open_menu(_slot_page)
	elif page in ["options", "save_slots", "load_slots"]:
		open_menu("pause")
	else:
		super._go_back()


func _input(event: InputEvent) -> void:
	if not _interactive() or is_instance_valid(_scores):
		return
	if event is InputEventKey and event.physical_keycode == KEY_F12:
		return  # Campaign owns its independent development panel.
	if event is InputEventJoypadButton and event.button_index == JOY_BUTTON_START:
		if event.pressed and not is_instance_valid(_controls_menu):
			_go_back()
		get_viewport().set_input_as_handled()
		return
	super._input(event)


func uses_small_font() -> bool:
	return (
		page
		in [
			"pause",
			"save_slots",
			"load_slots",
			"delete_slots",
			"overwrite_save",
			"delete_save",
			"save_error"
		]
	)


func small_menu_footer() -> String:
	return "Esc / Start / RMB: resume" if page == "pause" else _status


func small_menu_heading() -> String:
	if page in ["save_slots", "overwrite_save"]:
		return "Save Game"
	if page == "load_slots":
		return "Load Game"
	if page in ["delete_slots", "delete_save"]:
		return "Delete Save"
	return "Unable to complete operation" if page == "save_error" else ""


func _save_slot() -> void:
	if not is_instance_valid(campaign):
		_show_failure("No active offline campaign")
		return
	var bytes: PackedByteArray = campaign.capture_checkpoint()
	if bytes.is_empty():
		_show_failure(campaign.session.world.last_checkpoint_error)
	elif not slots.write(_slot, bytes):
		_show_failure(slots.last_error)
	else:
		_status = "Saved to slot %d" % _slot
		open_menu("save_slots")


func _load_slot() -> void:
	var bytes: PackedByteArray = slots.read(_slot)
	if bytes.is_empty():
		_show_failure(slots.last_error)
		return
	if not is_instance_valid(campaign):
		_show_failure("No active offline campaign")
		return
	# Successful restore replaces this pause view. Do not touch old UI afterwards.
	if not campaign.restore_checkpoint(bytes):
		_show_failure(campaign.session.world.last_checkpoint_error)


func _show_failure(message: String) -> void:
	_failure = message
	_status = ""
	open_menu("save_error")


func _exit_tree() -> void:
	preload("res://scripts/audio/cd_audio_settings.gd").set_source_mode(
		int(Settings.values().sound)
	)
