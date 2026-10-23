extends "res://scenes/campaign/campaign.gd"
## Native 3D presentation of original CD recorded input and actor schedules.
const Flow = preload("res://scripts/frontend/cd_frontend_flow.gd")

const OriginalSource = preload("res://scripts/assets/original_asset_source.gd")
var _leaving := false


func _ready() -> void:
	var source := OriginalSource.new()
	if not source.mount(OriginalSource.configured_disc_path()):
		push_error(source.last_error)
		return
	var catalog: RefCounted = source.load_cd_frontend_catalog()
	if catalog == null:
		push_error(source.last_error)
		return
	driver.recording = catalog.demo(Flow.selected_demo)
	get_tree().set_meta("campaign_level", int(driver.recording.level))
	super._ready()
	# $36C80 gives the initial demo player a map display and spawn grace.
	session.fighter.grace = 20
	session.fighter.map_timer = 150
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_updated()


func load_level(_number: int, carry: Dictionary = {}) -> bool:
	# Development --level arguments must not select a different recorded map.
	return super.load_level(int(driver.recording.level), carry)


func _advance_to_now() -> void:
	var now := Time.get_ticks_usec()
	var elapsed := now - _previous_usec
	_previous_usec = now
	if ready_to_play and not paused and not _leaving:
		driver.advance_usec(elapsed)


func _process(_delta: float) -> void:
	_advance_to_now()
	if ready_to_play and not paused and not _leaving:
		_present()
		if driver.finished:
			_leave(false)


func _controls(_sample: int) -> Dictionary:
	return {"held": 0xffffffff, "strafe": 0}


func _input(event: InputEvent) -> void:
	if _leaving:
		return
	var confirm: bool = (
		event is InputEventKey
		and event.pressed
		and not event.echo
		and event.physical_keycode in [KEY_ENTER, KEY_SPACE, KEY_Z, KEY_X, KEY_C, KEY_ESCAPE]
	)
	confirm = (
		confirm
		or (
			event is InputEventJoypadButton
			and event.pressed
			and event.button_index in [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X]
		)
	)
	var start: bool = (
		event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_START
	)
	if confirm or start:
		get_viewport().set_input_as_handled()
		_leave(start)


func _focus_lost() -> void:
	pass  # Attract playback continues when its window loses focus.


func _unhandled_input(_event: InputEvent) -> void:
	pass  # Live input cannot steer, shoot, capture the mouse or pause a recording.


func _leave(start: bool) -> void:
	_leaving = true
	if start:
		get_tree().set_meta("campaign_level", 1)
		get_tree().set_meta("campaign_score_eligible", true)
	get_tree().change_scene_to_file.call_deferred(
		"res://scenes/campaign/campaign.tscn" if start else "res://scenes/startup/startup.tscn"
	)


func restore_checkpoint(bytes: PackedByteArray) -> bool:
	if not super.restore_checkpoint(bytes):
		return false
	_leaving = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	return true
