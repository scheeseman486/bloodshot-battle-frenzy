extends "res://scenes/main_menu/main_menu.gd"
## Shared native small-font pages: centered rows, shadow, red selection and static.
## Navigation/input remain in the frontend dispatcher; subclasses own actions.
var _hint_font: FontFile


func _ready() -> void:
	super._ready()
	if catalog != null:
		_hint_font = source.load_cd_small_font().native_font()
		_layout_small_rows()


func open_menu(name: String) -> void:
	super.open_menu(name)
	_layout_small_rows()


func _tick() -> void:
	super._tick()
	if uses_small_font() and int(menu_state.selected) > 0:
		_resolve_row(int(menu_state.selected) - 1)


func uses_small_font() -> bool:
	return true


func reveals_whole_rows() -> bool:
	# Keep the shared reveal clock/cues, resolving one complete small-font row.
	return uses_small_font()


func _layout_small_rows() -> void:
	if _hint_font == null or not uses_small_font():
		return
	var height := float((labels.size() - 1) * 18 + 12)
	for index: int in range(labels.size()):
		var text := labels[index].get_string_from_ascii()
		var width := _hint_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		row_origins[index] = Vector2((256 - width) * 0.5, (224 - height) * 0.5 + index * 18)


func row_at_position(position: Vector2) -> int:
	if not uses_small_font():
		return super.row_at_position(position)
	var point := (position - frame.position) / artwork_scale
	for index: int in range(labels.size()):
		var text := labels[index].get_string_from_ascii()
		var width := _hint_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		if Rect2(row_origins[index] - Vector2(8, 3), Vector2(width + 16, 18)).has_point(point):
			return index
	return -1


func label_layout(index: int) -> Dictionary:
	if not uses_small_font() or _hint_font == null:
		return super.label_layout(index)
	var width := (
		_hint_font
		. get_string_size(labels[index].get_string_from_ascii(), HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		. x
	)
	return {"commands": [], "pauses": {}, "end": row_origins[index] + Vector2(width, 0)}


func _draw() -> void:
	if not uses_small_font():
		super._draw()
		return
	if _hint_font == null:
		return
	for index: int in range(labels.size()):
		var text := labels[index].get_string_from_ascii()
		var origin := frame.position + row_origins[index] * artwork_scale
		draw_set_transform(origin, 0, artwork_scale)
		draw_string(
			_hint_font, Vector2(1, 11), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.BLACK
		)
		if visible_letters[index] < labels[index].size():
			draw_string(
				_hint_font, Vector2(0, 10), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.CYAN
			)
		var ink := Color(1.0, 0.12, 0.12) if int(menu_state.selected) == index + 1 else Color.WHITE
		draw_string(
			_hint_font,
			Vector2(0, 10),
			text.left(visible_letters[index]),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			12,
			ink
		)
	var heading := small_menu_heading()
	if not heading.is_empty():
		_draw_small_line(heading, row_origins[0].y - 14 if not row_origins.is_empty() else 40)
	var footer := small_menu_footer()
	if not footer.is_empty():
		_draw_small_line(footer, 216)
	draw_set_transform(Vector2.ZERO)


func small_menu_heading() -> String:
	return ""


func small_menu_footer() -> String:
	return ""


func _draw_small_line(text: String, baseline: float) -> void:
	var width := _hint_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	draw_set_transform(
		frame.position + Vector2((256 - width) * .5, 0) * artwork_scale, 0, artwork_scale
	)
	draw_string(
		_hint_font, Vector2(1, baseline + 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.BLACK
	)
	draw_string(
		_hint_font, Vector2(0, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE
	)
