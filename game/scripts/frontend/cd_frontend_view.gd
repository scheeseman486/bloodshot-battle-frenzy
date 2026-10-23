extends Control
## Shared runtime media and corrected flat-art display for native frontend scenes.
const Source = preload("res://scripts/assets/original_asset_source.gd")
const Settings = preload("res://scripts/frontend/cd_frontend_settings.gd")
var source := Source.new()
var catalog: RefCounted
var frame := Rect2()
var artwork_scale := Vector2.ONE
var background: TextureRect
var noise: ShaderMaterial
var _transitioning := false
var wide_background := true
var clearing_text: Array = []
var _text_static_tick := 0
var _background_palette := preload("res://scripts/presentation/cd_menu_palette.gd").new()


func switch_scene(path: String) -> void:
	if _transitioning:
		return
	_transitioning = true
	# Scene changes may originate inside an input or catch-up clock callback.
	# Deferring detachment lets the callback finish with its valid viewport.
	get_tree().change_scene_to_file.call_deferred(path)


func mount_frontend(already_mounted: bool = false) -> bool:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	RenderingServer.set_default_clear_color(Color.BLACK)
	if not already_mounted and not source.mount(Source.configured_disc_path()):
		show_error(source.last_error)
		return false
	catalog = source.load_cd_frontend_catalog()
	if catalog == null:
		show_error(source.last_error)
		return false
	preload("res://scripts/audio/cd_audio_settings.gd").set_source_mode(
		int(Settings.values().sound)
	)
	material = ShaderMaterial.new()
	material.shader = preload("res://shaders/cd_menu_text_static.gdshader")
	update_text_static(0)
	background = TextureRect.new()
	background.show_behind_parent = true
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.texture = catalog.noise_tiles()
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	noise = ShaderMaterial.new()
	noise.shader = preload("res://shaders/cd_menu_background.gdshader")
	noise.set_shader_parameter("source_tiles", catalog.noise_tiles())
	noise.set_shader_parameter("seeds", catalog.noise_seeds())
	_background_palette.configure(catalog.noise_targets())
	noise.set_shader_parameter("colour_palette", _background_palette.texture)
	background.material = noise
	add_child(background)
	get_viewport().size_changed.connect(_layout)
	_layout()
	return true


func _layout() -> void:
	var size := get_viewport().get_visible_rect().size
	var height := minf(size.y, size.x * 0.75)
	artwork_scale = Vector2(height * (7.0 / 6.0) / 224.0, height / 224.0)
	frame = Rect2(
		(size - Vector2(256, 224) * artwork_scale) * 0.5, Vector2(256, 224) * artwork_scale
	)
	if background != null:
		background.position = Vector2.ZERO if wide_background else frame.position
		background.size = size if wide_background else frame.size
		noise.set_shader_parameter("logical_size", background.size / artwork_scale)
		noise.set_shader_parameter(
			"logical_origin", (background.position - frame.position) / artwork_scale
		)
	queue_redraw()


func draw_bytes(
	bytes: PackedByteArray, origin: Vector2, limit: int = 0x7fffffff, wrap_indent: int = 6
) -> void:
	var layout: Dictionary = catalog.text_layout(bytes, origin, wrap_indent)
	for command: Dictionary in layout.commands:
		if int(command.index) >= limit:
			return
		# $2E4F4 clears source space cells; they reveal the animated background.
		if int(command.code) != 32:
			draw_texture(catalog.ui.character(int(command.code)), Vector2(command.x, command.y))


func update_background(tick: float, smooth_ticks: float = -1.0) -> void:
	update_text_static(int(tick))
	if noise != null:
		# Keep the original tile/static cadence; every use of this background
		# blends its complete endpoint palettes on fractional render time.
		noise.set_shader_parameter("phase", float(int(tick)))
		_background_palette.advance(smooth_ticks if smooth_ticks >= 0.0 else tick, true)


func show_error(message: String) -> void:
	var label := Label.new()
	label.text = message + "\nSupply the original European CD via --disc or project settings."
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(label)
	push_error(message)


func development_shortcut(event: InputEvent) -> bool:
	if (
		event is InputEventKey
		and event.pressed
		and not event.echo
		and event.physical_keycode == KEY_F12
	):
		get_viewport().set_input_as_handled()
		switch_scene("res://scenes/development_menu/development_menu.tscn")
		return true
	return false


func update_text_static(tick: int) -> void:
	_text_static_tick = tick
	if material is ShaderMaterial and catalog != null:
		material.set_shader_parameter("static_pattern", catalog.ui.text_noise_pattern(tick))
		var colors: PackedColorArray = catalog.ui.text_noise_colors()
		for index: int in [1, 4, 5]:
			material.set_shader_parameter("ink_%d" % index, colors[index])


func play_text_clear_sound() -> void:
	# SHELL $2E27E requests this PCM once before starting its eight-tick timer.
	$Audio.play_source(0x2547e)


func begin_text_clear(commands: Array) -> void:
	play_text_clear_sound()
	# Snapshot only what has actually appeared; a skip must not reveal more text.
	clearing_text = commands.duplicate(true)
	queue_redraw()


func draw_clearing_text() -> void:
	for glyph: Dictionary in clearing_text:
		if int(glyph.code) > 32:
			draw_texture(
				catalog.ui.character_noise(int(glyph.code), _text_static_tick),
				Vector2(glyph.x, glyph.y)
			)
