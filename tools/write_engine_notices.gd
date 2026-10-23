extends SceneTree


## Export metadata from the exact local engine; no game/media resources required.
func _initialize() -> void:
	var target := OS.get_cmdline_user_args()[0]
	var text := Engine.get_license_text() + "\n\nGodot component copyrights\n"
	text += JSON.stringify(Engine.get_copyright_info(), "\t") + "\n\nComponent licenses\n"
	var licenses: Dictionary = Engine.get_license_info()
	for name: String in licenses:
		text += "\n" + name + "\n" + str(licenses[name]) + "\n"
	var output := FileAccess.open(target, FileAccess.WRITE)
	assert(output != null)
	output.store_string(text)
	output.close()
	quit()
