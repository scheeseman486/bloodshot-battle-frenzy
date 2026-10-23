class_name CdOfflineDriver
extends RefCounted
## Scene compatibility surface over one server/client pair. Owns no simulation
## state or clock dispatcher. Historical drivers remain source-test oracles only.
signal updated
var _server: RefCounted
var _client: RefCounted
var _controls: Callable
var aim_rate: Callable
var recording: Dictionary = {}
var clock: RefCounted:
	get:
		return _server.world.clock
var timing_profile: Resource:
	get:
		return _server.world.timing_profile
var finished: bool:
	get:
		return bool(_server.world.demo_state.get("finished", false))
var _world_origin: Vector2i:
	get:
		return _server.session.player.world_origin


func attach(server: RefCounted, client: RefCounted, controls: Callable) -> void:
	_server = server
	_client = client
	_controls = controls
	if not server.updated.is_connected(updated.emit):
		server.updated.connect(updated.emit)


func advance_usec(elapsed: int, budget: int = 32) -> int:
	if recording.is_empty() and _controls.is_valid():
		_client.command(_controls.call(0), float(aim_rate.call()) if aim_rate.is_valid() else 0.0)
	return _server.advance_usec(elapsed, budget)


func aim_units(delta: float) -> void:
	var controls: Dictionary = (
		_controls.call(0) if _controls.is_valid() else {"held": 0xffffffff, "strafe": 0}
	)
	_client.command(controls, float(aim_rate.call()) if aim_rate.is_valid() else 0.0, [delta])


func player_pose() -> Dictionary:
	return _client.presentation_pose()


func world_phase() -> float:
	return _client.phase


func interpolation_fraction() -> float:
	return world_phase()


func animation_frame_time(include_fraction: bool = true) -> float:
	return _client.animation_time if include_fraction else _client.boundary_time
