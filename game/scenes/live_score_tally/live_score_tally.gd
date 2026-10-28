extends Control
const ParticipantLabels = preload("res://scripts/presentation/participant_labels.gd")
## Source-art, read-only in-game table. No pause, focus or simulation ownership.
const Colours = preload("res://scripts/presentation/player_colours.gd")
const CameraProfile = preload("res://scripts/presentation/cd_projection.gd")
var _canvas: Control
var _font: Font
var _icons: Array[Texture2D] = []
var _title: Label
var _score_heading: Label
var _rows: Array = []
var _signature: Array = []
var _frame := Rect2()
var _scale := Vector2.ONE


func _enter_tree() -> void:
	preload("res://scripts/presentation/sharp_bilinear_ui.gd").apply(self)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	hide()
	get_viewport().size_changed.connect(_layout)


func configure(ui: RefCounted, font: Font) -> void:
	_font = font
	if is_instance_valid(_canvas):
		remove_child(_canvas)
		_canvas.queue_free()
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.theme = preload("res://scripts/frontend/native_small_theme.gd").make(font)
	add_child(_canvas)
	_icons.clear()
	for colour: int in range(4):
		_icons.append(Colours.skull_texture(ui.icon(4), colour, true))
	_title = _label("", Vector2(12, 47), 232)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label("#", Vector2(34, 69), 14)
	_label("USER", Vector2(52, 69), 86)
	_score_heading = _label("", Vector2(144, 69), 54, true)
	_label("PING", Vector2(204, 69), 38, true)
	_rows.clear()
	for index: int in range(4):
		var y := 88.0 + index * 21.0
		var icon := TextureRect.new()
		icon.position = Vector2(12, y)
		icon.size = Vector2(16, 16)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_canvas.add_child(icon)
		_rows.append({"icon": icon, "number": _label("", Vector2(34, y + 2), 14),
			"user": _label("", Vector2(52, y + 2), 86),
			"score": _label("", Vector2(144, y + 2), 54, true),
			"ping": _label("", Vector2(204, y + 2), 38, true)})
	_signature.clear()
	_layout()


func _label(text: String, at: Vector2, width: float, right: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	label.position = at
	label.size = Vector2(width, 12)
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(label)
	return label


func _layout() -> void:
	if not is_instance_valid(_canvas):
		return
	var viewport := get_viewport().get_visible_rect().size
	var height := minf(viewport.y, viewport.x * 0.75)
	_scale = Vector2(CameraProfile.SOURCE_PIXEL_ASPECT, 1.0) * height / 224.0
	_frame = Rect2((viewport - Vector2(256, 224) * _scale) * 0.5, Vector2(256, 224) * _scale)
	_canvas.position = _frame.position
	_canvas.scale = _scale


static func number(value: int) -> String:
	for unit: Array in [[1000000000000.0, "t"], [1000000000.0, "b"], [1000000.0, "m"], [1000.0, "k"]]:
		if absi(value) >= maxf(unit[0], 10000.0):
			var scaled := float(value) / float(unit[0])
			return (("%.1f" if absf(scaled) < 10 else "%.0f") % scaled) + str(unit[1])
	return str(value)


func present(rows: Array, mode: String, local_reference: Dictionary) -> void:
	if not is_instance_valid(_canvas) or _signature == [rows, mode, local_reference]:
		return
	_signature = [rows.duplicate(true), mode, local_reference.duplicate()]
	_title.text = "VS BATTLE" if mode == "versus" else "CO-OP CAMPAIGN SCORE"
	_score_heading.text = "KILLS" if mode == "versus" else "SCORE"
	for index: int in range(4):
		var view: Dictionary = _rows[index]
		for node: Control in view.values():
			node.visible = index < rows.size()
		if index >= rows.size():
			continue
		var row: Array = rows[index]
		view.icon.texture = _icons[row[3]]
		view.number.text = str(row[2] + 1)
		var local := local_reference == {"id": row[0], "generation": row[1]}
		view.user.text = ("> " if local else "") + ParticipantLabels.label(rows, row[2], row[5] == -3, {"id": row[0], "generation": row[1]})
		view.score.text = number(row[4])
		view.ping.text = "BOT" if row[5]==-3 else ("HOST" if row[5] == -2 else ("-" if row[5] < 0 else str(row[5])))
