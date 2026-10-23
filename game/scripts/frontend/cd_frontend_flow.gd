class_name CdFrontendFlow
extends RefCounted
## Process-local frontend flow. Attract playback never modifies campaign progress
## or persisted user preferences. The CD resets its language-initialized flag at boot.
static var initialized := false
static var startup_language := false
static var automatic_credits := false
static var selected_demo := 2
static var score_request := {}
const Scores = preload("res://scripts/frontend/cd_high_score_store.gd")
const SCORE_SCENE := "res://scenes/high_scores/high_scores.tscn"


static func begin_demo() -> String:
	# CD demos 0/1 become co-op; defer them until multiplayer is rebuilt.
	selected_demo = 2
	return "res://scenes/attract_demo/attract_demo.tscn"


static func show_scores(
	return_path: String, level: int = -1, power: int = 0, cheated: bool = false, track: int = 3
) -> String:
	score_request = {
		"return_path": return_path,
		"level": level,
		"power": power,
		"cheated": cheated,
		"track": track
	}
	return SCORE_SCENE
