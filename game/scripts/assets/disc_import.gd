extends RefCounted
## Original media is never written. Stage and compare the complete compressed
## image before a same-directory atomic rename, leaving an old copy on failure.
const Source = preload("res://scripts/assets/original_asset_source.gd")
const COPY_NAME := "bloodshot-europe.chd"
const Location = preload("res://scripts/assets/disc_location.gd")
const CHUNK_SIZE := 2 * 1024 * 1024


static func validate(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "That file cannot be found or read."
	var source := Source.new()
	if not source.mount(path, false):
		return "That file is not a readable CHD or CUE/BIN image. " + source.last_error
	if not source.supported_media():
		return "Please select the supported European Mega CD Bloodshot / Battle Frenzy CHD or CUE/BIN image."
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://resources/assets/cd_data_file_hashes.json"))
	for name: String in manifest.files:
		var entry: Dictionary = manifest.files[name]
		var bytes: PackedByteArray = source.read_range(name)
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(bytes)
		if bytes.size() != int(entry.size) or hash.finish().hex_encode() != entry.sha256:
			return "The disc's %s data is damaged or unsupported. Please choose another image." % name
	return ""


## Await between bounded chunks so a large CD image does not freeze the window.
## With no SceneTree this is also usable by noninteractive import checks.
static func take_disc(path: String, folder: String, tree: SceneTree = null,
		progress: Callable = Callable()) -> String:
	var why := validate(path)
	if not why.is_empty():
		return why
	if path.get_extension().to_lower() == "cue":
		return await _take_cue(path, folder, tree, progress)
	var destination := folder.path_join(COPY_NAME)
	if path.simplify_path() == destination.simplify_path():
		return _activate(COPY_NAME, folder)
	var error := DirAccess.make_dir_recursive_absolute(folder)
	if error != OK:
		return "Cannot create the game's media folder: %s (%s)." % [folder, error_string(error)]
	var temporary := destination + ".importing-" + Crypto.new().generate_random_bytes(12).hex_encode()
	why = await _copy_verified(path, temporary, tree, progress)
	if why.is_empty():
		why = validate(temporary)
	if why.is_empty():
		error = DirAccess.rename_absolute(temporary, destination)
		if error != OK:
			why = "Cannot install the copied image in %s (%s)." % [folder, error_string(error)]
	if not why.is_empty():
		DirAccess.remove_absolute(temporary)
		return why
	return _activate(COPY_NAME, folder)


static func _copy_verified(path: String, temporary: String, tree: SceneTree,
		progress: Callable) -> String:
	var why := ""
	var input := FileAccess.open(path, FileAccess.READ)
	if input == null:
		return "The selected image can no longer be read."
	var size := input.get_length()
	var output := FileAccess.open(temporary, FileAccess.WRITE)
	if output == null:
		return "Cannot write the game's media folder: " + temporary.get_base_dir()
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	var copied := 0
	while copied < size:
		var bytes := input.get_buffer(mini(CHUNK_SIZE, size - copied))
		if bytes.is_empty():
			why = "The selected image could not be read completely."
			break
		output.store_buffer(bytes)
		if output.get_error() != OK:
			why = "The image could not be copied. Check free disk space and folder permissions."
			break
		hash.update(bytes)
		copied += bytes.size()
		if progress.is_valid():
			progress.call("Copying CD image", copied, size)
		if tree != null:
			await tree.process_frame
	input.close()
	output.flush()
	if output.get_error() != OK:
		why = "The image could not be saved. Check free disk space and folder permissions."
	output.close()
	var expected := hash.finish()
	if why.is_empty():
		var verification: Dictionary = await _digest(temporary, tree, progress)
		if verification.size != size or verification.digest != expected:
			why = "The copied image is incomplete or damaged. Please try again."
	if not why.is_empty(): DirAccess.remove_absolute(temporary)
	return why


static func _digest(path: String, tree: SceneTree, progress: Callable) -> Dictionary:
	var input := FileAccess.open(path, FileAccess.READ)
	if input == null:
		return {"size": -1, "digest": PackedByteArray()}
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	var size := input.get_length()
	var done := 0
	while done < size:
		var bytes := input.get_buffer(mini(CHUNK_SIZE, size - done))
		if bytes.is_empty():
			break
		hash.update(bytes)
		done += bytes.size()
		if progress.is_valid():
			progress.call("Checking copied image", done, size)
		if tree != null:
			await tree.process_frame
	input.close()
	return {"size": done, "digest": hash.finish()}


static func _activate(relative: String, folder: String) -> String:
	var pointer := folder.path_join(Location.POINTER_NAME)
	var temporary := pointer + ".tmp-" + Crypto.new().generate_random_bytes(12).hex_encode()
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return "Cannot save the imported image selection."
	file.store_string(JSON.stringify({"schema": 1, "path": relative}))
	file.flush()
	var error := file.get_error()
	file.close()
	if error == OK: error = DirAccess.rename_absolute(temporary, pointer)
	if error != OK:
		DirAccess.remove_absolute(temporary)
		return "Cannot activate the imported image (%s)." % error_string(error)
	return ""


static func _take_cue(path: String, folder: String, tree: SceneTree, progress: Callable) -> String:
	if path.simplify_path() == ProjectSettings.globalize_path(Location.installed_path(folder)).simplify_path():
		return ""
	var disc: Object = ClassDB.instantiate("BloodshotDisc")
	var info: Dictionary = disc.inspect_image(path)
	if info.is_empty(): return disc.get_error()
	var id := Crypto.new().generate_random_bytes(12).hex_encode()
	var sets := folder.path_join("sets")
	var temporary := sets.path_join(".importing-" + id)
	if DirAccess.make_dir_recursive_absolute(temporary) != OK:
		return "Cannot create the game's media folder: " + folder
	var why := ""
	for index: int in range(info.image_files.size()):
		var part: Dictionary = info.image_files[index]
		var report := func(message: String, done: int, total: int) -> void:
			if progress.is_valid(): progress.call("%s (file %d/%d)" % [message, index + 1, info.image_files.size()], done, total)
		why = await _copy_verified(part.path, temporary.path_join(part.installed_name), tree, report)
		if not why.is_empty(): break
	var cue := temporary.path_join("disc.cue")
	if why.is_empty():
		var file := FileAccess.open(cue, FileAccess.WRITE)
		if file == null:
			why = "Cannot save the imported CUE."
		else:
			file.store_string(info.cue_text)
			file.flush()
			if file.get_error() != OK: why = "Cannot save the imported CUE."
			file.close()
	if why.is_empty(): why = validate(cue)
	var relative := "sets/cue-" + id + "/disc.cue"
	var installed := folder.path_join(relative).get_base_dir()
	if why.is_empty() and DirAccess.rename_absolute(temporary, installed) != OK:
		why = "Cannot install the copied CUE/BIN image set."
	if why.is_empty(): why = _activate(relative, folder)
	# All names below belong to this operation's random staging/install folder.
	if not why.is_empty():
		for directory: String in [temporary, installed]:
			if not DirAccess.dir_exists_absolute(directory): continue
			for name: String in DirAccess.get_files_at(directory):
				DirAccess.remove_absolute(directory.path_join(name))
			DirAccess.remove_absolute(directory)
	return why
