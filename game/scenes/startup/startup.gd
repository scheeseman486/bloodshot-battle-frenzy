extends "res://scripts/frontend/cd_sequence_view.gd"
## Native disclaimer followed by the European publisher startup sequence.
const Disclaimer = preload("res://scripts/frontend/native_boot_disclaimer.gd")
var small_font: RefCounted
var disclaimer_font: FontFile
var preparing_assets := true
var _first_presentation_frame := true
var _loading_message := "Preparing game data..."
var _loading_done := 0
var _loading_total := 20


func _ready() -> void:
	# Preparation is outside the original presentation clock. Input during this
	# phase cannot skip the disclaimer or accumulate simulation work.
	set_process(false)
	var path := Source.configured_disc_path()
	var mounted := source.mount(path)
	if not mounted or not source.supported_media():
		if DisplayServer.get_name() == "headless":
			show_error("The supported European Mega CD image is required. " + source.last_error)
			get_tree().quit(1)
			return
		var prompt := preload("res://scripts/frontend/disc_image_prompt.gd").new()
		add_child(prompt)
		path = await prompt.acquire()
		prompt.queue_free()
		if path.is_empty():
			get_tree().quit()
			return
		preload("res://scripts/assets/disc_location.gd").selected_path = path
		if not source.mount(path):
			show_error(source.last_error)
			return
	small_font = source.load_cd_small_font()
	if small_font == null:
		show_error(source.last_error)
		return
	disclaimer_font = small_font.native_font()
	RenderingServer.set_default_clear_color(Color.BLACK)
	_layout()
	if not await source.prepare_asset_cache(_preparation_progress):
		show_error(source.last_error)
		return
	if not await preload("res://scripts/presentation/cd_runtime_preparation.gd").prepare(source, _preparation_progress):
		show_error(source.last_error)
		return
	if get_tree().has_meta("startup_destination"):
		var destination: String = get_tree().get_meta("startup_destination")
		get_tree().remove_meta("startup_destination")
		get_tree().change_scene_to_file(destination)
		return
	if mount_frontend(true):
		if Settings.has_saved_language():
			Flow.initialized = true
			Flow.startup_language = false
		preparing_assets = false
		begin(["logos"])
		set_process(true)


func _preparation_progress(message: String, done: int, total: int) -> void:
	_loading_message = message
	_loading_done = done
	_loading_total = total
	_layout()


func _process(delta: float) -> void:
	if preparing_assets:
		return
	# The first engine delta can include the final loading batch. Presentation
	# starts with a fresh clock when the disclaimer becomes visible.
	if _first_presentation_frame:
		_first_presentation_frame = false
		return
	super._process(delta)


func _draw() -> void:
	if not preparing_assets:
		super._draw()
		return
	if disclaimer_font == null:
		return
	draw_set_transform(frame.position, 0, artwork_scale)
	var lines := [_loading_message, "%d / %d" % [_loading_done, _loading_total]]
	for index: int in range(lines.size()):
		var width := (
			disclaimer_font.get_string_size(lines[index], HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		)
		draw_string(
			disclaimer_font,
			Vector2((256 - width) * 0.5, 104 + index * 12),
			lines[index],
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			12,
			Color.WHITE
		)
	draw_set_transform(Vector2.ZERO)


func _input(event: InputEvent) -> void:
	if not preparing_assets:
		super._input(event)


func finished() -> void:
	if not Flow.initialized:
		Flow.startup_language = true
		switch_scene("res://scenes/main_menu/main_menu.tscn")
	else:
		switch_scene("res://scenes/title_screen/title_screen.tscn")


func skipped() -> void:
	if not Flow.initialized:
		Flow.startup_language = true
	switch_scene("res://scenes/main_menu/main_menu.tscn")


func is_disclaimer_slide(index: int) -> bool:
	return index == 0


func draw_slide(index: int, brightness: float) -> void:
	if not is_disclaimer_slide(index):
		super.draw_slide(index, brightness)
		return
	for line: Dictionary in Disclaimer.layout(small_font):
		# Keep half-pixel centering in the transform; TextServer snaps pen offsets.
		draw_set_transform(frame.position + Vector2(line.x, 0) * artwork_scale, 0, artwork_scale)
		draw_string(
			disclaimer_font,
			Vector2(0, line.baseline),
			line.text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			12,
			line.color * Color(brightness, brightness, brightness)
		)
	draw_set_transform(Vector2.ZERO)
