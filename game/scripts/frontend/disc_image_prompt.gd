extends Node
## Bootstrap UI precedes access to original fonts/artwork. Ask through the OS,
## with a separate desktop-sized Godot window on systems lacking a native picker.
signal chosen(path: String)
const Import = preload("res://scripts/assets/disc_import.gd")
const Location = preload("res://scripts/assets/disc_location.gd")
const TITLE := "Bloodshot / Battle Frenzy"
var _progress: AcceptDialog


static func file_dialog(folder: String) -> FileDialog:
	var dialog := FileDialog.new()
	dialog.use_native_dialog = true
	dialog.force_native = true
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.title = "Select your European Mega CD Bloodshot / Battle Frenzy CHD or CUE"
	dialog.filters = PackedStringArray(["*.chd, *.cue ; CD images (CHD or CUE)"])
	dialog.current_dir = folder
	return dialog


func acquire() -> String:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var dialog := file_dialog(OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS))
	add_child(dialog)
	dialog.file_selected.connect(func(path: String) -> void: chosen.emit(path))
	dialog.canceled.connect(func() -> void: chosen.emit(""))
	while true:
		dialog.popup_centered(Vector2i(900, 600))
		var path: String = await chosen
		if path.is_empty():
			return ""
		_progress = AcceptDialog.new()
		_progress.title = TITLE
		_progress.force_native = true
		_progress.dialog_close_on_escape = false
		_progress.get_ok_button().hide()
		_progress.dialog_text = "Checking selected CD image..."
		add_child(_progress)
		_progress.popup_centered(Vector2i(520, 140))
		await get_tree().process_frame
		var why := await Import.take_disc(path,
			ProjectSettings.globalize_path(Location.COPY_PATH).get_base_dir(),
			get_tree(), _show_progress)
		_progress.queue_free()
		_progress = null
		if why.is_empty():
			return ProjectSettings.globalize_path(Location.installed_path())
		OS.alert(why + "\n\nChoose your original European Mega CD CHD or CUE to try again.", TITLE)

	return ""


func _show_progress(message: String, done: int, total: int) -> void:
	_progress.dialog_text = "%s... %d%%\n\nThis copy will be used on future launches." % [
		message, int(100.0 * done / maxi(1, total))]
