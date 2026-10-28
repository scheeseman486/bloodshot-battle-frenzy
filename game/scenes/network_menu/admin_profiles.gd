extends "res://scripts/frontend/cd_small_menu_view.gd"
## Local profile import/verification and public identity export. No secret export.
const Profile = preload("res://scripts/network/admin_profile.gd")
var _addresses: Array = []
var _page := 0
var status := ""
var _picker: FileDialog
var _trust: Control
var _candidate: Dictionary = {}


func _ready() -> void:
	initial_menu = "profiles"
	allow_attract = false
	NetworkSettings.load_profile()
	super._ready()


func menu_definition(_name: String) -> Dictionary:
	_addresses = NetworkSettings.admin_pins.keys()
	_addresses.sort()
	var items := [
		{"native": "Copy My Public Fingerprint", "choices": 0, "address": 0},
		{"native": "Import Server Profile", "choices": 0, "address": 0},
		{
			"native": "Password: " + ("none" if NetworkSettings.password.is_empty() else "set"),
			"choices": 0,
			"address": 0
		}
	]
	for address: String in _addresses.slice(_page * 4, _page * 4 + 4):
		items.append(
			{
				"native":
				"Manage " + (address if address.length() <= 24 else address.left(21) + "..."),
				"choices": 0,
				"address": 0
			}
		)
	if _addresses.size() > 4:
		items.append({"native": "More Servers", "choices": 0, "address": 0})
	items.append({"native": "Back", "choices": 0, "address": 0})
	return {"row": 3, "items": items}


func _activate(row: int) -> void:
	if row < 1 or row > labels.size():
		return
	if row == 1:
		if NetworkSettings.identity != null:
			DisplayServer.clipboard_set(
				preload("res://scripts/network/network_auth.gd").fingerprint(
					NetworkSettings.identity
				)
			)
			status = "Public fingerprint copied"
	elif row == 2:
		_picker = FileDialog.new()
		_picker.access = FileDialog.ACCESS_FILESYSTEM
		_picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_picker.use_native_dialog = true
		_picker.title = "Select public Bloodshot server profile"
		_picker.filters = PackedStringArray(["*.json ; Public server profile"])
		_picker.file_selected.connect(_selected)
		_picker.canceled.connect(_picker_closed)
		add_child(_picker)
		_picker.popup_centered_ratio(.7)
	elif row == 3:
		open_network_entry(3)
	elif row - 4 < mini(4, _addresses.size() - _page * 4):
		var address: String = _addresses[_page * 4 + row - 4]
		get_tree().set_meta("admin_request", {"address": address})
		switch_scene("res://scenes/network_menu/server_admin.tscn")
	elif _addresses.size() > 4 and row == labels.size() - 1:
		_page = posmod(_page + 1, ceili(_addresses.size() / 4.0))
		open_menu("profiles")
	else:
		_go_back()
	menu_state.chosen = 0


func _selected(path: String) -> void:
	_picker_closed()
	var reader := Profile.new()
	_candidate = reader.read_file(path)
	if _candidate.is_empty():
		status = reader.last_error
		return
	_reset_controls_edges()
	_trust = preload("res://scenes/small_notice/small_notice.tscn").instantiate()
	_trust.modal = true
	_trust.confirmation = true
	_trust.font = _hint_font
	_trust.heading = "Verify server identity"
	var lines := PackedStringArray(["Trust this server?"])
	var endpoint := Profile.endpoint(_candidate)
	for offset: int in range(0, endpoint.length(), 32):
		lines.append(endpoint.substr(offset, 32))
	lines.append_array(
		PackedStringArray(
			[
				"Compare with the server owner",
				"through a trusted channel.",
				"Certificate SHA-256 (PEM text):",
				str(_candidate.certificate).sha256_text().left(32),
				str(_candidate.certificate).sha256_text().right(32),
				"This grants no admin rights."
			]
		)
	)
	_trust.text = "\n".join(lines)
	_trust.dismissed.connect(func(accepted: bool):
		if accepted: _trust_profile()
		else: _trust_closed())
	add_child(_trust)


func _trust_profile() -> void:
	var profile := Profile.new()
	status = "Server profile trusted" if profile.install(_candidate) else profile.last_error
	_trust_closed()
	open_menu("profiles")


func _picker_closed() -> void:
	if is_instance_valid(_picker):
		_picker.queue_free()
	_picker = null
	_reset_controls_edges()


func _trust_closed() -> void:
	if is_instance_valid(_trust):
		_trust.queue_free()
	_trust = null
	_candidate.clear()
	_reset_controls_edges()


func _tick() -> void:
	if is_instance_valid(_picker) or is_instance_valid(_trust):
		return
	super._tick()


func _input(event: InputEvent) -> void:
	if is_instance_valid(_picker) or is_instance_valid(_trust):
		return
	super._input(event)


func _go_back() -> void:
	get_tree().set_meta("multiplayer_menu", true)
	switch_scene("res://scenes/main_menu/main_menu.tscn")


func network_entry_return() -> String:
	return "profiles"


func small_menu_heading() -> String:
	return "Server Administration"


func small_menu_footer() -> String:
	return status
