extends RefCounted
## Shared media discovery. Overrides serve unattended tools; releases remember
## imports in user://, independently of executable name, cwd or AppImage mount.
const POINTER_NAME := "active-image.json"
const COPY_PATH := "user://original-media/bloodshot-europe.chd"
static var selected_path := ""


static func resolve() -> String:
	var installed := installed_path()
	return choose(OS.get_cmdline_user_args(), OS.get_environment("BLOODSHOT_DISC"),
		OS.has_feature("editor"),
		str(ProjectSettings.get_setting("bloodshot/source/disc_path", "")),
		release_folder(OS.get_executable_path(), OS.get_environment("APPDIR"),
			OS.get_environment("APPIMAGE")), not installed.is_empty(), installed)


static func choose(arguments: PackedStringArray, environment: String, editor: bool,
		configured: String, executable_folder: String, installed: bool, managed: String = COPY_PATH) -> String:
	if not selected_path.is_empty():
		return selected_path
	for index: int in range(arguments.size() - 1):
		if arguments[index] == "--disc":
			return arguments[index + 1]
	if not environment.is_empty():
		return environment
	if editor:
		return "res://" + configured
	if installed:
		return managed
	return executable_folder.path_join("roms").path_join(configured.get_file())


## The pointer accepts only owned install names, never an arbitrary filesystem
## path from a local JSON file. Legacy single-CHD installs remain discoverable.
static func installed_path(folder: String = "user://original-media") -> String:
	var pointer := folder.path_join(POINTER_NAME)
	if FileAccess.file_exists(pointer):
		var file := FileAccess.open(pointer, FileAccess.READ)
		if file != null and file.get_length() <= 1024:
			var value: Variant = JSON.parse_string(file.get_as_text())
			if value is Dictionary and value.size() == 2 and value.get("schema") == 1 and value.get("path") is String:
				var name: String = value.path
				var valid := name == COPY_PATH.get_file()
				if name.begins_with("sets/cue-") and name.ends_with("/disc.cue"):
					var id := name.trim_prefix("sets/cue-").trim_suffix("/disc.cue")
					valid = id.length() == 24
					for character: String in id:
						if not character in "0123456789abcdef": valid = false
				var path := folder.path_join(name)
				if valid and FileAccess.file_exists(path): return path
	var legacy := folder.path_join(COPY_PATH.get_file())
	return legacy if FileAccess.file_exists(legacy) else ""


## Ignore a launcher's inherited AppImage variables unless this executable is
## actually inside that mount. Managed media never depends on these variables.
static func release_folder(executable: String, appdir: String, appimage: String) -> String:
	if not appdir.is_empty() and not appimage.is_empty():
		if executable.begins_with(appdir.trim_suffix("/") + "/"):
			return appimage.get_base_dir()
	return executable.get_base_dir()
