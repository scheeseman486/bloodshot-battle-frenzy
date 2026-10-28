@tool
class_name CdAudioSettings
extends RefCounted
## Project-local runtime buses and user preferences. No global editor or device
## settings are changed; the Godot process owns these audio buses.
const MdCatalog = preload("res://scripts/audio/md_audio_catalog.gd")
const RomImport = preload("res://scripts/assets/md_rom_import.gd")
static var config_path := "user://audio.cfg"
static var _providers := {"music": "cd", "effects": "cd"}
static var _rom_path := ""
static var cartridge: RefCounted
static var cartridge_error := ""
static var _notice_shown := ""
static var _worker: Thread
static var _candidate_path := ""
static var _candidate: RefCounted
static var _revision := 0
static var _ready := false
static var _source_mode := 1
static var _volumes := {"Effects": 1.0, "Music": 1.0}
static var _stored_volumes := {"Effects": 1.0, "Music": 1.0}
static var _volume_controls := false


static func ensure() -> void:
	if _ready:
		return
	_ready = true
	var preferences := ConfigFile.new()
	preferences.load(config_path)
	var volume_controls: Variant = preferences.get_value("mix", "volume_controls", false)
	_volume_controls = volume_controls is bool and volume_controls
	for key: String in _providers:
		var raw: Variant = preferences.get_value("provider", key, "cd")
		_providers[key] = raw if raw is String and raw in ["cd", "md"] else "cd"
	_rom_path = str(preferences.get_value("provider", "rom_path", ""))
	if _rom_path.is_empty():
		_rom_path = OS.get_environment("BLOODSHOT_ROM")
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and not tree.root.tree_exiting.is_connected(shutdown):
		tree.root.tree_exiting.connect(shutdown)
	for bus: String in ["Effects", "Music"]:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus)
		AudioServer.set_bus_send(AudioServer.get_bus_index(bus), "Master")
		var volume: Variant = preferences.get_value("volume", bus, 1.0)
		_apply_volume(
			bus,
			(
				clampf(float(volume), 0.0, 1.0)
				if (volume is int or volume is float) and is_finite(volume)
				else 1.0
			)
		)
	_stored_volumes = _volumes.duplicate()
	_start_cartridge(_rom_path, RomImport.release_folder(), RomImport.COPY_PATH)


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
	if bus not in _volumes or not is_finite(linear):
		return
	_apply_volume(bus, clampf(linear, 0.0, 1.0))
	_stored_volumes[bus] = _volumes[bus]
	_save()


static func preview_volume(bus: String, linear: float) -> void:
	ensure()
	if bus in _volumes and is_finite(linear):
		_apply_volume(bus, clampf(linear, 0.0, 1.0))


static func restore_user_mix(legacy_mode: int = 1) -> Error:
	ensure()
	# The removed discrete native preference becomes explicit zero channel gains.
	# Do not create a config on first boot with the default, fully enabled mix.
	if not _volume_controls and legacy_mode in [2, 3, 4]:
		var candidate := _volumes.duplicate()
		if legacy_mode in [2, 4]:
			candidate.Music = 0.0
		if legacy_mode in [3, 4]:
			candidate.Effects = 0.0
		var result := save_mix(candidate, _providers)
		if result != OK:
			# A read-only profile can prevent migration persistence. Keep the
			# live mix explicit anyway, so no removed setting masks a slider.
			set_source_mode(1)
			for bus: String in candidate:
				preview_volume(bus, float(candidate[bus]))
			return result
	set_source_mode(1)
	return OK


static func save_mix(volumes: Dictionary, providers: Dictionary) -> Error:
	ensure()
	if volumes.size() != 2 or providers.size() != 2:
		return ERR_INVALID_PARAMETER
	for bus: String in ["Music", "Effects"]:
		var value: Variant = volumes.get(bus)
		if not (value is float or value is int) or not is_finite(value) or value < 0 or value > 1:
			return ERR_INVALID_PARAMETER
	for kind: String in ["music", "effects"]:
		var value: Variant = providers.get(kind)
		if not value is String or value not in ["cd", "md"]:
			return ERR_INVALID_PARAMETER
		if value == "md" and cartridge == null and _providers[kind] != "md":
			return ERR_UNAVAILABLE
	var result := _write_preferences(volumes, providers, true)
	if result != OK:
		return result
	_volume_controls = true
	_providers = providers.duplicate()
	_stored_volumes = volumes.duplicate()
	set_source_mode(1)
	for bus: String in volumes:
		_apply_volume(bus, float(volumes[bus]))
	_revision += 1
	return OK


static func _save() -> Error:
	# Loading optional media may save its path while sliders are previewing.
	# Such writes must never persist an unsaved preview mix.
	return _write_preferences(_stored_volumes, _providers, _volume_controls)


static func _write_preferences(
	volumes: Dictionary, providers: Dictionary, volume_controls: bool
) -> Error:
	var preferences := ConfigFile.new()
	preferences.load(config_path)
	for name: String in ["Effects", "Music"]:
		preferences.set_value("volume", name, float(volumes[name]))
	for key: String in providers:
		preferences.set_value("provider", key, providers[key])
	preferences.set_value("mix", "volume_controls", volume_controls)
	preferences.set_value("provider", "rom_path", _rom_path)
	var result := preferences.save(config_path + ".tmp")
	if result == OK:
		result = DirAccess.rename_absolute(config_path + ".tmp", config_path)
	return result


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


static func provider(kind: String) -> String:
	ensure()
	return str(_providers.get(kind, "cd"))


static func active_provider(kind: String) -> String:
	poll_cartridge()
	return "md" if provider(kind) == "md" and cartridge != null else "cd"


static func revision() -> int:
	poll_cartridge()
	return _revision


static func preparing() -> bool:
	return _worker != null


static func prepare_cartridge(path: String) -> void:
	_start_cartridge(path, "", RomImport.COPY_PATH)


static func _start_cartridge(path: String, search_folder: String, destination: String) -> void:
	if _worker != null:
		return
	_candidate = MdCatalog.new()
	_candidate_path = ""
	_worker = Thread.new()
	var result := _worker.start(
		func():
			var imported: Dictionary = (
				RomImport.discover(path, search_folder, destination)
				if not search_folder.is_empty()
				else RomImport.take_rom(path, destination)
			)
			_candidate_path = imported.path
			_candidate.error = imported.error
			if not _candidate_path.is_empty() and _candidate.load_rom(_candidate_path):
				_candidate.prepare()
	)
	if result != OK:
		_worker = null
		_candidate = null
		cartridge_error = "Could not prepare cartridge audio. CD audio is active."


static func poll_cartridge() -> void:
	if _worker == null or _worker.is_alive():
		return
	_worker.wait_to_finish()
	_worker = null
	cartridge_error = str(_candidate.error)
	if cartridge_error.is_empty() and not _candidate_path.is_empty():
		cartridge = _candidate
		_rom_path = _candidate_path
		_save()
		_revision += 1
	elif cartridge_error.is_empty() and "md" in _providers.values():
		cartridge_error = "Cartridge audio is unavailable. CD audio is active. Locate the original ROM in Audio settings."
	_candidate = null


static func set_provider(kind: String, value: String) -> bool:
	ensure()
	poll_cartridge()
	if not _providers.has(kind) or value not in ["cd", "md"]:
		return false
	if value == "md" and cartridge == null:
		return false
	var previous: String = _providers[kind]
	_providers[kind] = value
	if _save() != OK:
		_providers[kind] = previous
		cartridge_error = "Could not save audio preferences."
		return false
	_revision += 1
	return true


static func shutdown() -> void:
	if _worker != null:
		_worker.wait_to_finish()
		_worker = null
	_candidate = null


static func take_notice() -> String:
	if (
		cartridge_error.is_empty()
		or cartridge_error == _notice_shown
		or not "md" in _providers.values()
	):
		return ""
	_notice_shown = cartridge_error
	return cartridge_error
