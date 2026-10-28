extends Control
## A modal keyboard editor in the game's original small bitmap font.
signal dismissed(accepted: bool)
signal navigation
var editor: LineEdit
var message: Label
var validate: Callable
var heading := ""
var initial := ""
var limit := 16
var secret := false
var font: Font
var _canvas: Control
var _done := false


func _enter_tree() -> void:
	preload("res://scripts/presentation/sharp_bilinear_ui.gd").apply(self)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.85)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	_canvas = Control.new()
	_canvas.theme = preload("res://scripts/frontend/native_small_theme.gd").make(font)
	add_child(_canvas)
	_label(heading, Vector2(16, 69))
	editor = LineEdit.new()
	# Inherit the bitmap font before native minimum-size calculation.
	_canvas.add_child(editor)
	editor.position = Vector2(16, 91)
	editor.size = Vector2(224, 20)
	editor.text = initial
	editor.max_length = limit
	editor.secret = secret
	editor.secret_character = "*"
	editor.virtual_keyboard_enabled = true
	# Invalid Enter submissions must retain focus after the native signal returns.
	editor.keep_editing_on_text_submit = true
	editor.add_theme_color_override("font_color", Color.WHITE)
	editor.add_theme_color_override("caret_color", Color.WHITE)
	editor.add_theme_stylebox_override("normal", preload("res://scripts/frontend/native_small_theme.gd").box(Color.BLACK, Color.WHITE))
	editor.add_theme_stylebox_override("focus", preload("res://scripts/frontend/native_small_theme.gd").box(Color.BLACK, Color.WHITE))
	editor.text_submitted.connect(func(_text): submit())
	message = _label("Enter: Save    Esc: Cancel", Vector2(16, 121))
	for item: Array in [["Save", 31, submit], ["Cancel", 143, cancel]]:
		var button := Button.new()
		_canvas.add_child(button)
		button.text = item[0]
		button.position = Vector2(item[1], 151)
		button.size = Vector2(80, 20)
		for state: String in ["normal", "hover", "pressed", "focus"]:
			button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
		button.add_theme_color_override("font_shadow_color", Color.BLACK)
		button.add_theme_constant_override("shadow_offset_x", 1)
		button.add_theme_constant_override("shadow_offset_y", 1)
		button.mouse_entered.connect(func(): navigation.emit())
		button.focus_entered.connect(func(): navigation.emit())
		button.pressed.connect(item[2])
	get_viewport().size_changed.connect(_layout)
	_layout()
	editor.grab_focus()
	editor.select_all()


func _label(value: String, at: Vector2) -> Label:
	var result := Label.new()
	_canvas.add_child(result)
	result.text = value
	result.position = at
	result.size = Vector2(224, 24)
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.add_theme_color_override("font_color", Color.WHITE)
	result.add_theme_color_override("font_shadow_color", Color.BLACK)
	result.add_theme_constant_override("shadow_offset_x", 1)
	result.add_theme_constant_override("shadow_offset_y", 1)
	return result


func _layout() -> void:
	var viewport := get_viewport().get_visible_rect().size
	var scale_y := minf(viewport.y / 224.0, viewport.x / (256.0 * 7.0 / 6.0))
	_canvas.scale = Vector2(7.0 / 6.0, 1) * scale_y
	_canvas.position = (viewport - Vector2(256, 224) * _canvas.scale) * 0.5


func submit() -> void:
	if _done: return
	var error: String = validate.call(editor.text) if validate.is_valid() else ""
	if not error.is_empty():
		message.text = error
		editor.grab_focus()
		return
	_done = true
	navigation.emit()
	dismissed.emit(true)
	queue_free()


func cancel() -> void:
	if _done: return
	_done = true
	navigation.emit()
	dismissed.emit(false)
	queue_free()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
		cancel()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		cancel()
		get_viewport().set_input_as_handled()
