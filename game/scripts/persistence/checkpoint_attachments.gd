class_name CdCheckpointAttachments
extends RefCounted
## Optional campaign/view continuity. Stores logical state and content IDs only;
## source pages, glyphs, images, audio buffers and GPU objects are reconstructed.
const CAMPAIGN_FIELDS := [
	"level_number",
	"_transition_pending",
	"_transition_carry",
	"continue_credits",
	"score_eligible",
	"cheated",
	"_game_over_presented",
	"paused"
]
const CARD_FIELDS := [
	"result",
	"phase",
	"page_index",
	"age",
	"ticks",
	"deadline",
	"_clock",
	"_pending",
	"_held",
	"_previous",
	"_done",
	"_closing",
	"_close_age",
	"_summary",
	"_background_epoch",
	"_continuation_exit",
	"_text_static_tick"
]
const ANIMATION_SOURCE_FIELDS := ["kind", "parameter", "health", "cursor", "frame", "timer"]
const DOOR_FIELDS := ["_groups", "_time", "_interval", "_blocked", "_opening_offsets"]


func capture(scene: Node) -> Dictionary:
	var campaign := {}
	for field: String in CAMPAIGN_FIELDS:
		campaign[field] = scene.get(field)
	campaign._transition_carry = campaign._transition_carry.duplicate(true)
	campaign.card = {}
	if is_instance_valid(scene._campaign_transition):
		for field: String in CARD_FIELDS:
			campaign.card[field] = scene._campaign_transition.get(field)
	var doors := {}
	for field: String in DOOR_FIELDS:
		var value: Variant = scene.door_motion.get(field)
		doors[field] = value.duplicate(true) if value is Array or value is Dictionary else value
	var animations := {"boundary": scene.actor_animations._last_boundary, "slots": {}}
	for slot: int in scene.actor_animations._slots:
		var row: Dictionary = scene.actor_animations._slots[slot]
		var cursor := 0
		for key: int in scene.actor_animations._clips:
			if is_same(scene.actor_animations._clips[key], row.clip):
				cursor = key
		var source := {}
		for field: String in ANIMATION_SOURCE_FIELDS:
			source[field] = row.source[field]
		animations.slots[slot] = {
			"start": row.start, "source": source, "generation": row.generation, "program": cursor
		}
	var card_music := {}
	if is_instance_valid(scene._campaign_transition):
		card_music = _capture_music(scene._campaign_transition.get_node("Audio"))
	return {
		"campaign": campaign,
		"presentation":
		{
			"version": 1,
			"doors": doors,
			"animations": animations,
			"music": _capture_music(scene.get_node("Audio")),
			"card_music": card_music
		}
	}


func attach_views(scene: Node, state: Dictionary) -> void:
	# Caller has installed a validated world and rebuilt original level/UI media.
	# Reopening the stream resumes music, never historical one-shot effects.
	var presentation: Dictionary = state.presentation
	for field: String in DOOR_FIELDS:
		scene.door_motion.set(field, presentation.doors[field])
	scene.actor_animations.configure(scene.actor_catalog)
	scene.actor_animations._last_boundary = presentation.animations.boundary
	for slot: int in presentation.animations.slots:
		var row: Dictionary = presentation.animations.slots[slot]
		scene.actor_animations._slots[slot] = {
			"start": row.start,
			"source": row.source.duplicate(true),
			"generation": row.generation,
			"clip": scene.actor_animations._clip(int(row.program))
		}
	scene.presentation._segments = scene.client.segments.duplicate(true)
	scene.presentation._groups = scene.client.session.groups.duplicate(true)
	_restore_music(scene.get_node("Audio"), presentation.music)
	if not presentation.card_music.is_empty() and is_instance_valid(scene._campaign_transition):
		_restore_music(scene._campaign_transition.get_node("Audio"), presentation.card_music)


func validate(campaign: Variant, presentation: Variant, schema: RefCounted) -> bool:
	if not schema._need(
		campaign is Dictionary and presentation is Dictionary,
		"Campaign/presentation records required"
	):
		return false
	if not campaign.is_empty():
		if not schema._shape(campaign, CAMPAIGN_FIELDS + ["card"], "campaign"):
			return false
		if (
			not schema._int(campaign.level_number, 0 if schema.definition.level.get_meta("battle_mode",false) else 1, 16, "campaign level")
			or not schema._int(campaign.continue_credits, -32768, 32767, "continue credits")
		):
			return false
		for flag: String in [
			"_transition_pending", "score_eligible", "cheated", "_game_over_presented", "paused"
		]:
			if not schema._need(campaign[flag] is bool, "Campaign boolean " + flag):
				return false
		if not schema._need(
			campaign._transition_carry is Dictionary and campaign.card is Dictionary,
			"Campaign carry/card types"
		):
			return false
		if not campaign._transition_carry.is_empty():
			var carry: Dictionary = campaign._transition_carry
			if not schema._shape(
				carry,
				[
					"keys",
					"palette_phase",
					"lives",
					"reward_index",
					"inventory",
					"selected",
					"manual",
					"pattern",
					"boss_phase",
					"damage_total",
					"countdown_boundary",
					"world_update"
				],
				"campaign carry"
			):
				return false
			if not schema._keys(carry.keys):
				return false
			for key: String in carry:
				if (
					key not in ["keys", "inventory"]
					and not schema._int(carry[key], -2147483648, 0xffffffff, "carry scalar")
				):
					return false
			if not schema._need(
				carry.inventory is Array and carry.inventory.size() == 18, "Carry inventory"
			):
				return false
			for weapon: Variant in carry.inventory:
				if not schema._record("weapon", weapon):
					return false
		if not campaign.card.is_empty():
			var card: Dictionary = campaign.card
			if not schema._shape(card, CARD_FIELDS, "campaign card"):
				return false
			if not schema._need(
				(
					card.phase in ["clear", "continue", "summary"]
					and card._continuation_exit in ["", "continue", "summary", "scores"]
				),
				"Card phase/action"
			):
				return false
			if not schema._shape(
				card.result,
				(
					["level", "kills", "bonuses", "tally", "credits"]
					+ (
						["players"]
						if card.result is Dictionary and card.result.has("players")
						else []
					)
				),
				"card result"
			):
				return false
			if (
				card.result.has("players")
				and not schema._need(
					preload("res://scripts/game/coop_score.gd").valid_rows(
						card.result.players, card.result.level == 16 or card.phase != "clear"
					),
					"Invalid co-op tally"
				)
			):
				return false
			var pages := 2 if card._summary or int(campaign.level_number) == 16 else 3
			if not schema._int(card.page_index, 0, pages - 1, "Card page"):
				return false
			for key: String in card.result:
				if key == "players":
					continue
				if not schema._int(card.result[key], -2147483648, 0xffffffff, "card result scalar"):
					return false
			for key: String in CARD_FIELDS:
				if key in ["result", "phase", "_continuation_exit"]:
					continue
				if key == "_clock":
					if not schema._need(
						(
							card[key] is float
							and is_finite(card[key])
							and card[key] >= 0
							and card[key] < 1
						),
						"Card clock"
					):
						return false
				elif key in ["_done", "_summary"]:
					if not schema._need(card[key] is bool, "Card flags"):
						return false
				elif not schema._int(card[key], 0, 0xffffffff, "card scalar"):
					return false
	if presentation.is_empty():
		return true
	if not schema._shape(
		presentation, ["version", "doors", "animations", "music", "card_music"], "presentation"
	):
		return false
	if not schema._need(presentation.version == 1, "Presentation version"):
		return false
	if not schema._shape(presentation.doors, DOOR_FIELDS, "door presentation"):
		return false
	var doors: Dictionary = presentation.doors
	if not schema._need(
		(
			doors._groups is Array
			and doors._groups.size() <= 256
			and doors._opening_offsets is Dictionary
		),
		"Door view limits"
	):
		return false
	for group: Variant in doors._groups:
		if not schema._record("door", group):
			return false
	for key: String in ["_time", "_interval"]:
		if not schema._need(
			doors[key] is float and is_finite(doors[key]) and doors[key] >= 0, "Door view time"
		):
			return false
	if not schema._indices(doors._blocked, doors._groups.size(), true):
		return false
	for index: Variant in doors._opening_offsets:
		if not schema._int(index, 0, doors._groups.size() - 1, "Door view index"):
			return false
		if not schema._need(
			(
				doors._opening_offsets[index] is float
				and is_finite(doors._opening_offsets[index])
				and absf(doors._opening_offsets[index]) <= 4096
			),
			"Door opening correction"
		):
			return false
	if not schema._shape(presentation.animations, ["boundary", "slots"], "animation continuity"):
		return false
	var animations: Dictionary = presentation.animations
	if not schema._need(
		(
			animations.boundary is float
			and is_finite(animations.boundary)
			and animations.slots is Dictionary
			and animations.slots.size() <= 180
		),
		"Animation continuity bound"
	):
		return false
	for index: Variant in animations.slots:
		if not schema._int(index, 0, 179, "Animation slot"):
			return false
		var slot: Variant = animations.slots[index]
		if not schema._shape(slot, ["start", "source", "generation", "program"], "Animation slot"):
			return false
		if not schema._need(slot.start is float and is_finite(slot.start), "Animation start"):
			return false
		if not schema._shape(slot.source, ANIMATION_SOURCE_FIELDS, "Animation source identity"):
			return false
		var complete: Dictionary = schema.definition.catalog._actor(0, 0, Vector2i.ZERO, 0)
		complete.merge(slot.source, true)
		if (
			not schema._record("actor", complete)
			or not schema._int(slot.generation, 0, 0x7fffffffffffffff, "Animation generation")
		):
			return false
		if not schema._need(
			slot.source.frame == 0 or schema.definition.catalog.frames.has(slot.source.frame),
			"Animation source frame"
		):
			return false
		if not schema._need(
			(
				slot.program is int
				and (slot.program == 0 or schema.definition.catalog.animations.has(slot.program))
			),
			"Animation program source id"
		):
			return false
	if not _validate_music(presentation.music, schema):
		return false
	if not schema._need(presentation.card_music is Dictionary, "Card music record"):
		return false
	return presentation.card_music.is_empty() or _validate_music(presentation.card_music, schema)


func _validate_music(music: Variant, schema: RefCounted) -> bool:
	if not schema._shape(music, ["track", "paused", "cue_paused", "loop"], "music selection"):
		return false
	if not schema._int(music.track, 0, 16, "Music track"):
		return false
	return schema._need(
		music.paused is bool and music.cue_paused is bool and music.loop is bool,
		"Music selection format"
	)


func _capture_music(audio: Node) -> Dictionary:
	# Playback position is deliberately local. Restore restarts the selected
	# original track; no sample clock or cross-client music synchronization.
	return {
		"track": audio.music_track,
		"paused": audio._paused,
		"cue_paused": audio._cue_paused,
		"loop": audio.music_loop
	}


func _restore_music(audio: Node, music: Dictionary) -> void:
	if int(music.track) == 0:
		audio.stop_all()
	else:
		audio.play_track(int(music.track), bool(music.loop))
		audio._cue_paused = music.cue_paused
		audio.set_paused(bool(music.paused))


func restore_campaign(scene: Node, campaign: Dictionary) -> void:
	for field: String in CAMPAIGN_FIELDS:
		scene.set(field, campaign[field])
	if campaign.card.is_empty():
		return
	var state: Dictionary = campaign.card
	var rules = preload("res://scripts/frontend/cd_campaign_card_rules.gd")
	var kind: String = (
		"ending"
		if state.phase != "clear" or state._summary
		else rules.destination(int(campaign.level_number))
	)
	var card: Control = (
		load("res://scenes/campaign_%s/campaign_%s.tscn" % [kind, kind]).instantiate()
	)
	card.result = state.result.duplicate(true)
	card.phase = state.phase
	card.completed.connect(scene._campaign_transition_done.call_deferred)
	card.music_changed.connect(func(_track): scene.get_node("Audio").stop_all())
	var layer := CanvasLayer.new()
	layer.name = "CampaignTransition"
	layer.layer = 20
	scene.add_child(layer)
	scene._campaign_transition = card
	layer.add_child(card)
	# _ready has mounted runtime data. Restore clocks/accepted edges afterwards;
	# rebuilding must not call _tick or grant a fresh card timeout.
	for field: String in CARD_FIELDS:
		card.set(field, state[field])
	card.pages = card.catalog.campaign_pages(
		int(state.result.level),
		int(state.result.kills),
		int(state.result.bonuses),
		rules.power_rating(int(state.result.tally)),
		bool(state._summary)
	)
	card.layout = {}
	card.clearing_text.clear()
	if state.phase != "continue":
		card.layout = card.catalog.campaign_layout(
			card.pages[int(state.page_index)],
			int(preload("res://scripts/frontend/cd_frontend_settings.gd").values().language)
		)
		if int(state._closing) > 0:
			card.clearing_text = (
				card
				. layout
				. commands
				. filter(func(glyph): return int(glyph.tick) <= int(state._close_age))
				. duplicate(true)
			)
	elif not state._continuation_exit.is_empty():
		card.clearing_text = card._continuation_commands().duplicate(true)
	card.update_text_static(int(state._text_static_tick))
	card._update_background()
