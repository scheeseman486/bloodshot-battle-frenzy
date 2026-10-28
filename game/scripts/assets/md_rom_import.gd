extends RefCounted
## Optional original cartridge installation. Only the supported raw image is
## accepted; filenames never identify content. Call from the cartridge worker.
const Catalog = preload("res://scripts/audio/md_audio_catalog.gd")
const DiscLocation = preload("res://scripts/assets/disc_location.gd")
const COPY_PATH := "user://original-media/bloodshot-europe.md"


static func release_folder() -> String:
	return DiscLocation.release_folder(
		OS.get_executable_path(), OS.get_environment("APPDIR"), OS.get_environment("APPIMAGE")
	)


## A verified install survives moving/removing the adjacent original. A missing
## remembered path can recover from that install or a newly adjacent image.
static func discover(
	preferred: String, folder: String, destination: String = COPY_PATH
) -> Dictionary:
	var catalog := Catalog.new()
	if catalog.load_rom(destination):
		return {"path": destination, "error": ""}
	var why := ""
	if not preferred.is_empty():
		if catalog.load_rom(preferred):
			return _install(catalog.bytes, destination)
		why = catalog.error
	var directory := DirAccess.open(folder)
	if directory != null:
		directory.include_hidden = true
		for name: String in directory.get_files():
			var path := folder.path_join(name)
			if catalog.load_rom(path):
				return _install(catalog.bytes, destination)
	return {"path": "", "error": why}


## Explicit picker choices must pass validation even if a valid install exists.
static func take_rom(path: String, destination: String = COPY_PATH) -> Dictionary:
	var catalog := Catalog.new()
	if not catalog.load_rom(path):
		return {"path": "", "error": catalog.error}
	return _install(catalog.bytes, destination)


static func _install(bytes: PackedByteArray, destination: String) -> Dictionary:
	if Catalog.new().load_rom(destination):
		return {"path": destination, "error": ""}
	var folder := destination.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(folder) != OK:
		return {"path": "", "error": "Cannot create the game's cartridge folder."}
	var temporary := (
		destination + ".importing-" + Crypto.new().generate_random_bytes(12).hex_encode()
	)
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return {"path": "", "error": "Cannot write the game's cartridge folder."}
	file.store_buffer(bytes)
	file.flush()
	var result := file.get_error()
	file.close()
	if result != OK:
		DirAccess.remove_absolute(temporary)
		return {"path": "", "error": "Could not save the cartridge copy. Check free disk space."}
	var why := _promote(temporary, destination)
	return {"path": destination if why.is_empty() else "", "error": why}


## Verify bytes read back from disk before replacing any previous install.
static func _promote(temporary: String, destination: String) -> String:
	var why := ""
	if not Catalog.new().load_rom(temporary):
		why = "The copied cartridge is incomplete or damaged. Please try again."
	elif DirAccess.rename_absolute(temporary, destination) != OK:
		why = "Cannot install the cartridge copy in the game's user folder."
	if not why.is_empty():
		DirAccess.remove_absolute(temporary)
	return why
