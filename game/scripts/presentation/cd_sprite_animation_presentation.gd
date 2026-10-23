class_name CdSpriteAnimationPresentation
extends RefCounted
## Native visual playback preserves the original six-PAL-period frame duration,
## independently of AI/combat dispatch. Repeated entries, jumps and terminal
## frames remain source data. Never mutate live actors or let visual completion
## delete an actor, trigger an effect or consume RNG.
const Selection = preload("res://scripts/simulation/cd_actor_animation.gd")
var _catalog: Resource
var _clips: Dictionary = {}
var _slots: Dictionary = {}
var _last_boundary := 0.0


func configure(catalog: Resource) -> void:
	_catalog = catalog
	_clips.clear()
	_slots.clear()
	_last_boundary = 0.0


## Called at each real world boundary, including all updates during a hitch.
## Cursor advancement along the same source program is not a visual restart.
func synchronize(actors: Array, frame_time: float, launches: Dictionary = {}) -> void:
	if frame_time < _last_boundary:
		_slots.clear()
	_last_boundary = frame_time
	for index: int in _slots.keys():
		if index >= actors.size() or int(actors[index].kind) == 0:
			_slots.erase(index)
	for index: int in range(actors.size()):
		var actor: Dictionary = actors[index]
		if int(actor.kind) == 0:
			continue
		var generation := int(launches.get(index, {}).get("generation", 0))
		var slot: Dictionary = _slots.get(index, {})
		if slot.is_empty() or not _continues(slot, actor, generation):
			var remaining := int(actor.get("timer", 0))
			var animated := remaining > 0 and int(actor.get("cursor", 0)) != 0
			# Attachment may observe an entry partway through its source timer.
			# Do not grant it a fresh full hold or run it one entry per display.
			var age := maxi(0, Selection.FRAME_PERIOD_TICKS - remaining) if animated else 0
			slot = {
				"start": frame_time - age,
				"clip": _clip(int(actor.cursor)) if animated else {"frames": [], "loop": -1}
			}
			_slots[index] = slot
		slot.source = {
			"kind": actor.kind,
			"parameter": actor.get("parameter", 0),
			"health": actor.get("health", 0),
			"cursor": actor.get("cursor", 0),
			"frame": actor.get("frame", 0),
			"timer": actor.get("timer", 0)
		}
		slot.generation = generation


## Absolute time makes playback independent of how often drawing is requested.
## Only the frame on a copied view record changes. Forward positions, anchors,
## current kinds, collision dimensions and hidden pending shots stay untouched.
func sample(actors: Array, frame_time: float, owned: bool = false) -> Array:
	var result := actors if owned else actors.duplicate()
	for index: int in _slots:
		if index >= actors.size() or int(actors[index].kind) == 0:
			continue
		var slot: Dictionary = _slots[index]
		if slot.clip.frames.is_empty():
			continue
		# Input-clock restoration can change an actor between world boundaries.
		# Show that event immediately, instead of reviving an obsolete animation.
		if not _same_event(slot.source, actors[index]):
			continue
		var elapsed := maxi(
			0, int(floor((frame_time - float(slot.start)) / Selection.FRAME_PERIOD_TICKS))
		)
		var address := int(actors[index].frame)
		if not slot.clip.frames.is_empty():
			var count: int = slot.clip.frames.size()
			if elapsed >= count:
				var loop: int = slot.clip.loop
				elapsed = loop + (elapsed - loop) % (count - loop) if loop >= 0 else count - 1
			address = int(slot.clip.frames[elapsed])
		if address != int(actors[index].frame):
			if not owned:
				result[index] = actors[index].duplicate()
			result[index].frame = address
	return result


func _same_event(before: Dictionary, after: Dictionary) -> bool:
	return (
		before.get("kind", 0) == after.get("kind", 0)
		and before.get("parameter", 0) == after.get("parameter", 0)
		and before.get("health", 0) == after.get("health", 0)
		and before.get("cursor", 0) == after.get("cursor", 0)
		and before.get("frame", 0) == after.get("frame", 0)
	)


func _continues(slot: Dictionary, actor: Dictionary, generation: int) -> bool:
	var before: Dictionary = slot.source
	for field: String in ["kind", "parameter", "health"]:
		if before.get(field, 0) != actor.get(field, 0):
			return false
	if generation != int(slot.generation):
		return false
	if _same_event(before, actor):
		return true
	var cursor := int(before.get("cursor", 0))
	if cursor == 0 or int(before.get("timer", 0)) == 0 or not _catalog.animations.has(cursor + 4):
		return false
	var expected := Selection.select(before, cursor + 4, _catalog)
	return not expected.deleted and _same_event(expected.state, actor)


func _clip(cursor: int) -> Dictionary:
	if _clips.has(cursor):
		return _clips[cursor]
	var clip := {"frames": [], "loop": -1}
	if (
		not _catalog.animations.has(cursor)
		or not _catalog.frames.has(int(_catalog.animations[cursor]))
	):
		return clip  # Static artwork has no animation program to invent.
	var selected := {
		"kind": 1,
		"cursor": cursor,
		"frame": int(_catalog.animations[cursor]),
		"timer": Selection.FRAME_PERIOD_TICKS
	}
	var visited: Dictionary = {}
	for _entry: int in range(256):
		var at := int(selected.cursor)
		if visited.has(at):
			clip.loop = int(visited[at])
			break
		visited[at] = clip.frames.size()
		clip.frames.append(int(selected.frame))
		var next := Selection.select(selected, at + 4, _catalog)
		if next.deleted or int(next.state.cursor) == 0:
			break  # Retain the final frame until the real simulation removes it.
		selected = next.state
	_clips[cursor] = clip
	return clip
