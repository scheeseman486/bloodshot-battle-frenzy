extends "res://scripts/frontend/cd_small_menu_view.gd"
## Native co-op connection page using the existing CD-backed small menu schema.
var address := "127.0.0.1"
var port := "28760"
var status := ""


func _ready() -> void:
	if NetworkSettings.load_profile(): port = str(NetworkSettings.port)
	initial_menu = "network"
	allow_attract = false
	super._ready()


func menu_definition(_name: String) -> Dictionary:
	var items: Array = []
	for label: String in [
		"Join Game",
		"Address: " + (address if address.length() <= 26 else address.left(23) + "..."),
		"Port: " + port,
		"Password: " + ("set" if not NetworkSettings.password.is_empty() else "none"),
		"Exit"
	]:
		items.append({"native": label, "choices": 0, "address": 0})
	return {"row": 3, "items": items}


func _activate(row: int) -> void:
	if row == 1:
		if not valid_endpoint(address, port):
			status = "Enter an address and port 1-65535"
			return
		get_tree().set_meta("network_request", {"host": false, "address": address, "port": port})
		switch_scene("res://scenes/network_gameplay/network_gameplay.tscn")
	elif row == 4:
		open_network_entry(3)
	elif row in [2, 3]:
		_reset_controls_edges()
		menu_state.chosen = 0
		var dialog := TextEntry.new()
		_text_entry = dialog
		dialog.font = _hint_font
		dialog.heading = "Address" if row == 2 else "Port"
		dialog.initial = address if row == 2 else port
		dialog.limit = 253 if row == 2 else 5
		dialog.validate = func(value: String) -> String:
			if row == 2:
				if not valid_endpoint(value, port): return "Enter an address or hostname"
				address = value.strip_edges()
			else:
				if not valid_endpoint(address, value): return "Enter a port from 1 to 65535"
				var previous := NetworkSettings.port
				NetworkSettings.port = int(value)
				if not NetworkSettings.save():
					NetworkSettings.port = previous
					return "Could not save port"
				port = value
			return ""
		dialog.navigation.connect(func(): $Audio.play_source(0x2547e))
		dialog.dismissed.connect(func(_accepted):
			_text_entry = null
			_reset_controls_edges()
			open_menu("network"))
		add_child(dialog)
	else:
		_go_back()


func network_entry_return() -> String:
	return "network"


static func valid_endpoint(host: String, number: String) -> bool:
	return (
		not host.strip_edges().is_empty()
		and host.length() <= 253
		and number.is_valid_int()
		and int(number) >= 1
		and int(number) <= 65535
	)


func _go_back() -> void:
	get_tree().set_meta("multiplayer_menu", true)
	switch_scene("res://scenes/main_menu/main_menu.tscn")


func small_menu_heading() -> String:
	return "Join Game"


func small_menu_footer() -> String:
	return status if not status.is_empty() else "IP address or hostname and server port"
