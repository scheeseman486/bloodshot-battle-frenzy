extends "res://scripts/frontend/cd_frontend_view.gd"
## Native slide/caption presentation driven by original PAL timers and CD data.
const Flow = preload("res://scripts/frontend/cd_frontend_flow.gd")
var program: Array[Dictionary] = []
var command_index := 0
var age := 0
var duration := 0
var _clock := 0.0
var _slide := -1
var _previous_slide := -1
var _outgoing := 0
var _overlay := -1
var _caption := PackedByteArray()
var _caption_layout := {}
var _caption_reveal: Array[int] = []
var _held_brightness := 1.0
var _cleanup_ticks := 0
var _cleanup_kind := ""
var _ticks := 0


func begin(parts: Array[String]) -> void:
	background.hide()
	for part: String in parts:
		program.append_array(catalog.startup_program(part, int(Settings.values().language)))
	_enter_command()


func _enter_command() -> void:
	if command_index >= program.size():
		finished()
		return
	# A completed fade survives later wait commands, independent of render calls.
	if command_index > 0 and program[command_index - 1].kind == "fade":
		_held_brightness = 0.0
	age = 0
	var command: Dictionary = program[command_index]
	duration = int(command.hold) + 1  # $3B3AC exits after, rather than at, its deadline.
	match command.kind:
		"slide":
			clearing_text.clear()
			_previous_slide = _slide
			_outgoing = 48 if _slide >= 0 and _held_brightness > 0.0 else 0
			_held_brightness = 1.0
			_slide = (int(command.address) - 0x3b582) / 14
			_overlay = -1
			_caption.clear()
			_caption_layout.clear()
			_caption_reveal.clear()
			if _slide == 4:
				$Audio.play_track(2, true)
		"overlay":
			_overlay = (int(command.address) - 0x3b582) / 14
		"blank":
			_held_brightness = 0.0
			_caption.clear()
			_caption_reveal.clear()
			_slide = -1
			_overlay = -1
		"text":
			_caption = catalog.text_bytes(int(command.address), int(Settings.values().language))
			_caption_layout = catalog.text_layout(_caption, Vector2(0, 200), 0)
			_caption_reveal.clear()
			var tick := 1
			for index: int in range(_caption.size()):
				_caption_reveal.append(tick)
				tick += 16 if _caption_layout.pauses.has(index) else 5
			# $3B34C waits for writing, then adds 49 + D5 and a strict deadline.
			duration = tick + 49 + int(command.hold)
	queue_redraw()


func _process(delta: float) -> void:
	if catalog == null or _transitioning:
		return
	_clock += delta
	var period := 1070460.0 / 53203424.0
	while _clock >= period and not _transitioning:
		_clock -= period
		_tick()
	queue_redraw()


func _tick() -> void:
	if _transitioning:
		return
	_ticks += 1
	update_text_static(_ticks)
	if _cleanup_ticks > 0:
		_cleanup_ticks -= 1
		if _cleanup_ticks == 0:
			clearing_text.clear()
			if _cleanup_kind == "overlay":
				_overlay = -1
			_cleanup_kind = ""
			_advance_command()
		return
	age += 1
	var kind: String = program[command_index].kind
	if kind == "text":
		var index := _caption_reveal.find(age)
		if index >= 0 and int(_caption[index]) > 32:
			$Audio.play_source(0x24d64)
	if age >= duration:
		if kind == "text":
			begin_text_clear(caption_glyphs())
			_caption.clear()
			_caption_reveal.clear()
			_cleanup_kind = "caption"
			_cleanup_ticks = 8
		elif kind == "fade" and _overlay >= 0:
			# Native extension: the CD keeps bank-2 title lettering bright while
			# fading bank 3, then cuts the lettering. Clear it with text noise.
			play_text_clear_sound()
			_cleanup_kind = "overlay"
			_cleanup_ticks = 8
		else:
			_advance_command()


func _advance_command() -> void:
	command_index += 1
	_enter_command()


func overlay_brightness() -> float:
	return 1.0


func overlay_is_noisy() -> bool:
	return _cleanup_kind == "overlay" and _cleanup_ticks > 0


func _caption_limit() -> int:
	var limit := 0
	for tick: int in _caption_reveal:
		if tick > age:
			break
		limit += 1
	return limit


func caption_glyphs() -> Array:
	var commands: Array = []
	if _caption.is_empty():
		return commands
	var limit := _caption_limit()
	var bottom := 200
	for glyph: Dictionary in _caption_layout.commands:
		if int(glyph.index) < limit:
			bottom = maxi(bottom, int(glyph.y))
	for glyph: Dictionary in _caption_layout.commands:
		if int(glyph.index) < limit and int(glyph.y) - bottom + 200 >= 176:
			var command: Dictionary = glyph.duplicate()
			command.y = int(command.y) - bottom + 200
			commands.append(command)
	return commands


func caption_cursor() -> Dictionary:
	if _caption.is_empty():
		return {}
	var point := Vector2(0, 200)
	for glyph: Dictionary in caption_glyphs():
		point = Vector2(int(glyph.x) + catalog.ui.character(int(glyph.code)).get_width(), glyph.y)
	var last := 0
	for tick: int in _caption_reveal:
		if tick > age:
			break
		last = tick
	return {"position": point, "visible": (age - last) % 24 < 14}


## Source stepped picture fade. Separate from drawing for lifecycle checks.
func slide_brightness() -> float:
	var command: Dictionary = program[command_index]
	var brightness := _held_brightness
	if command.kind == "slide":
		if age < _outgoing:
			brightness = clampf(1.0 - floorf(float(age) / 6.0) / 8.0, 0, 1)
		else:
			var delay := 14 if _outgoing > 0 else 0
			brightness = clampf(floorf(float(age - _outgoing - delay) / 6.0) / 8.0, 0, 1)
	elif command.kind == "fade":
		brightness = clampf(1.0 - floorf(float(age) / 6.0) / 8.0, 0, 1)
	return brightness


func _draw() -> void:
	if catalog == null or program.is_empty() or command_index >= program.size():
		return
	var displayed := _slide
	if program[command_index].kind == "slide" and age < _outgoing:
		displayed = _previous_slide
	var brightness := slide_brightness()
	if displayed >= 0:
		draw_slide(displayed, brightness)
	if _overlay >= 0:
		draw_texture_rect(
			catalog.slide(_overlay, true),
			frame,
			false,
			Color.CYAN if overlay_is_noisy() else Color.WHITE
		)
	if not clearing_text.is_empty():
		draw_set_transform(frame.position, 0, artwork_scale)
		draw_clearing_text()
		draw_set_transform(Vector2.ZERO)
	if not _caption.is_empty():
		draw_set_transform(frame.position, 0, artwork_scale)
		for glyph: Dictionary in caption_glyphs():
			if int(glyph.code) != 32:
				draw_texture(catalog.ui.character(int(glyph.code)), Vector2(glyph.x, glyph.y))
		var cursor := caption_cursor()
		if not cursor.is_empty() and cursor.visible:
			var texture: Texture2D = catalog.ui.character(255)
			var size := Vector2(
				minf(texture.get_width(), 256 - cursor.position.x), texture.get_height()
			)
			if size.x > 0:
				draw_texture_rect_region(
					texture, Rect2(cursor.position, size), Rect2(Vector2.ZERO, size)
				)
		draw_set_transform(Vector2.ZERO)


## Startup can replace one image while retaining source timing and fades.
func draw_slide(index: int, brightness: float) -> void:
	draw_texture_rect(catalog.slide(index), frame, false, Color(brightness, brightness, brightness))


func _input(event: InputEvent) -> void:
	if _transitioning or development_shortcut(event):
		return
	var pressed: bool = (
		event is InputEventKey
		and event.pressed
		and not event.echo
		and event.physical_keycode in [KEY_ENTER, KEY_SPACE, KEY_Z, KEY_X, KEY_C, KEY_ESCAPE]
	)
	pressed = (
		pressed
		or (
			event is InputEventJoypadButton
			and event.pressed
			and event.button_index in [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X, JOY_BUTTON_START]
		)
	)
	if pressed:
		get_viewport().set_input_as_handled()
		skipped()


func finished() -> void:
	pass


func skipped() -> void:
	switch_scene("res://scenes/main_menu/main_menu.tscn")
