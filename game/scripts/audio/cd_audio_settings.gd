@tool
class_name CdAudioSettings
extends RefCounted
## Project-local runtime buses and user preferences. No global editor or device
## settings are changed; the Godot process owns these audio buses.
static var _ready := false
static var _source_mode := 1
static var _volumes := {"Effects": 1.0, "Music": 1.0}


static func ensure() -> void:
	if _ready:
		return
	_ready = true
	var preferences := ConfigFile.new()
	preferences.load("user://audio.cfg")
	for bus: String in ["Effects", "Music"]:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus)
		AudioServer.set_bus_send(AudioServer.get_bus_index(bus), "Master")
		_apply_volume(bus, clampf(float(preferences.get_value("volume", bus, 1.0)), 0.0, 1.0))


static func volume(bus: String) -> float:
	ensure()
	return float(_volumes.get(bus, 1.0))


static func set_source_mode(mode: int) -> void:
	ensure()
	_source_mode = clampi(mode, 1, 4)
	for bus: String in ["Effects", "Music"]:
		_apply_volume(bus, float(_volumes[bus]))


static func set_volume(bus: String, linear: float) -> void:
	ensure()
	_apply_volume(bus, clampf(linear, 0.0, 1.0))
	var preferences := ConfigFile.new()
	for name: String in ["Effects", "Music"]:
		preferences.set_value("volume", name, volume(name))
	preferences.save("user://audio.cfg")


static func _apply_volume(bus: String, linear: float) -> void:
	var index := AudioServer.get_bus_index(bus)
	_volumes[bus] = linear
	var source_silent := (
		_source_mode == 4
		or (bus == "Music" and _source_mode == 2)
		or (bus == "Effects" and _source_mode == 3)
	)
	AudioServer.set_bus_mute(index, linear <= 0.0 or source_silent)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(0.0001, linear)))
