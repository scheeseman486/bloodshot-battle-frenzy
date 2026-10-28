class_name NativeSmallTheme
extends RefCounted
## Native menu geometry with the runtime CD/owner bitmap font. No artwork atlas.
const INK := Color(0.95, 0.96, 1.0)
const ACCENT := Color(0.45, 0.73, 1.0)


static func make(font: Font) -> Theme:
	var result := Theme.new()
	result.default_font = font
	result.default_font_size = 12
	for type: String in ["Button", "Label"]:
		result.set_color("font_color", type, INK)
	result.set_color("font_disabled_color", "Button", Color(0.4, 0.43, 0.5))
	result.set_color("font_hover_color", "Button", Color.WHITE)
	result.set_color("font_focus_color", "Button", Color.WHITE)
	result.set_color("font_pressed_color", "Button", ACCENT)
	result.set_stylebox("normal", "Button", box(Color(0.045, 0.06, 0.09), Color(0.16, 0.21, 0.29)))
	result.set_stylebox("hover", "Button", box(Color(0.08, 0.13, 0.21), ACCENT))
	result.set_stylebox("pressed", "Button", box(Color(0.1, 0.18, 0.28), ACCENT))
	result.set_stylebox("focus", "Button", box(Color.TRANSPARENT, ACCENT))
	result.set_stylebox("disabled", "Button", box(Color(0.03, 0.035, 0.05), Color(0.1, 0.12, 0.15)))
	result.set_constant("separation", "VBoxContainer", 0)
	result.set_constant("separation", "HBoxContainer", 3)
	result.set_constant("line_spacing", "Label", 0)
	# Keep native range/scroll controls crisp beside the pixel font.
	result.set_stylebox("slider", "HSlider", box(Color(0.07, 0.09, 0.13), Color(0.16, 0.21, 0.29)))
	result.set_stylebox("grabber_area", "HSlider", box(Color(0.18, 0.31, 0.45), ACCENT))
	result.set_stylebox("grabber_area_highlight", "HSlider", box(Color(0.24, 0.42, 0.60), ACCENT))
	for name: String in ["slider", "grabber_area", "grabber_area_highlight"]:
		var rail := result.get_stylebox(name, "HSlider")
		rail.content_margin_top = 1
		rail.content_margin_bottom = 1
	for entry: Array in [
		["grabber", ACCENT],
		["grabber_highlight", Color.WHITE],
		["grabber_disabled", Color(0.4, 0.43, 0.5)]
	]:
		var pixels := Image.create(4, 8, false, Image.FORMAT_RGBA8)
		pixels.fill(entry[1])
		result.set_icon(entry[0], "HSlider", ImageTexture.create_from_image(pixels))
	result.set_stylebox(
		"scroll", "VScrollBar", box(Color(0.03, 0.035, 0.05), Color(0.16, 0.21, 0.29))
	)
	for state: String in ["grabber", "grabber_highlight", "grabber_pressed"]:
		result.set_stylebox(state, "VScrollBar", box(Color(0.18, 0.31, 0.45), ACCENT))
	return result


static func box(fill: Color, rim: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = rim
	style.set_border_width_all(1)
	style.content_margin_left = 3
	style.content_margin_right = 3
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	return style


static func with_source_sliders(font: Font, ui: RefCounted) -> Theme:
	var result := make(font)
	var rail := StyleBoxTexture.new()
	rail.texture = ui.menu_slider_texture(0, ACCENT)
	rail.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	rail.content_margin_top = 4
	rail.content_margin_bottom = 4
	for name: String in ["slider", "grabber_area", "grabber_area_highlight"]:
		result.set_stylebox(name, "HSlider", rail)
	result.set_icon("grabber", "HSlider", ui.menu_slider_texture(1, ACCENT))
	result.set_icon("grabber_highlight", "HSlider", ui.menu_slider_texture(3, INK))
	result.set_icon("grabber_disabled", "HSlider", ui.menu_slider_texture(1, ACCENT))
	return result
