extends "res://scripts/frontend/cd_frontend_view.gd"
## Native frontend navigation around the source-backed, pure menu dispatcher.
const Rules = preload("res://scripts/frontend/cd_menu_rules.gd")
const ControlsMenu = preload("res://scenes/controls_menu/controls_menu.tscn")
const Display = preload("res://scripts/presentation/cd_display_settings.gd")
const NetworkSettings = preload("res://scripts/network/network_settings.gd")
const TextEntry = preload("res://scripts/frontend/network_text_entry.gd")
const Flow = preload("res://scripts/frontend/cd_frontend_flow.gd")
var initial_menu := ""
var allow_attract := true
var _exit_confirmation: Control
var _controls_menu: Control
var _menu_items: Array = []
var _startup_language := false
var _automatic_credits := false
var page := "main"
var menu_state := {}
var labels: Array[PackedByteArray] = []
var visible_letters: Array[int] = []
var row_origins: Array[Vector2] = []
var _typing_row := 0
var _typing_tick := 0
var _held := 0xffffffff
var _previous := 0xffffffff
var _pending := 0xffffffff
var _clock := 0.0
var _background_ticks := 0.0
var _ticks := 0
var _idle := 0
var _sound_index := 0
var _credits: Array[PackedByteArray] = []
var _credit_page := 0
var _credit_age := 0
var _credit_closing := 0
var _credit_cancel := false
var _modal: AcceptDialog
var _text_entry: Control


func _ready() -> void:
	if mount_frontend():
		if not initial_menu.is_empty():
			open_menu(initial_menu)
		elif get_tree().get_meta("multiplayer_menu", false):
			get_tree().remove_meta("multiplayer_menu")
			open_menu("multiplayer")
		elif Flow.startup_language:
			Flow.startup_language = false
			_startup_language = true
			open_menu("language")
		elif Flow.automatic_credits:
			Flow.automatic_credits = false
			_automatic_credits = true
			open_menu("options")
			_activate(3)
		else:
			open_menu("main")


func open_menu(name: String) -> void:
	if page == "sound_test" and name != "sound_test":
		$Audio.stop_effects()
		preload("res://scripts/audio/cd_audio_settings.gd").set_source_mode(
			int(Settings.values().sound)
		)
		$Audio.play_track(3, true)
	page = name
	var definition := menu_definition(name)
	# Extend only the native menu instance; the verified CD table stays immutable.
	var items: Array = definition.items.duplicate(true)
	if name == "main":
		items[1] = {"native": "Multiplayer", "choices": 0, "address": 0}
		items.append({"native": "Exit Game", "choices": 0, "address": 0})
	if name == "battle":
		items.append({"native": "Co-op", "choices": 0, "address": 0})
	if name == "preferences":
		items = items.filter(func(item: Dictionary): return int(item.address) != 0x55aaa)
		items.insert(items.size() - 1, {"native": "Input bindings", "choices": 0, "address": 0})
		items.insert(items.size() - 1, {"native": "Video settings", "choices": 0, "address": 0})
	_menu_items = items
	var choices := Settings.values()
	if name == "language":
		# $2DAAC uses English labels even when the current game language differs.
		choices.language = 69
	menu_state = {
		"stage": 2,
		"selected": 0,
		"chosen": 0,
		"ready": true,
		"rows": items.size(),
		"edge": 0xffffffff,
		"items": [],
		"language": choices.language,
		"diagonals": choices.diagonals,
		"sound": choices.sound
	}
	labels.clear()
	visible_letters.clear()
	row_origins.clear()
	for item: Dictionary in items:
		var field: String = {0x55aaa: "diagonals", 0x55aa8: "sound"}.get(int(item.address), "")
		var value := int(choices.get(field, 0))
		if item.has("native_key"):
			value = (
				1
				+ int(
					(
						Display.widescreen()
						if item.native_key == "wide"
						else Display.is_fullscreen(get_window())
					)
				)
			)
		menu_state.items.append({"choices": item.choices, "address": item.address, "value": value})
		if item.has("native"):
			labels.append(
				(
					String(item.native if int(item.choices) == 0 else item.values[value - 1])
					. to_ascii_buffer()
				)
			)
		else:
			var pointer := (
				int(item.text) if int(item.choices) == 0 else int(item.values[maxi(0, value - 1)])
			)
			labels.append(catalog.text_bytes(pointer, int(choices.language)))
		visible_letters.append(0)
	var origin := Vector2(24, int(definition.row) * 8)
	for index: int in range(labels.size()):
		row_origins.append(origin)
		# Placement must share the draw/hit layout, including native Video's
		# single-line choices; the source word reservation adds a false row.
		var layout: Dictionary = label_layout(index)
		origin = Vector2(24, layout.end.y + 24)
	# Native Preferences has another row; keep localized wrapped menus inside
	# the source-height frame without changing glyph scale or row spacing.
	var shift := minf(0.0, 216.0 - origin.y)
	if shift < 0.0:
		for index: int in range(row_origins.size()):
			row_origins[index].y += shift
	_typing_row = 0
	_typing_tick = 8
	_idle = 0
	if name == "sound_test":
		_sound_index = 0
		$Audio.stop_all()
		preload("res://scripts/audio/cd_audio_settings.gd").set_source_mode(2)
	queue_redraw()


func _process(delta: float) -> void:
	if catalog == null or menu_state.is_empty() or _transitioning:
		return
	_clock += delta
	var period := 1070460.0 / 53203424.0
	_background_ticks += delta / period
	while _clock >= period and not _transitioning:
		_clock -= period
		_tick()
	update_background(_ticks, _background_ticks)
	queue_redraw()


func _tick() -> void:
	if _transitioning or is_instance_valid(_controls_menu) or is_instance_valid(_exit_confirmation):
		return
	_ticks += 1
	if is_instance_valid(_modal) or is_instance_valid(_text_entry):
		return
	_idle += 1
	_consume_input_edges()
	if int(menu_state.edge) != 0xffffffff:
		_idle = 0
	if page == "credits":
		if _credit_closing > 0:
			_credit_closing -= 1
			if _credit_closing == 0:
				clearing_text.clear()
				_credit_page += 1
				_credit_age = 0
				if _credit_cancel:
					_automatic_credits = false
					open_menu("main")
				elif _credit_page >= _credits.size():
					if _automatic_credits:
						switch_scene(Flow.begin_demo())
					else:
						open_menu("options")
			return
		_credit_age += 1
		var pressed := (int(menu_state.edge) & 0x70) != 0x70
		if _credit_age > 299 or pressed:
			_close_credit(_automatic_credits and pressed)
		return
	_advance_reveal()
	menu_state.ready = true
	_apply_menu_input()
	if allow_attract and _idle >= 1200:
		if _startup_language:
			_activate(maxi(1, int(menu_state.selected)))
		else:
			switch_scene(Flow.begin_demo())


func _consume_input_edges() -> void:
	menu_state.edge = (_held | (~_previous & 0xffffffff)) & _pending
	_previous = _held
	_pending = 0xffffffff


func _apply_menu_input() -> void:
	if page == "video":
		_sync_video()
	var before: Dictionary = menu_state
	menu_state = Rules.advance(menu_state)
	if page == "sound_test" and int(menu_state.selected) == 1:
		_sound_index = Rules.sound_index(_sound_index, int(menu_state.edge), 37)
	if int(menu_state.selected) != int(before.selected):
		$Audio.play_source(0x2547e)
		if int(menu_state.edge) != 0xffffffff:
			_resolve_row(int(menu_state.selected) - 1)
	if int(menu_state.stage) == 2 and menu_state.items != before.items:
		var index := int(menu_state.selected) - 1
		var item: Dictionary = _menu_items[index]
		if item.has("native_key"):
			var enabled := int(menu_state.items[index].value) == 2
			if item.native_key == "wide":
				Display.set_widescreen(enabled)
				$DisplayOptions/Widescreen.set_pressed_no_signal(enabled)
			else:
				Display.set_fullscreen(get_window(), enabled)
				$DisplayOptions/Fullscreen.set_pressed_no_signal(enabled)
			labels[index] = (
				String(item.values[int(menu_state.items[index].value) - 1]).to_ascii_buffer()
			)
		else:
			Settings.apply(menu_state)
			labels[index] = catalog.text_bytes(
				int(item.values[int(menu_state.items[index].value) - 1]), int(menu_state.language)
			)
		_resolve_row(index)
	if int(menu_state.chosen) != 0:
		_resolve_row(int(menu_state.chosen) - 1)
		_activate(int(menu_state.chosen))


func _activate(row: int) -> void:
	match page:
		"main":
			if row == 1:
				start_campaign()
			elif row == 2:
				open_menu("multiplayer")
			elif row == 3:
				open_menu("options")
			elif row == 4:
				open_exit_confirmation()
		"options":
			if row == 1:
				open_menu("preferences")
			elif row == 2:
				open_menu("sound_test")
			elif row == 3:
				page = "credits"
				_credits = catalog.credit_pages(int(menu_state.language))
				_credit_page = 0
				_credit_age = 0
				_credit_closing = 0
				menu_state.chosen = 0
			elif row == 4:
				if Flow.Scores.shared().rows.is_empty():
					open_menu("main")
				else:
					switch_scene(Flow.show_scores("res://scenes/main_menu/main_menu.tscn"))
			else:
				open_menu("main")
		"preferences":
			if row == 3:
				open_controls()
			elif row == 4:
				open_menu("video")
			else:
				open_menu("language" if row == 1 else "options")
		"language":
			var choices := Settings.values()
			choices.language = [69, 70, 68, 83][row - 1]
			Settings.apply(choices)
			if _startup_language:
				Flow.initialized = true
				switch_scene("res://scenes/title_screen/title_screen.tscn")
			else:
				open_menu("main")
		"sound_test":
			if row == 1:
				$Audio.stop_effects()
				$Audio.play_source(int(catalog.sound_ids()[_sound_index]))
				menu_state.chosen = 0
			else:
				open_menu("options")
		"video":
			open_menu("preferences")
		"multiplayer":
			if row == 4:
				open_menu("main")
				return
			if not NetworkSettings.load_profile():
				show_unavailable(NetworkSettings.last_error)
				return
			if row == 1:
				get_tree().set_meta(
					"network_request",
					{"host": true, "address": "127.0.0.1", "port": str(NetworkSettings.port), "lobby": true}
				)
				switch_scene("res://scenes/network_gameplay/network_gameplay.tscn")
			elif row == 2:
				switch_scene("res://scenes/network_menu/network_menu.tscn")
			elif row == 3:
				open_menu("network_setup")
			else:
				open_menu("main")
		"network_setup":
			if row == 4: open_menu("multiplayer")
			else: open_network_entry(row)
		"battle":
			if row == _menu_items.size():
				switch_scene("res://scenes/network_menu/network_menu.tscn")
			else:
				show_unavailable("Deathmatch remains deferred. Choose Co-op for network play.")


func open_network_entry(row: int) -> void:
	_reset_controls_edges()
	menu_state.chosen = 0
	var dialog := TextEntry.new()
	_text_entry = dialog
	dialog.font = source.load_cd_small_font().native_font()
	dialog.heading = ["Player Name", "Port", "Password"][row - 1]
	dialog.initial = [NetworkSettings.player_name, str(NetworkSettings.port), NetworkSettings.password][row - 1]
	dialog.limit = [NetworkSettings.MAX_NAME, 5, 64][row - 1]
	dialog.secret = row == 3
	dialog.validate = func(value: String) -> String:
		if row == 1:
			var cleaned := value.strip_edges()
			if not NetworkSettings.valid_name(cleaned): return "Use up to 16 printable letters/numbers"
			var before := NetworkSettings.player_name
			NetworkSettings.player_name = cleaned
			if not NetworkSettings.save():
				NetworkSettings.player_name = before
				return "Could not save player name"
		elif row == 2:
			if not value.is_valid_int() or int(value) < 1 or int(value) > 65535: return "Enter a port from 1 to 65535"
			var before := NetworkSettings.port
			NetworkSettings.port = int(value)
			if not NetworkSettings.save():
				NetworkSettings.port = before
				return "Could not save port"
		else:
			if not NetworkSettings.valid_password(value): return "Use up to 64 printable characters"
			NetworkSettings.password = value
		return ""
	dialog.navigation.connect(func(): $Audio.play_source(0x2547e))
	dialog.dismissed.connect(func(_accepted):
		_text_entry = null
		_reset_controls_edges()
		open_menu(network_entry_return()))
	add_child(dialog)


func network_entry_return() -> String:
	return "network_setup"


func show_unavailable(message: String) -> void:
	menu_state.chosen = 0
	var dialog := AcceptDialog.new()
	_modal = dialog
	dialog.title = "Bloodshot / Battle Frenzy"
	dialog.dialog_text = message
	add_child(dialog)
	dialog.popup_centered()
	var dismiss := func() -> void:
		_held = 0xffffffff
		_previous = 0xffffffff
		_pending = 0xffffffff
		dialog.queue_free()
	dialog.confirmed.connect(dismiss)
	dialog.close_requested.connect(dismiss)


func start_campaign() -> void:
	Settings.apply(menu_state)
	get_tree().set_meta("campaign_level", 1)
	get_tree().set_meta("campaign_score_eligible", true)
	switch_scene("res://scenes/campaign/campaign.tscn")


func _draw() -> void:
	if catalog == null or menu_state.is_empty() or is_instance_valid(_exit_confirmation):
		return
	draw_set_transform(frame.position, 0, artwork_scale)
	if page == "credits":
		if _credit_page >= _credits.size():
			draw_set_transform(Vector2.ZERO)
			return
		if _credit_closing > 0:
			draw_clearing_text()
		else:
			draw_bytes(_credits[_credit_page], Vector2(16, 48), _credit_age / 2, 2)
		draw_set_transform(Vector2.ZERO)
		return
	for index: int in range(labels.size()):
		_draw_menu_text(index)
	if int(menu_state.selected) > 0:
		var cursor: Texture2D = catalog.ui.character(255)
		draw_texture(cursor, Vector2(0, row_origins[int(menu_state.selected) - 1].y))
	if page == "sound_test":
		draw_bytes(catalog.sound_name(_sound_index), catalog.sound_origin(_sound_index))
	draw_set_transform(Vector2.ZERO)


func _input(event: InputEvent) -> void:
	if (
		_transitioning
		or is_instance_valid(_modal)
		or is_instance_valid(_text_entry)
		or is_instance_valid(_controls_menu)
		or is_instance_valid(_exit_confirmation)
		or development_shortcut(event)
		or catalog == null
	):
		return
	if _mouse_input(event):
		return
	if event is InputEventKey and not event.echo:
		if event.pressed and event.physical_keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_go_back()
			return
		var bit := int(
			(
				{
					KEY_UP: 1,
					KEY_W: 1,
					KEY_DOWN: 2,
					KEY_S: 2,
					KEY_LEFT: 4,
					KEY_A: 4,
					KEY_RIGHT: 8,
					KEY_D: 8,
					KEY_ENTER: 16,
					KEY_SPACE: 16,
					KEY_Z: 64,
					KEY_X: 16,
					KEY_C: 32
				}
				. get(event.physical_keycode, 0)
			)
		)
		_button(bit, event.pressed)
	elif event is InputEventJoypadButton:
		if event.button_index == JOY_BUTTON_START and event.pressed and page == "main":
			start_campaign()
		else:
			var bit := int(
				(
					{
						JOY_BUTTON_DPAD_UP: 1,
						JOY_BUTTON_DPAD_DOWN: 2,
						JOY_BUTTON_DPAD_LEFT: 4,
						JOY_BUTTON_DPAD_RIGHT: 8,
						JOY_BUTTON_A: 16,
						JOY_BUTTON_B: 64,
						JOY_BUTTON_X: 32
					}
					. get(event.button_index, 0)
				)
			)
			_button(bit, event.pressed)
	elif event is InputEventJoypadMotion:
		if event.axis == JOY_AXIS_LEFT_Y:
			_button(1, event.axis_value < -0.5)
			_button(2, event.axis_value > 0.5)
		elif event.axis == JOY_AXIS_LEFT_X:
			_button(4, event.axis_value < -0.5)
			_button(8, event.axis_value > 0.5)


func _button(bit: int, pressed: bool) -> void:
	if bit == 0:
		return
	if pressed:
		var fresh := (_held & bit) != 0
		if fresh:
			_pending &= ~bit
		_held &= ~bit
		# Dispatch each press in arrival order. Waiting for the reveal clock merged
		# direction/confirm edges and let pointer motion erase queued clicks.
		# Credits retain their timed closing sequence; gameplay clocks are untouched.
		if fresh and page != "credits":
			_consume_input_edges()
			_idle = 0
			menu_state.ready = true
			_apply_menu_input()
	else:
		_held |= bit
	get_viewport().set_input_as_handled()


func _reset_controls_edges() -> void:
	_held = 0xffffffff
	_previous = 0xffffffff
	_pending = 0xffffffff
	menu_state.chosen = 0
	_idle = 0
	_clock = 0.0


func open_controls() -> void:
	if is_instance_valid(_controls_menu):
		return
	_reset_controls_edges()
	_controls_menu = ControlsMenu.instantiate()
	_controls_menu.closed.connect(_controls_closed)
	add_child(_controls_menu)


func _controls_closed(_saved: bool) -> void:
	_controls_menu = null
	_reset_controls_edges()
	queue_redraw()


func row_at_position(position: Vector2) -> int:
	if page == "credits" or not frame.has_point(position):
		return -1
	var point := (position - frame.position) / artwork_scale
	for index: int in range(labels.size()):
		var layout: Dictionary = label_layout(index)
		if point.y >= row_origins[index].y and point.y < layout.end.y + 24:
			return index
	return -1


func _advance_reveal() -> void:
	_seek_unresolved()
	if _typing_row >= labels.size():
		return
	if _typing_tick > 0:
		_typing_tick -= 1
	if _typing_tick > 0:
		return
	var row := _typing_row
	var layout: Dictionary = label_layout(row)
	var index := visible_letters[row]
	var hold := int(layout.pauses.get(index, 2))
	_typing_tick = hold
	visible_letters[row] = labels[row].size() if reveals_whole_rows() else index + 1
	if int(labels[row][index]) > 32:
		$Audio.play_source(0x24d64)
	_seek_unresolved()
	if _typing_row != row:
		_typing_tick += hold


func reveals_whole_rows() -> bool:
	return false


func _seek_unresolved() -> void:
	while (
		_typing_row < labels.size() and visible_letters[_typing_row] >= labels[_typing_row].size()
	):
		_typing_row += 1
		_typing_tick = 6


func _resolve_row(index: int) -> void:
	if index < 0 or index >= labels.size():
		return
	visible_letters[index] = labels[index].size()
	_seek_unresolved()
	queue_redraw()


func _draw_menu_text(index: int) -> void:
	var layout: Dictionary = label_layout(index)
	for command: Dictionary in layout.commands:
		if int(command.code) == 32:
			continue
		var texture: Texture2D = (
			catalog.ui.character(int(command.code))
			if int(command.index) < visible_letters[index]
			else catalog.ui.character_noise(int(command.code), _ticks)
		)
		draw_texture(texture, Vector2(command.x, command.y))


func _mouse_input(event: InputEvent) -> bool:
	if event is InputEventMouseMotion:
		_idle = 0
		var row := row_at_position(event.position)
		if row >= 0:
			# A newer pointer event supersedes unconsumed keyboard/pad edges.
			_pending = 0xffffffff
			_previous = _held
			if int(menu_state.selected) != row + 1:
				$Audio.play_source(0x2547e)
			menu_state.selected = row + 1
			_idle = 0
			_resolve_row(row)
		get_viewport().set_input_as_handled()
		return true
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_go_back()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			var row := row_at_position(event.position)
			if row >= 0 or page == "credits":
				if event.pressed and row >= 0:
					_pending = 0xffffffff
					_previous = _held
					menu_state.selected = row + 1
					_resolve_row(row)
				_button(16, event.pressed)
			elif not event.pressed:
				_button(16, false)
		else:
			return false
		get_viewport().set_input_as_handled()
		return true
	return false


func _go_back() -> void:
	_idle = 0
	_pending = 0xffffffff
	_previous = _held
	if page == "credits":
		_close_credit(true)
	elif _startup_language:
		_activate(maxi(1, int(menu_state.selected)))
	elif _automatic_credits:
		_automatic_credits = false
		open_menu("main")
	elif page == "main":
		switch_scene("res://scenes/title_screen/title_screen.tscn")
	elif page == "video":
		open_menu("preferences")
	elif page == "network_setup":
		open_menu("multiplayer")
	else:
		open_menu("options" if page in ["preferences", "sound_test", "credits"] else "main")


func _sync_video() -> void:
	for index: int in range(2):
		var enabled := Display.widescreen() if index == 0 else Display.is_fullscreen(get_window())
		var value := 1 + int(enabled)
		if int(menu_state.items[index].value) != value:
			menu_state.items[index].value = value
			labels[index] = String(_menu_items[index].values[value - 1]).to_ascii_buffer()
			_resolve_row(index)


func label_layout(index: int) -> Dictionary:
	# Native video choices are short enough for one line. The original writer
	# reserves three cells before wrapping, needlessly splitting the off value.
	return catalog.text_layout(labels[index], row_origins[index], 6, page != "video")


func _close_credit(cancel: bool) -> void:
	if _credit_closing > 0:
		return
	_credit_cancel = cancel
	_credit_closing = 8
	begin_text_clear(
		catalog.text_layout(_credits[_credit_page], Vector2(16, 48), 2).commands.filter(
			func(glyph: Dictionary): return int(glyph.index) < _credit_age / 2
		)
	)


func menu_definition(name: String) -> Dictionary:
	if name == "multiplayer":
		return {
			"row": 9,
			"items":
			[
				{"native": "Host Game", "choices": 0, "address": 0},
				{"native": "Join Game", "choices": 0, "address": 0},
				{"native": "Network Setup", "choices": 0, "address": 0},
				{"native": "Exit", "choices": 0, "address": 0}
			]
		}
	if name == "network_setup":
		var items := []
		for label: String in ["Player Name", "Port", "Password", "Exit"]:
			items.append({"native": label, "choices": 0, "address": 0})
		return {"row": 9, "items": items}
	if name == "video":
		return {
			"row": 9,
			"items":
			[
				{
					"native": "Widescreen",
					"native_key": "wide",
					"choices": 2,
					"address": -1,
					"values": ["widescreen off", "widescreen on"]
				},
				{
					"native": "Fullscreen",
					"native_key": "full",
					"choices": 2,
					"address": -2,
					"values": ["fullscreen off", "fullscreen on"]
				},
				{"native": "Back", "choices": 0, "address": 0}
			]
		}
	return catalog.menus[name]


func open_exit_confirmation() -> void:
	if is_instance_valid(_exit_confirmation) or _transitioning:
		return
	_reset_controls_edges()
	_exit_confirmation = load("res://scenes/exit_confirmation/exit_confirmation.tscn").instantiate()
	_exit_confirmation.cancelled.connect(_cancel_exit)
	_exit_confirmation.confirmed.connect(_confirm_exit)
	add_child(_exit_confirmation)
	queue_redraw()


func _cancel_exit() -> void:
	if is_instance_valid(_exit_confirmation):
		_exit_confirmation.queue_free()
	_exit_confirmation = null
	_reset_controls_edges()
	menu_state.selected = 4
	_resolve_row(3)
	queue_redraw()


func _confirm_exit() -> void:
	if _transitioning:
		return
	_transitioning = true
	quit_game()


func quit_game() -> void:
	# Keep PCM/CD/FM workers alive until the existing lifecycle drains playback.
	preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree())
