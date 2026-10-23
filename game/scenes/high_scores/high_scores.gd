extends "res://scripts/frontend/cd_frontend_view.gd"
## Native CD scoreboard and edge-driven initials. All artwork stays runtime CD data.
const Rules = preload("res://scripts/frontend/cd_high_score_rules.gd")
const Store = preload("res://scripts/frontend/cd_high_score_store.gd")
const Flow = preload("res://scripts/frontend/cd_frontend_flow.gd")
signal completed
var use_flow_request := true
var store: RefCounted
var request := {"level": -1, "power": 0, "cheated": false, "return_path": ""}
var layout := {}
var phase := "unconfigured"
var ticks := 0
var age := 0
var selected_row := -1
var selected_letter := 0
var initials := ""
var _clock := 0.0
var _held := 0xffffffff
var _previous := 0xffffffff
var _pending := 0xffffffff
var _done := false
var _closing := 0


func _ready() -> void:
	if not mount_frontend():
		return
	if store == null:
		store = Store.shared()
	if use_flow_request and not Flow.score_request.is_empty():
		request = Flow.score_request.duplicate()
		Flow.score_request.clear()
	# Flush the transition edge, while preserving held A/B/C. The original
	# display wait accepts held buttons and can retain a blank inserted name.
	for key: Key in [KEY_ENTER, KEY_SPACE, KEY_Z, KEY_X, KEY_C]:
		if Input.is_physical_key_pressed(key):
			_held &= ~16
	for device: int in Input.get_connected_joypads():
		for button: int in [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X]:
			if Input.is_joy_button_pressed(device, button):
				_held &= ~16
	_previous = _held
	if phase != "unconfigured" or not str(request.return_path).is_empty():
		begin()
		if not _done and int(request.get("track", 0)) > 0:
			$Audio.play_track(int(request.track), int(request.track) != 4)
	else:
		# Editor/direct-scene preview is inert and cannot change the open tree.
		layout = catalog.score_layout(store.rows)
		age = int(layout.duration)
	update_background(ticks)


func begin() -> void:
	selected_row = store.qualify(int(request.level), int(request.power), bool(request.cheated))
	layout = catalog.score_layout(store.rows)
	age = 0
	phase = "writing"
	if store.rows.is_empty() or (int(request.level) >= 0 and bool(request.cheated)):
		_finish()


func _process(delta: float) -> void:
	if catalog == null or (_done and _closing == 0) or phase == "unconfigured":
		return
	_clock += delta
	var period := 1070460.0 / 53203424.0
	while _clock >= period and (not _done or _closing > 0):
		_clock -= period
		_tick()
	update_background(float(ticks) + _clock / period)
	queue_redraw()


func _tick() -> void:
	if _closing > 0:
		ticks += 1
		update_text_static(ticks)
		_closing -= 1
		if _closing == 0:
			clearing_text.clear()
			_complete_finish()
		queue_redraw()
		return
	if _done or phase == "unconfigured":
		return
	ticks += 1
	age += 1
	var edge := (_held | (~_previous & 0xffffffff)) & _pending
	_previous = _held
	_pending = 0xffffffff
	if phase == "writing":
		if (_held & 0x70) != 0x70:
			_finish()
			return
		for glyph: Dictionary in layout.commands:
			if int(glyph.tick) == age and int(glyph.code) > 32 and int(glyph.tick) > 1:
				$Audio.play_source(0x24d64)
		if age >= int(layout.duration):
			age = 0
			if selected_row >= 0:
				phase = "entry"
				initials = "A"
				store.set_initials(selected_row, initials)
			else:
				phase = "hold"
	elif phase == "entry":
		var action := Rules.entry_action(edge)
		if action in [-1, 1]:
			initials = (
				initials.left(selected_letter)
				+ String.chr(Rules.letter(initials.unicode_at(selected_letter), action))
			)
			store.set_initials(selected_row, initials)
			age = 0
		elif action == 2:
			selected_letter += 1
			age = 0
			if selected_letter == 3:
				$Audio.play_source(0x17c8c)
				phase = "hold"
			else:
				$Audio.play_source(0x2547e)
				initials += "A"
				store.set_initials(selected_row, initials)
	elif phase == "hold":
		# $315FA consumes 251 observed PAL samples for its 250-tick deadline.
		if age >= 251 or (edge & 0xf0) != 0xf0:
			_finish()
	queue_redraw()


func _cancel() -> void:
	# The source's global Start request bypasses automatic credits after its
	# display-only table ($2DA42). Native Escape uses the same dismissal.
	Flow.automatic_credits = false
	_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	var commands: Array = layout.get("commands", []).filter(
		func(glyph: Dictionary): return phase != "writing" or int(glyph.tick) <= age
	)
	if not initials.is_empty():
		commands.append_array(
			(
				catalog
				. text_layout(initials.to_ascii_buffer(), Vector2(184, 48 + selected_row * 24), 0)
				. commands
			)
		)
	if not commands.is_empty():
		begin_text_clear(commands)
		_closing = 8
		return
	_complete_finish()


func _complete_finish() -> void:
	if not store.last_error.is_empty():
		# Saving failure is visible, while the process-local score is retained.
		var dialog := AcceptDialog.new()
		dialog.title = "High scores"
		dialog.dialog_text = "High-score storage is unavailable. Scores entered during this session remain available until the game closes."
		add_child(dialog)
		dialog.confirmed.connect(_return_to_frontend)
		dialog.close_requested.connect(_return_to_frontend)
		dialog.popup_centered()
	else:
		_return_to_frontend()


func _return_to_frontend() -> void:
	completed.emit()
	if not str(request.return_path).is_empty():
		switch_scene(str(request.return_path))


func _draw() -> void:
	if catalog == null or (_done and _closing == 0):
		return
	draw_set_transform(frame.position, 0, artwork_scale)
	if _closing > 0:
		draw_clearing_text()
		draw_set_transform(Vector2.ZERO)
		return
	for glyph: Dictionary in layout.get("commands", []):
		if (phase != "writing" or int(glyph.tick) <= age) and int(glyph.code) > 32:
			draw_texture(catalog.ui.character(int(glyph.code)), Vector2(glyph.x, glyph.y))
	if selected_row >= 0 and not initials.is_empty():
		var origin := Vector2(184, 48 + selected_row * 24)
		draw_bytes(initials.to_ascii_buffer(), origin, 0x7fffffff, 0)
		if phase == "entry" and age % 24 < 14:
			var end: Vector2 = catalog.text_layout(initials.to_ascii_buffer(), origin, 0).end
			var cursor: Texture2D = catalog.ui.character(255)
			var width := minf(cursor.get_width(), 256 - end.x)
			if width > 0:
				# Three wide letters can reach the source display edge. Keep the
				# cursor inside its artwork frame in a widescreen native window.
				var size := Vector2(width, cursor.get_height())
				draw_texture_rect_region(cursor, Rect2(end, size), Rect2(Vector2.ZERO, size))
	draw_set_transform(Vector2.ZERO)


func _input(event: InputEvent) -> void:
	if _done or development_shortcut(event) or catalog == null or store == null:
		return
	if event is InputEventKey and not event.echo:
		if event.physical_keycode == KEY_ESCAPE and event.pressed:
			get_viewport().set_input_as_handled()
			_cancel()
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
		if (
			event.button_index == JOY_BUTTON_START
			and event.pressed
			and phase in ["writing", "entry", "hold"]
		):
			get_viewport().set_input_as_handled()
			_cancel()
			return
		_button(
			int(
				(
					{
						JOY_BUTTON_DPAD_UP: 1,
						JOY_BUTTON_DPAD_DOWN: 2,
						JOY_BUTTON_DPAD_LEFT: 4,
						JOY_BUTTON_DPAD_RIGHT: 8,
						JOY_BUTTON_A: 16,
						JOY_BUTTON_B: 64,
						JOY_BUTTON_X: 32,
						JOY_BUTTON_START: 128
					}
					. get(event.button_index, 0)
				)
			),
			event.pressed
		)
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
		_pending &= ~bit
		_held &= ~bit
	else:
		_held |= bit
	get_viewport().set_input_as_handled()
