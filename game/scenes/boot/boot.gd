extends Node
## Separate composition root. Only runtime services belong here; each mode owns
## its own scene. The regular launch enters the runtime-decoded European CD title.


func _enter_tree() -> void:
	# Apply saved window/audio preferences before startup mounts media or draws
	# its loading frame. Later scene initialization remains safe and idempotent.
	if (
		OS.has_feature("dedicated_server")
		or "--dedicated" in OS.get_cmdline_user_args()
		or "--probe-client" in OS.get_cmdline_user_args()
	):
		return
	preload("res://scripts/presentation/cd_display_settings.gd").initialize_window(get_window())
	preload("res://scripts/audio/cd_audio_settings.gd").set_source_mode(
		int(preload("res://scripts/frontend/cd_frontend_settings.gd").values().sound)
	)


func _ready() -> void:
	preload("res://scripts/runtime/cd_application_lifecycle.gd").install(get_tree())
	if "--asset-cache-probe" in OS.get_cmdline_user_args():
		get_tree().root.add_child.call_deferred(
			load("res://scripts/diagnostics/asset_cache_probe.gd").new()
		)
		return
	if (
		OS.has_feature("dedicated_server")
		or "--dedicated" in OS.get_cmdline_user_args()
		or "--probe-client" in OS.get_cmdline_user_args()
	):
		get_tree().change_scene_to_file.call_deferred(
			"res://scenes/dedicated_server/dedicated_server.tscn"
		)
		return
	if "--network" in OS.get_cmdline_user_args():
		get_tree().set_meta("startup_destination", "res://scenes/network_gameplay/network_gameplay.tscn")
		get_tree().change_scene_to_file.call_deferred("res://scenes/startup/startup.tscn")
		return
	if "--runtime-audit" in OS.get_cmdline_user_args():
		var audit_path := "res://scripts/diagnostics/runtime_audit.gd"
		if "--audit-bots" in OS.get_cmdline_user_args():
			audit_path = "res://scripts/diagnostics/multiplayer_bot_audit.gd"
		var audit: Node = load(audit_path).new()
		get_tree().root.add_child.call_deferred(audit)
		return
	if "--audio-self-test" in OS.get_cmdline_user_args():
		get_tree().change_scene_to_file.call_deferred(
			"res://scenes/diagnostics/audio_diagnostics.tscn"
		)
		return
	get_tree().change_scene_to_file.call_deferred("res://scenes/startup/startup.tscn")
