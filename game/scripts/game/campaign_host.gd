class_name CdCampaignHost
extends RefCounted
## Authority owns campaign decisions; cards only report their completed UI action.
const Carry = preload("res://scripts/simulation/cd_campaign_carry.gd")
const Rules = preload("res://scripts/frontend/cd_campaign_card_rules.gd")
var _state: Dictionary = {
	"level_number": 1,
	"_transition_pending": false,
	"_transition_carry": {},
	"continue_credits": 3,
	"score_eligible": true,
	"cheated": false,
	"cheats_ever_enabled": false,
	"_game_over_presented": false,
	"paused": false,
	"card": {}
}
var level_number: int:
	get:
		return _state.level_number
	set(value):
		_state.level_number = value
var _transition_pending: bool:
	get:
		return _state._transition_pending
	set(value):
		_state._transition_pending = value
var _transition_carry: Dictionary:
	get:
		return _state._transition_carry
	set(value):
		_state._transition_carry = value
var continue_credits: int:
	get:
		return _state.continue_credits
	set(value):
		_state.continue_credits = value
var score_eligible: bool:
	get:
		return _state.score_eligible
	set(value):
		_state.score_eligible = value
var cheated: bool:
	get:
		return _state.cheated
	set(value):
		_state.cheated = value
var cheats_ever_enabled: bool:
	get:
		return bool(_state.get("cheats_ever_enabled", false))


var _game_over_presented: bool:
	get:
		return _state._game_over_presented
	set(value):
		_state._game_over_presented = value
var paused: bool:
	get:
		return _state.paused
	set(value):
		_state.paused = value


func disable_scoring_for_cheats() -> void:
	_state.cheats_ever_enabled = true
	score_eligible = false


func begin(session: RefCounted, exhausted: bool) -> Dictionary:
	_transition_pending = true
	_transition_carry = Carry.capture(session)
	var result := {
		"kind": "ending" if exhausted else Rules.destination(level_number),
		"phase": "continue" if exhausted else "clear",
		"result":
		{
			"level": level_number,
			"kills": int(session.actor_system.encounter.kills),
			"bonuses": int(session.actor_system.encounter.bonuses),
			"tally": int(session.actor_system.encounter.damage_total),
			"credits": continue_credits
		}
	}

	if cheats_ever_enabled:
		result.result.scoring_disabled = true
	return result


func complete(action: String, session: RefCounted) -> Dictionary:
	if not _transition_pending:
		return {}
	if action == "next" and session.is_complete() and level_number < 16:
		_transition_pending = false
		return {
			"kind": "load", "level": level_number + 1, "carry": _transition_carry.duplicate(true)
		}
	if action == "continue" and session.is_game_over() and continue_credits > 0:
		continue_credits -= 1
		cheated = false
		_transition_pending = false
		return {"kind": "load", "level": level_number, "carry": {}}
	if action in ["finished", "scores"]:
		_transition_pending = false
		return {
			"kind": "scores",
			"level": level_number,
			"rating": 0 if cheats_ever_enabled else Rules.power_rating(int(session.actor_system.encounter.damage_total)),
			"ineligible": not score_eligible or cheated or cheats_ever_enabled
		}
	return {}


func describe() -> Dictionary:
	return _state.duplicate(true)


func restore(state: Dictionary) -> void:
	# Bind the complete authoritative record; no second mutable campaign owner.
	_state = state
	if not _state.has("cheats_ever_enabled"):
		_state.cheats_ever_enabled = bool(_state.get("cheated", false))
	if cheats_ever_enabled:
		score_eligible = false
