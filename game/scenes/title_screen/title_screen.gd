extends "res://scripts/frontend/cd_sequence_view.gd"
## Original title composition, localized story captions, then automatic credits.


func _ready() -> void:
	if mount_frontend():
		begin(["title", "story"])


func finished() -> void:
	Flow.automatic_credits = true
	var destination := "res://scenes/main_menu/main_menu.tscn"
	if not Flow.Scores.shared().rows.is_empty():
		destination = Flow.show_scores(destination, -1, 0, false, 2)
	switch_scene(destination)
