extends RefCounted
## Independent human/bot display ordinals. Seats still own colour and identity.
## Use the whole roster, never score order or the current results page.

static func ordinal(rows: Array, seat: int, bot: bool, reference: Dictionary = {}) -> int:
	var result := 1
	for value: Variant in rows:
		var other_seat: int
		var other_bot: bool
		var other_reference: Dictionary
		if value is Array:
			other_seat = int(value[2])
			other_bot = int(value[5]) == -3
			other_reference = {"id": value[0], "generation": value[1]}
		else:
			other_seat = int(value.seat)
			other_bot = value.get("controller", "human") == "bot"
			other_reference = value.get("reference", {})
		if other_bot != bot:
			continue
		var earlier := other_seat < seat
		# Frozen standings can retain more than one incarnation of a seat.
		if other_seat == seat and not reference.is_empty() and not other_reference.is_empty():
			earlier = int(other_reference.id) < int(reference.id) or (int(other_reference.id) == int(reference.id) and int(other_reference.generation) < int(reference.generation))
		if earlier:
			result += 1
	return result


static func label(rows: Array, seat: int, bot: bool, reference: Dictionary = {}, compact: bool = false) -> String:
	if not bot and not compact:
		for value: Variant in rows:
			var candidate: Dictionary = {"id": value[0], "generation": value[1]} if value is Array else value.get("reference", {})
			var candidate_seat: int = int(value[2]) if value is Array else int(value.seat)
			if (candidate == reference if not reference.is_empty() else candidate_seat == seat):
				var name: String = str(value[6]) if value is Array and value.size() == 7 else (str(value.get("name", "")) if value is Dictionary else "")
				if not name.is_empty(): return name
	return ("BOT %d" if bot else ("P%d" if compact else "PLAYER %d")) % ordinal(rows, seat, bot, reference)


static func roster(world: RefCounted) -> Array:
	var result := []
	for player: RefCounted in world.players:
		result.append({"reference": player.player_ref(), "seat": player.seat,
			"controller": "bot" if world.bots.is_bot(player.player_ref()) else "human"})
		if not player.public_name.is_empty(): result.back().name = player.public_name
	return result
