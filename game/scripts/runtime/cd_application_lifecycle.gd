class_name CdApplicationLifecycle
extends Node
## Own application exits. AudioServer releases stopped playback asynchronously;
## the extension must remain loaded until those mixer references are retired.
const META := &"bloodshot_application_lifecycle"
var _requested := false
var _exit_code := 0
var _tracked: Array[WeakRef] = []


static func install(tree: SceneTree) -> Node:
	if tree.has_meta(META):
		return tree.get_meta(META)
	var lifecycle: Node = load("res://scripts/runtime/cd_application_lifecycle.gd").new()
	lifecycle.name = "ApplicationLifecycle"
	lifecycle.process_mode = Node.PROCESS_MODE_ALWAYS
	tree.set_meta(META, lifecycle)
	tree.root.add_child.call_deferred(lifecycle)
	return lifecycle


static func request_quit(tree: SceneTree, code: int = 0) -> void:
	install(tree)._request(code)


static func track_playback(tree: SceneTree, playback: AudioStreamPlayback) -> void:
	if not tree.has_meta(META):
		return
	var owner: Node = tree.get_meta(META)
	for index: int in range(owner._tracked.size() - 1, -1, -1):
		if owner._tracked[index].get_ref() == null:
			owner._tracked.remove_at(index)
	owner._tracked.append(weakref(playback))


static func stop_audio(tree: SceneTree) -> Array[WeakRef]:
	var retired: Array[WeakRef] = []
	if tree.has_meta(META):
		retired.append_array(tree.get_meta(META)._tracked)
	for service: Node in tree.get_nodes_in_group("bloodshot_audio_services"):
		retired.append_array(service.shutdown_playbacks())
	return retired


static func wait_for_audio(tree: SceneTree, retired: Array[WeakRef]) -> bool:
	# This is a bounded drain, not a fixed exit delay. Keep the main loop alive
	# for AudioServer's normal fade and safe-list reclamation on both threads.
	var deadline := Time.get_ticks_msec() + 1000
	while retired.any(func(reference: WeakRef) -> bool: return reference.get_ref() != null):
		if Time.get_ticks_msec() >= deadline:
			return false
		await tree.process_frame
		await tree.create_timer(0.01).timeout
	return true


func _ready() -> void:
	get_tree().auto_accept_quit = false
	get_tree().root.close_requested.connect(_request)


func _request(code: int = 0) -> void:
	if _requested:
		return
	_requested = true
	_exit_code = code
	_drain.call_deferred()


func _drain() -> void:
	var started := Time.get_ticks_usec()
	var tree := get_tree()
	tree.root.set_disable_input(true)
	var retired: Array[WeakRef] = []
	var deadline := Time.get_ticks_msec() + 1000
	var quiet_frames := 0
	while quiet_frames < 2:
		retired.append_array(stop_audio(tree))
		if tree.current_scene != null:
			tree.current_scene.process_mode = Node.PROCESS_MODE_DISABLED
			tree.current_scene.queue_free()
		# A scene change queued before the close request can instantiate audio
		# after the first pass. Re-scan instead of letting that audio escape.
		for service: Node in tree.get_nodes_in_group("bloodshot_audio_services"):
			service.queue_free()
		await tree.process_frame
		await tree.create_timer(0.01).timeout
		var live := retired.any(
			func(reference: WeakRef) -> bool: return reference.get_ref() != null
		)
		if (
			not live
			and tree.current_scene == null
			and tree.get_nodes_in_group("bloodshot_audio_services").is_empty()
		):
			quiet_frames += 1
		else:
			quiet_frames = 0
		if Time.get_ticks_msec() >= deadline:
			push_error("Audio playback references did not retire before application exit")
			_exit_code = 1
			break
	if "--runtime-audit" in OS.get_cmdline_user_args():
		print(
			"AUDIO_SHUTDOWN_COMPLETE ",
			JSON.stringify(
				{
					"drain_usec": Time.get_ticks_usec() - started,
					"retired_references": retired.size(),
					"exit_code": _exit_code
				}
			)
		)
	tree.quit(_exit_code)


func _exit_tree() -> void:
	if get_tree().get_meta(META, null) == self:
		get_tree().remove_meta(META)
