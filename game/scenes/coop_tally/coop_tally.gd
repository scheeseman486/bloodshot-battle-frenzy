extends "res://scripts/frontend/cd_frontend_view.gd"
const ParticipantLabels = preload("res://scripts/presentation/participant_labels.gd")
## Read-only server result. UI time can reveal rows; it never awards points.
signal completed(action: String)
var result := {"level": 1, "players": []}
var phase := "clear"
var final_result := false
var completion_action := "next"
var local_reference := {}
var _font: FontFile
var _age := 0.0
var _done := false
var _details := true
var _canvas: Control
var _body: Control
var _continue: Button
var _details_button: Button
var _blocked_keys: Array = []
var _blocked_buttons: Array = []


func _ready() -> void:
	if not mount_frontend():
		return
	_font = source.load_cd_small_font().native_font()
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	black.show_behind_parent = true
	add_child(black)
	move_child(black, 0)
	# The source background shader writes its own color, so dim it with a
	# separate native layer rather than modulating its ignored canvas color.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.76)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	_canvas = Control.new()
	_canvas.theme = preload("res://scripts/frontend/native_small_theme.gd").make(_font)
	add_child(_canvas)
	_body = Control.new()
	_canvas.add_child(_body)
	_details_button = Button.new()
	_details_button.position = Vector2(6, 198)
	_details_button.size = Vector2(103, 18)
	_details_button.pressed.connect(_toggle_details)
	_canvas.add_child(_details_button)
	_continue = Button.new()
	_continue.position = Vector2(116, 198)
	_continue.size = Vector2(134, 18)
	_continue.text = "Continue"
	_continue.pressed.connect(_finish)
	_canvas.add_child(_continue)
	for key: int in [KEY_ENTER, KEY_SPACE]:
		if Input.is_physical_key_pressed(key):
			_blocked_keys.append(key)
	for device: int in Input.get_connected_joypads():
		for button: int in [JOY_BUTTON_A, JOY_BUTTON_START]:
			if Input.is_joy_button_pressed(device, button):
				_blocked_buttons.append(Vector2i(device, button))
	_continue.disabled = true
	_refresh()
	_layout()
	_details_button.grab_focus()


func _layout() -> void:
	super._layout()
	if is_instance_valid(_canvas):
		_canvas.position = frame.position
		_canvas.scale = artwork_scale


func _label(
	text: String, position: Vector2, width: float, right: bool = false, ink: Color = Color.WHITE
) -> void:
	var label := Label.new()
	_body.add_child(label)
	label.text = text
	label.position = position
	label.size = Vector2(width, 12)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT
	label.add_theme_color_override("font_color", ink)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)


func _number(value: int) -> String:
	# Abbreviate only presentation; snapshots keep exact integer scores.
	for unit: Array in [[1000000000.0, "b"], [1000000.0, "m"], [1000.0, "k"]]:
		if absi(value) >= maxf(float(unit[0]), 10000.0):
			var scaled := float(value) / float(unit[0])
			return ("%.1f" if absf(scaled) < 10 else "%.0f") % scaled + str(unit[1])
	return str(value)


func _refresh() -> void:
	for child: Node in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	_details_button.text = "Standings" if _details else "Breakdown"
	_details_button.position.x = 77 if _details else 6
	_continue.visible = not _details
	var final := final_result
	_label(
		(
			("CAMPAIGN COMPLETE" if int(result.level) == 16 else "GAME OVER")
			if final
			else "LEVEL %d COMPLETE" % int(result.level)
		),
		Vector2(12, 9),
		238
	)
	_body.get_child(0).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if _details:
		_draw_details()
	else:
		_draw_standings(final)


func _draw_standings(final: bool) -> void:
	var columns := [8.0, 29.0, 70.0, 123.0, 157.0, 209.0]
	var widths := [18.0, 35.0, 51.0, 30.0, 49.0, 39.0]
	var headings := ["#", "Player", "Total" if final else "Score", "Kills", "Damage", "Died"]
	for column: int in range(columns.size()):
		_label(headings[column], Vector2(columns[column], 39), widths[column], column >= 2)
	for index: int in range(result.players.size()):
		var row: Dictionary = result.players[index]
		var ink := Color(1, 0.15, 0.15) if row.reference == local_reference else Color.WHITE
		if not str(row.get("name", "")).is_empty():
			_label(row.name, Vector2(29, 50 + index * 26), 219, false, ink)
		var values := [
			str(row.rank),
			ParticipantLabels.label(result.players, row.seat, row.get("controller", "human") == "bot", row.reference, true),
			_number(row.total if final else row.points),
			_number(row.stats.kills),
			_number(row.stats.damage),
			_number(row.stats.deaths)
		]
		for column: int in range(columns.size()):
			_label(
				values[column],
				Vector2(columns[column], 62 + index * 26),
				widths[column],
				column >= 2,
				ink
			)
	_label("Equal scores share a rank.", Vector2(8, 172), 240)
	_label("Breakdown: bonuses and penalties", Vector2(8, 184), 240)


func _draw_details() -> void:
	var fields := [
		"Damage",
		"Kills x100",
		"Reactor",
		"Speedy",
		"Friendly fire",
		"Doofus",
		"Slowpoke",
		"Cremated",
		"Lives",
		"Battle Frenzy",
		"Level score",
		"Campaign"
	]
	var bonus_keys := ["reactor", "speedy", "friendly", "doofus", "slowpoke", "cremated", "lives", "frenzy"]
	var visible_rows: Array[int] = [0, 1]
	for bonus_index: int in range(bonus_keys.size()):
		var bonus_key: String = bonus_keys[bonus_index]
		if result.players.any(func(row): return int(row.bonuses[bonus_key]) != 0):
			visible_rows.append(bonus_index + 2)
	visible_rows.append_array([10, 11])
	for row_index: int in range(visible_rows.size()):
		_label(fields[visible_rows[row_index]], Vector2(6, 45 + row_index * 12), 80)
	for index: int in range(result.players.size()):
		var row: Dictionary = result.players[index]
		var left := 88.0 + index * 40.0
		var ink := Color(1, 0.15, 0.15) if row.reference == local_reference else Color.WHITE
		_label(ParticipantLabels.label(result.players, row.seat, row.get("controller", "human") == "bot", row.reference, true), Vector2(left, 27), 38, true, ink)
		var values := [
			row.stats.damage,
			int(row.stats.kills) * 100,
			row.bonuses.reactor,
			row.bonuses.speedy,
			row.bonuses.friendly,
			row.bonuses.doofus,
			row.bonuses.slowpoke,
			row.bonuses.cremated,
			row.bonuses.lives,
			row.bonuses.frenzy,
			row.points,
			row.total
		]
		for row_index: int in range(visible_rows.size()):
			var field_index: int = visible_rows[row_index]
			var value := int(values[field_index])
			# Keep shared columns aligned, but only show awards a player received.
			if field_index >= 2 and field_index < 10 and value == 0:
				continue
			_label(_number(value), Vector2(left, 45 + row_index * 12), 38, true, ink)


func _process(delta: float) -> void:
	_age += maxf(delta, 0)
	_continue.disabled = _age < 0.3 or _done
	update_background(_age * 53203424.0 / 1070460.0)


func _toggle_details() -> void:
	if _done:
		return
	_details = not _details
	_refresh()
	if _details:
		_details_button.grab_focus()
	else:
		_continue.grab_focus()


func _confirm() -> void:
	# Confirmation follows the visible focused action on either page.
	if _details or _details_button.has_focus():
		_toggle_details()
	else:
		_finish()


func _finish() -> void:
	if (
		_details or _done or _age < 0.3
		or not _blocked_keys.is_empty() or not _blocked_buttons.is_empty()
	):
		return
	_done = true
	_continue.disabled = true
	_continue.text = "Waiting..."
	completed.emit(completion_action)


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if not event.pressed:
			_blocked_keys.erase(event.physical_keycode)
		elif not event.echo:
			if event.physical_keycode in [KEY_TAB, KEY_LEFT, KEY_RIGHT]:
				_toggle_details()
			elif (
				event.physical_keycode in [KEY_ENTER, KEY_SPACE]
				and not event.physical_keycode in _blocked_keys
			):
				_confirm()
			else:
				return
	elif event is InputEventJoypadButton:
		var identity := Vector2i(event.device, event.button_index)
		if not event.pressed:
			_blocked_buttons.erase(identity)
		elif event.button_index == JOY_BUTTON_X:
			_toggle_details()
		elif (
			event.button_index in [JOY_BUTTON_A, JOY_BUTTON_START]
			and identity not in _blocked_buttons
		):
			_confirm()
	else:
		return  # Native GUI owns mouse hit testing and focus navigation.
	get_viewport().set_input_as_handled()
