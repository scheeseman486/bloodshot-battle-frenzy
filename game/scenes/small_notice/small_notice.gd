extends Control
## Source-backed status text and modal notices, using the settings' logical scale.
signal dismissed(accepted: bool)
const SmallTheme = preload("res://scripts/frontend/native_small_theme.gd")
const Source = preload("res://scripts/assets/original_asset_source.gd")
@export var modal := false
@export var confirmation := false
@export var heading := ""
@export var text := "":
	set(value):
		text = value
		if is_instance_valid(message):
			message.text = value.replace("…", "...")
var font: Font
var message: Label
var connected_devices: Callable = Input.get_connected_joypads
var _canvas: Control
var _body: ScrollContainer
var _accept: Button
var _cancel: Button
var _done := false


func _enter_tree() -> void:
	preload("res://scripts/presentation/sharp_bilinear_ui.gd").apply(self)


func _ready() -> void:
	if font == null:
		var source := Source.new()
		if source.mount(Source.configured_disc_path()):
			var catalog: RefCounted = source.load_cd_small_font()
			if catalog != null:
				font = catalog.native_font()
	if font == null:
		# No original glyphs exist before supported media is available. Use the
		# same OS boundary as the image picker; never substitute a Godot font.
		hide()
		if modal:
			show_message(text)
			cancel.call_deferred()
		return
	mouse_filter = Control.MOUSE_FILTER_STOP if modal else Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if modal:
		var shade := ColorRect.new()
		shade.color = Color(0, 0, 0, 0.85)
		shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(shade)
	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.theme = SmallTheme.make(font)
	add_child(_canvas)
	if modal:
		var panel := Panel.new()
		panel.position = Vector2(8, 8)
		panel.size = Vector2(240, 208)
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_theme_stylebox_override(
			"panel", SmallTheme.box(Color(0.025, 0.035, 0.05), SmallTheme.ACCENT)
		)
		_canvas.add_child(panel)
		var title := _label(heading)
		title.position = Vector2(16, 16)
		title.size = Vector2(224, 18)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_canvas.add_child(title)
	_body = ScrollContainer.new()
	_body.name = "Body"
	_body.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_body.follow_focus = true
	_canvas.add_child(_body)
	message = _label(text.replace("…", "..."))
	message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(message)
	if modal:
		_accept = _button(
			"Trust" if confirmation else "OK", Vector2(36 if confirmation else 88, 194), accept
		)
		if confirmation:
			_cancel = _button("Cancel", Vector2(140, 194), cancel)
		# Trust requires an explicit choice; initial Enter must prefer Cancel.
		(_cancel if confirmation else _accept).grab_focus()
	get_viewport().size_changed.connect(_layout)
	_layout()
	set_process_input(modal)
	set_process_unhandled_input(modal)


func _label(value: String) -> Label:
	var label := Label.new()
	label.theme = _canvas.theme
	label.text = value
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	return label


func _button(value: String, at: Vector2, action: Callable) -> Button:
	var button := Button.new()
	# Establish the bitmap theme before native minimum-size calculation.
	_canvas.add_child(button)
	button.text = value
	button.position = at
	button.size = Vector2(80, 20)
	button.pressed.connect(action)
	return button


func _layout() -> void:
	if not is_instance_valid(_canvas):
		return
	var viewport := get_viewport().get_visible_rect().size
	var height := minf(viewport.y, viewport.x * 0.75)
	_canvas.scale = Vector2(7.0 / 6.0, 1.0) * height / 224.0
	_canvas.position = (
		(viewport - Vector2(256, 224) * _canvas.scale) * 0.5 if modal else Vector2.ZERO
	)
	_body.position = Vector2(16, 40) if modal else Vector2(8, 8)
	_body.size = Vector2(224, 144) if modal else viewport / _canvas.scale - Vector2(16, 16)


func show_message(value: String) -> void:
	text = value
	if font != null:
		show()
	elif DisplayServer.get_name() != "headless":
		OS.alert(value, heading if not heading.is_empty() else "Bloodshot / Battle Frenzy")


func accept() -> void:
	_finish(true)


func cancel() -> void:
	_finish(false)


func _finish(accepted: bool) -> void:
	if _done:
		return
	_done = true
	dismissed.emit(accepted)
	queue_free()


func _confirm_focused() -> void:
	if confirmation and _cancel.has_focus():
		cancel()
	else:
		accept()


func _input(event: InputEvent) -> void:
	if not modal or _done or not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_ESCAPE:
				cancel()
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				_confirm_focused()
			KEY_LEFT, KEY_RIGHT:
				if confirmation:
					(_accept if _cancel.has_focus() else _cancel).grab_focus()
			_:
				return
	elif (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_RIGHT
	):
		cancel()
	elif event is InputEventJoypadButton and event.pressed:
		var devices: Array = connected_devices.call()
		if devices.is_empty() or event.device != int(devices[0]):
			get_viewport().set_input_as_handled()
			return
		match event.button_index:
			JOY_BUTTON_B, JOY_BUTTON_START:
				cancel()
			JOY_BUTTON_A:
				_confirm_focused()
			JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT:
				if confirmation:
					(_accept if _cancel.has_focus() else _cancel).grab_focus()
			_:
				return
	else:
		return
	get_viewport().set_input_as_handled()


func _unhandled_input(_event: InputEvent) -> void:
	if modal and not _done and is_visible_in_tree():
		get_viewport().set_input_as_handled()
