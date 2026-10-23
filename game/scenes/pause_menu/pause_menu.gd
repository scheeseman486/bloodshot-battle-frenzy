extends "res://scripts/frontend/cd_frontend_view.gd"
## Pause owns presentation only. The campaign retains and freezes all simulation.
signal finished(result: Dictionary)
signal main_menu_requested
var history: Array = [0, 0, 0, 0, 0, 0]
var active := false
var accepts_controls := true
var campaign: Node3D
var navigation: Control
var ticks := 0
var _clock := 0.0
var _held := 0xffffffff
var _previous := 0xffffffff
var _pending := 0xffffffff
var _done := false


func _ready() -> void:
	if not mount_frontend():
		return
	background.hide()
	navigation = preload("res://scenes/pause_menu/pause_navigation.tscn").instantiate()
	navigation.host = self
	navigation.campaign = campaign
	navigation.resumed.connect(_resume)
	navigation.main_menu_requested.connect(func(): main_menu_requested.emit())
	add_child(navigation)
	if active:
		$Audio.play_source(0x2873c)


func _process(delta: float) -> void:
	if not active or _done or catalog == null:
		return
	_clock += delta
	var period := 1070460.0 / 53203424.0
	while _clock >= period and not _done:
		_clock -= period
		_tick()


func _tick() -> void:
	if active and not _done and accepts_controls:
		ticks += 1


func _resume() -> void:
	if _done or not active or not accepts_controls:
		return
	_done = true
	# Cheat entry is intentionally disabled until the separate cheat menu exists.
	finished.emit.call_deferred({"history": history.duplicate(), "match": -1, "resume": true})
