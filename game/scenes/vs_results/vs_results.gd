extends Control
const ParticipantLabels = preload("res://scripts/presentation/participant_labels.gd")
## Frozen authority standings over the game, using the existing menu's source
## bitmap font and transparent source skulls. Only the host exposes round verbs.
signal completed(action: String)
signal menu_requested
const Colours = preload("res://scripts/presentation/player_colours.gd")
const CameraProfile = preload("res://scripts/presentation/cd_projection.gd")
var result: Dictionary = {}
var local_reference: Dictionary = {}
var host := false
var _canvas: Control
var _icons: Array[Texture2D] = []
var _rows: Array = []
var _labels: Array[Label] = []
var _page := 0
var _action_menu: Control
var _selected: int:
	get: return maxi(0, int(_action_menu.menu_state.selected) - 1) if is_instance_valid(_action_menu) else 0
var _actions: Array = []
var _scale := Vector2.ONE


func configure(ui: RefCounted, font: Font) -> void:
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.theme = preload("res://scripts/frontend/native_small_theme.gd").make(font)
	add_child(_canvas)
	for colour: int in range(4):
		_icons.append(ImageTexture.create_from_image(Colours.skull_image(ui.icon(4).get_image(), colour, true)))
	_rows = result.get("rows", []).duplicate(true)
	_rows.sort_custom(func(a, b):
		if a.kills != b.kills: return a.kills > b.kills
		if a.deaths != b.deaths: return a.deaths < b.deaths
		return a.reference.id < b.reference.id)
	_actions = ["rematch", "lobby"] if host else []
	_rebuild()
	if host:
		_action_menu = preload("res://scenes/pause_menu/pause_navigation.tscn").instantiate()
		_action_menu.set_script(preload("res://scenes/vs_results/vs_result_actions.gd"))
		_action_menu.completed.connect(func(action): completed.emit(action))
		_action_menu.back_requested.connect(func(): menu_requested.emit())
		add_child(_action_menu)
	_layout()


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_viewport().size_changed.connect(_layout)
	visibility_changed.connect(_clear_action_input)


func _label(text: String, at: Vector2, width: float, right: bool = false) -> Label:
	var label := Label.new()
	# Attach the source-font theme before measuring; the default font's larger
	# minimum width otherwise survives and pushes the last heading off 4:3.
	_canvas.add_child(label)
	label.text = text
	label.position = at
	label.size = Vector2(width, 12)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	_labels.append(label)
	return label


func _rebuild() -> void:
	for child: Node in _canvas.get_children():
		_canvas.remove_child(child)
		child.free()
	_labels.clear()
	var winners: Array = result.get("winners", [])
	var title := "SHARED VICTORY"
	if winners.size() == 1:
		for entry: Dictionary in _rows:
			if entry.reference == winners[0]: title = ParticipantLabels.label(_rows, entry.seat, entry.get("controller", "human") == "bot", entry.reference) + " WINS"
	_label(title, Vector2(8, 66), 240).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label("FIRST TO %d" % int(result.get("limit", 15)), Vector2(8, 80), 240).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label("PLAYER", Vector2(37, 96), 100)
	_label("KILLS", Vector2(143, 96), 43, true)
	_label("DEATHS", Vector2(195, 96), 48, true)
	for index: int in range(4):
		var offset := _page * 4 + index
		if offset >= _rows.size(): break
		var entry: Dictionary = _rows[offset]
		var y := 111.0 + index * 16.0
		var icon := TextureRect.new()
		icon.position = Vector2(15, y - 2)
		icon.size = Vector2(16, 16)
		icon.texture = _icons[entry.seat]
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_canvas.add_child(icon)
		_label((">" if entry.reference == local_reference else "") + ParticipantLabels.label(_rows, entry.seat, entry.get("controller", "human") == "bot", entry.reference) + (" LEFT" if not entry.active else ""), Vector2(37, y), 100)
		_label(str(entry.kills), Vector2(143, y), 43, true)
		_label(str(entry.deaths), Vector2(195, y), 48, true)
	if _rows.size() > 4:
		_label("<  PAGE %d/%d  >" % [_page + 1, ceili(_rows.size() / 4.0)], Vector2(8, 176), 240).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if not host:
		_label("WAITING FOR HOST", Vector2(8, 193), 240).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label("ESC: MENU", Vector2(8, 207), 240).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _layout() -> void:
	if not is_instance_valid(_canvas): return
	var viewport := get_viewport().get_visible_rect().size
	var height := minf(viewport.y, viewport.x * 0.75)
	_scale = Vector2(CameraProfile.SOURCE_PIXEL_ASPECT, 1) * height / 224.0
	_canvas.scale = _scale
	_canvas.position = (viewport - Vector2(256, 224) * _scale) * 0.5


func _clear_action_input() -> void:
	if is_instance_valid(_action_menu): _action_menu._reset_controls_edges()


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not can_process() or not is_instance_valid(_canvas): return
	# Remote standings still offer the local menu, without exposing host verbs.
	if not host:
		if ((event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE)
			or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)
			or (event is InputEventJoypadButton and event.pressed and event.button_index in [JOY_BUTTON_B, JOY_BUTTON_START])):
			menu_requested.emit.call_deferred()
			get_viewport().set_input_as_handled()
			return
	var direction := 0
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode in [KEY_LEFT, KEY_RIGHT]:
			direction = -1 if event.physical_keycode == KEY_LEFT else 1
	elif event is InputEventJoypadButton and event.pressed:
		if event.button_index in [JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]:
			direction = -1 if event.button_index == JOY_BUTTON_DPAD_LEFT else 1
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var point: Vector2 = (event.position - _canvas.position) / _scale
		if _rows.size() > 4 and Rect2(8, 173, 240, 15).has_point(point):
			direction = -1 if point.x < 128 else 1
	if direction != 0:
		_page = posmod(_page + direction, maxi(1, ceili(_rows.size() / 4.0)))
		_rebuild()
		get_viewport().set_input_as_handled()
	elif is_instance_valid(_action_menu):
		_action_menu._input(event)
