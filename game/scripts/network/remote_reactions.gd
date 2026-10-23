extends RefCounted
## Confirmed reaction artwork has a local lifetime. Authoritative records remain
## current: these copied frames never supply collision, hits, AI or progression.
const Selection = preload("res://scripts/simulation/cd_actor_animation.gd")
var _catalog: Resource
var _slots: Dictionary = {}
var _clips: Dictionary = {}
var _ghosts: Array = []
const MAX_GHOSTS := 180


func configure(catalog: Resource) -> void:
	_catalog = catalog
	_slots.clear()
	_clips.clear()
	_ghosts.clear()


func synchronize(before: Dictionary, after: Dictionary, time: float) -> void:
	if before.is_empty():
		return  # Late join is current state, not a replay of historical reactions.
	var old: Dictionary = before.records.actor_system
	var current: Dictionary = after.records.actor_system
	for slot: int in _slots.keys():
		if (
			slot >= current.actors.size()
			or _slots[slot].generation != current.entity_generations[slot]
		):
			if bool(_slots[slot].detached):
				_ghosts.append(_slots[slot])
			_slots.erase(slot)
	while _ghosts.size() > MAX_GHOSTS:
		_ghosts.pop_front()
	for slot: int in range(current.actors.size()):
		var actor: Dictionary = current.actors[slot]
		var previous: Dictionary = old.actors[slot] if slot < old.actors.size() else {}
		var same: bool = (
			slot < old.entity_generations.size()
			and old.entity_generations[slot] == current.entity_generations[slot]
		)
		if (
			same
			and int(actor.kind) == int(previous.get("kind", 0))
			and int(actor.get("health", 0)) >= int(previous.get("health", 0))
		):
			continue  # A routine motion/frame publication is not a new reaction.
		var root := 0
		var detached := false
		var stops: Array = []
		var parameters: Dictionary = _catalog.parameters.get(int(actor.get("parameter", 0)), {})
		if int(actor.kind) == 48 and (not same or int(previous.get("kind", 0)) != 48):
			root = 0x3044e  # Source mine/prop/projectile/core explosion program.
			detached = true
		elif same and int(actor.kind) == 23 and int(previous.get("kind", 0)) != 23:
			root = (
				0x30592 if int(previous.get("kind", 0)) == 20 else int(parameters.get("death", 0))
			)
			detached = true
		elif same and int(actor.kind) == 21 and int(previous.get("kind", 0)) == 4:
			root = 0x30442  # Confirmed final-core transition, no countdown rule here.
			detached = true
		elif (
			same
			and int(actor.kind) >= 1
			and int(actor.kind) <= 19
			and int(actor.get("health", 0)) < int(previous.get("health", 0))
		):
			root = int(parameters.get("hurt", 0))
			stops = [int(parameters.get("idle", 0)), int(parameters.get("walk", 0))]
		if root == 0:
			continue
		var clip := _clip(root, stops)
		if clip.is_empty() or (int(actor.kind) == 23 and int(actor.frame) not in clip):
			continue
		_slots[slot] = {
			"generation": current.entity_generations[slot],
			"start": time,
			"frames": clip,
			"detached": detached,
			"actor": actor.duplicate(true)
		}


func sample(actors: Array, time: float) -> Array:
	for slot: int in _slots.keys():
		var reaction: Dictionary = _slots[slot]
		var frame := maxi(
			0, int(floor((time - float(reaction.start)) / Selection.FRAME_PERIOD_TICKS))
		)
		if frame >= reaction.frames.size() or slot >= actors.size():
			_slots.erase(slot)
			continue
		if int(actors[slot].kind) == 0 and not reaction.detached:
			_slots.erase(slot)
			continue
		if int(actors[slot].kind) != 0:
			reaction.actor = actors[slot].duplicate(true)
		var shown: Dictionary = reaction.actor.duplicate(true)
		shown.frame = reaction.frames[frame]
		actors[slot] = shown  # Only the disposable render array, never public state.
	for index: int in range(_ghosts.size() - 1, -1, -1):
		var reaction: Dictionary = _ghosts[index]
		var frame := maxi(
			0, int(floor((time - float(reaction.start)) / Selection.FRAME_PERIOD_TICKS))
		)
		if frame >= reaction.frames.size():
			_ghosts.remove_at(index)
		else:
			var shown: Dictionary = reaction.actor.duplicate(true)
			shown.frame = reaction.frames[frame]
			actors.append(shown)  # Retired identity, separate from the new occupant.
	return actors


func _clip(root: int, stops: Array) -> Array:
	var key := [root, stops]
	if _clips.has(key):
		return _clips[key]
	var frames: Array = []
	if not _catalog.animations.has(root) or not _catalog.frames.has(int(_catalog.animations[root])):
		return frames
	var actor := {"kind": 1, "cursor": root, "frame": int(_catalog.animations[root]), "timer": 6}
	var visited := {}
	for _entry: int in range(256):
		var cursor: int = actor.cursor
		if visited.has(cursor) or (not frames.is_empty() and cursor in stops):
			break
		visited[cursor] = true
		frames.append(int(actor.frame))
		var next := Selection.select(actor, cursor + 4, _catalog)
		if next.deleted or int(next.state.cursor) == 0:
			break
		actor = next.state
	_clips[key] = frames
	return frames
