class_name SilentAudioService
extends Node
## Stable gameplay-facing audio interface for Stage 1. No sound is decoded yet.

signal event_requested(event_id: StringName, world_position: Vector3)

func play_event(event_id: StringName, world_position: Vector3 = Vector3.ZERO) -> void:
	event_requested.emit(event_id, world_position)

func stop_all() -> void:
	pass
