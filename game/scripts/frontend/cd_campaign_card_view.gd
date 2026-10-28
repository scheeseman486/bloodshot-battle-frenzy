extends "res://scripts/frontend/cd_frontend_view.gd"
## Native campaign cards. Only presentation clocks advance while gameplay waits.
const Rules = preload("res://scripts/frontend/cd_campaign_card_rules.gd")
signal completed(action: String)
signal music_changed(track: int)
var result := {"level": 1, "kills": 0, "bonuses": 0, "tally": 0, "credits": 3}
var phase := "clear"
var pages: Array[Dictionary] = []
var page_index := 0
var age := 0
var ticks := 0
var deadline := 250
var layout := {}
var _clock := 0.0
var _pending := 0xffffffff
var _held := 0xffffffff
var _previous := 0xffffffff
var _done := false
var _closing := 0
var _close_age := 0
var _summary := false
var _background_epoch := 0
var _continuation_exit := ""
var _palette_phase := ""


func _ready() -> void:
	if not mount_frontend():
		return
	# Cover the underlying native 3D view, including letterbox space.
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	black.show_behind_parent = true
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(black)
	move_child(black, 0)
	# Card waits flush edges; continuation still observes a button held from
	# gameplay. Initialize both samples together so a held fire cannot skip
	# the first clear card but can accept the original held-button continue.
	for key: Key in [KEY_ENTER, KEY_SPACE, KEY_Z, KEY_X, KEY_C, KEY_ESCAPE]:
		if Input.is_physical_key_pressed(key):
			_held &= ~16
	for device: int in Input.get_connected_joypads():
		for button: int in [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X]:
			if Input.is_joy_button_pressed(device, button):
				_held &= ~16
	_previous = _held
	begin()
	_update_background()


func begin() -> void:
	pages = catalog.campaign_pages(int(result.level), int(result.kills), int(result.bonuses))
	if phase != "clear":
		_begin_continuation()
	else:
		_open_page()


func _open_page() -> void:
	age = 0
	clearing_text.clear()
	deadline = ticks + 250
	layout = catalog.campaign_layout(pages[page_index], int(Settings.values().language))
	refresh_score_layout()
	queue_redraw()


func _begin_continuation() -> void:
	pages.clear()
	layout.clear()
	age = 0
	if int(result.credits) > 0:
		phase = "continue"
		_background_epoch = ticks
		music_changed.emit(15)
		$Audio.play_track(15, false)
	else:
		_begin_summary()


func _begin_summary() -> void:
	phase = "summary"
	_background_epoch = ticks
	_summary = true
	pages = catalog.campaign_pages(
		int(result.level),
		int(result.kills),
		int(result.bonuses),
		0 if bool(result.get("scoring_disabled",false)) else Rules.power_rating(int(result.tally)),
		true
	)
	page_index = 0
	music_changed.emit(4)
	$Audio.play_track(4, false)
	_open_page()


func refresh_score_layout() -> void:
	if bool(result.get("scoring_disabled",false)) and page_index==1 and phase!="continue":
		layout={"commands":[],"duration":0}


func _process(delta: float) -> void:
	if catalog == null or _done:
		return
	_clock += delta
	var period := 1070460.0 / 53203424.0
	while _clock >= period and not _done:
		_clock -= period
		_tick()
	_update_background()
	queue_redraw()


func _tick() -> void:
	if _done:
		return
	ticks += 1
	age += 1
	var edge := (_held | (~_previous & 0xffffffff)) & _pending
	_previous = _held
	_pending = 0xffffffff
	_update_background()
	if not _continuation_exit.is_empty():
		_closing -= 1
		if _closing == 0:
			var action := _continuation_exit
			_continuation_exit = ""
			clearing_text.clear()
			if action == "summary":
				_begin_summary()
			else:
				_finish(action)
		return
	if phase == "continue":
		# $31776 accepts held A/B/C, rather than Start or direction edges.
		if (_held & 0x70) != 0x70:
			_close_continuation("continue")
		elif age >= 1000:
			$Audio.play_source(0x24d64)
			_close_continuation("summary")
		elif age % 50 == 0:
			$Audio.play_source(0x24d64)
		return
	if _closing > 0:
		_closing -= 1
		if _closing == 0:
			_next_page()
		return
	for glyph: Dictionary in layout.commands:
		if int(glyph.tick) == age and int(glyph.code) > 32:
			$Audio.play_source(0x24d64)
	if Rules.ready(ticks, deadline, edge, age < int(layout.duration)):
		begin_text_clear(
			layout.commands.filter(func(glyph: Dictionary): return int(glyph.tick) <= age)
		)
		_close_age = age
		_closing = 10  # Bounded native replacement for queued graphics cleanup.


func _update_background() -> void:
	update_text_static(ticks)
	if noise == null:
		return
	var elapsed := ticks - _background_epoch
	noise.set_shader_parameter("phase", float(elapsed))
	# Shared source palette rule; retain each card's explicit original start colour.
	if _palette_phase != phase:
		_palette_phase = phase
		var initial := ((int(result.level) * 82) % 199) % 24
		var rgb := Vector3i(-1,-1,-1)
		if phase == "continue": rgb = Vector3i(4,15,8)
		elif phase == "summary": rgb = Vector3i(15,0,0)
		_background_palette.configure(catalog.noise_targets(), initial, rgb)
		noise.set_shader_parameter("colour_palette", _background_palette.texture)
	# Palette time is continuous between card ticks. The phase epoch and source
	# start colours still come from the existing card flow and saved clock.
	_background_palette.advance(float(elapsed) + _clock * 53203424.0 / 1070460.0, true)


func _next_page() -> void:
	page_index += 1
	if page_index < pages.size():
		_open_page()
	elif _summary:
		_finish("finished")
	elif int(result.level) < 16:
		_finish("next")
	else:
		_begin_continuation()


func _finish(action: String) -> void:
	if _done:
		return
	_done = true
	completed.emit(action)


func _draw() -> void:
	if catalog == null or _done:
		return
	draw_set_transform(frame.position, 0, artwork_scale)
	if bool(result.get("scoring_disabled",false)) and page_index==1 and phase!="continue":
		var font: Font=source.load_cd_small_font().native_font()
		for line: Array in [["Scoring disabled",104],["Cheats enabled",122]]:
			var text: String=line[0]
			var width:=font.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,12).x
			draw_string(font,Vector2((256-width)*0.5,float(line[1])),text,HORIZONTAL_ALIGNMENT_LEFT,-1,12,Color.WHITE)
	elif _closing > 0:
		draw_clearing_text()
	elif phase == "continue":
		for glyph: Dictionary in _continuation_commands():
			if int(glyph.code) > 32:
				draw_texture(catalog.ui.character(int(glyph.code)), Vector2(glyph.x, glyph.y))
	else:
		for glyph: Dictionary in layout.get("commands", []):
			if int(glyph.tick) <= (_close_age if _closing > 0 else age) and int(glyph.code) > 32:
				var texture: Texture2D = catalog.ui.character(int(glyph.code))
				if texture != null:
					draw_texture(texture, Vector2(glyph.x, glyph.y))
	draw_set_transform(Vector2.ZERO)


func _input(event: InputEvent) -> void:
	if _done:
		return
	var bit := 0
	var pressed := false
	if event is InputEventKey and not event.echo:
		bit = (
			16
			if event.physical_keycode in [KEY_ENTER, KEY_SPACE, KEY_Z, KEY_X, KEY_C, KEY_ESCAPE]
			else 0
		)
		pressed = event.pressed
	elif event is InputEventJoypadButton:
		bit = {JOY_BUTTON_A: 16, JOY_BUTTON_B: 64, JOY_BUTTON_X: 32, JOY_BUTTON_START: 128}.get(
			event.button_index, 0
		)
		pressed = event.pressed
	if bit == 0:
		return
	if pressed:
		_held &= ~bit
		_pending &= ~bit
	else:
		_held |= bit
	get_viewport().set_input_as_handled()


func _continuation_commands() -> Array:
	var credits: PackedByteArray = catalog.text_bytes(0x33ad4, int(Settings.values().language))
	credits.append_array((" %d" % int(result.credits)).to_ascii_buffer())
	var counter := str(maxi(1, 20 - age / 50)).to_ascii_buffer()
	var commands: Array = []
	for line: Array in [[credits, 64], [counter, 120]]:
		var text: PackedByteArray = line[0]
		var width: float = catalog.text_layout(text, Vector2.ZERO).end.x
		commands.append_array(
			catalog.text_layout(text, Vector2((256 - width) * 0.5, line[1])).commands
		)
	return commands


func _close_continuation(action: String) -> void:
	_continuation_exit = action
	_closing = 8
	begin_text_clear(_continuation_commands())
