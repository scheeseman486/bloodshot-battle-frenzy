@tool
extends "res://scripts/audio/cd_audio_service.gd"
## Original title/menu CD music. Playback resources and worker lifetime belong
## to the scene, independently of frontend animation and navigation clocks.
const Source = preload("res://scripts/assets/original_asset_source.gd")
@export_range(2, 17) var track := 2
@export var auto_play := true


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var source := Source.new()
	if source.mount(Source.configured_disc_path()):
		if configure(source) and auto_play:
			play_track(track, true)
