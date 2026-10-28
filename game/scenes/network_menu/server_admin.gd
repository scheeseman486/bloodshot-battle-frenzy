extends Node3D
## Management composition root: source-font menus, no world/avatar/audio world.
var endpoint: Node
var host_endpoint: Node
var settings := preload("res://scripts/input/cd_input_settings.gd").new()
var _menu: Control
var _closing := false
var _was_available := false


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	endpoint = preload("res://scripts/network/replication_peer.gd").new()
	add_child(endpoint)
	var request: Dictionary = get_tree().get_meta("admin_request", {})
	if get_tree().has_meta("admin_request"):
		get_tree().remove_meta("admin_request")
	var address := str(request.get("address", ""))
	var split := address.rfind(":")
	var profile := preload("res://scripts/network/network_settings.gd")
	var configured := profile.configure(endpoint.transport)
	endpoint.transport.purpose = "manage"
	endpoint.admin.completed.connect(_result)
	endpoint.admin.changed.connect(_changed)
	_menu = preload("res://scenes/network_menu/session_menu.tscn").instantiate()
	_menu.game = self
	_menu.leave_requested.connect(leave_game)
	_menu.resumed.connect(func(): endpoint.admin.refresh_players())
	add_child(_menu)
	_menu.status = "Connecting to server"
	if (
		not configured
		or split < 1
		or not endpoint.transport.connect_to(address.left(split), int(address.substr(split + 1)))
	):
		_menu.status = profile.last_error if not configured else endpoint.transport.last_error
		if _menu.status.is_empty():
			_menu.status = "Select a trusted server profile"
		return
	endpoint.phase = "connecting"


func _process(_delta: float) -> void:
	if _closing or endpoint == null:
		return
	endpoint.pump(Time.get_ticks_msec())
	if endpoint.phase in ["rejected", "disconnected"]:
		_menu.status = (
			endpoint.last_error
			if not endpoint.last_error.is_empty()
			else (
				endpoint.admin.last_error
				if not endpoint.admin.last_error.is_empty()
				else "Disconnected"
			)
		)


func _changed() -> void:
	if _closing or not is_instance_valid(_menu):
		return
	if endpoint.admin.available:
		if not _was_available:
			_menu.status = "Administration connected"
			endpoint.admin.refresh_players()
		_was_available = true
	else:
		_was_available = false
		_menu.status = "Administration access unavailable"
		_menu.open_menu("session")


func request_admin(action: String, value: Variant = null) -> bool:
	var accepted: bool = endpoint.admin.request(action, value)
	if not accepted:
		_menu.status = "Wait for the current server request"
	return accepted


func _result(action: String, accepted: bool, error: String) -> void:
	_menu.admin_result(action, accepted, error)


func leave_game() -> void:
	if _closing:
		return
	_closing = true
	endpoint.close()
	get_tree().change_scene_to_file("res://scenes/network_menu/admin_profiles.tscn")


func _exit_tree() -> void:
	if is_instance_valid(endpoint):
		endpoint.close()
