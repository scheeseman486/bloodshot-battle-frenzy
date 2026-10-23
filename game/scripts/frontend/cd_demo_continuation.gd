class_name CdDemoContinuation
extends RefCounted
## One authoritative implementation of the existing single-player CD demo clock.
## Only its reader/cursors are checkpoint state; records remain runtime CD data.
const Playback = preload("res://scripts/frontend/cd_demo_playback.gd")


static func advance(world: RefCounted, index: int, visibility: Dictionary = {}) -> void:
	var state: Dictionary = world.demo_state
	if state.finished:
		return
	var player: RefCounted = world.players[0]
	world.sample_controls({player.id: 0xffffffff})
	if index % int(world.timing_profile.samples_per_update) != 0:
		return
	state.reader = Playback.input(state.reader, world.demo_recording.records, 0)
	if (int(state.reader.edge) & 128) == 0:
		state.finished = true
		return
	state.world_calls += 1
	player.sample_demo_record(int(state.reader.held), int(state.reader.edge))
	while state.action_cursor < world.demo_recording.actions.size():
		var command: Dictionary = world.demo_recording.actions[int(state.action_cursor)]
		if int(command.update) > int(state.world_calls):
			break
		if int(command.update) == int(state.world_calls):
			world.demo_actions.append(command)
		state.action_cursor += 1
	world.step(6, visibility)
