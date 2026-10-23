extends Control
## Developer-only navigation reached with F12; original frontend flow is separate.

const AudioSettings = preload("res://scripts/audio/cd_audio_settings.gd")


func _ready() -> void:
	for number: int in range(1, 17):
		$Center/Content/Level.add_item("LEVEL %d" % number, number)
	$Center/Content/Level.select(clampi(int(get_tree().get_meta("campaign_level", 1)) - 1, 0, 15))
	for bus: String in ["Effects", "Music"]:
		var slider: HSlider = get_node("Center/Content/AudioOptions/" + bus)
		slider.value = AudioSettings.volume(bus) * 100.0
		slider.value_changed.connect(_volume_changed.bind(bus))
	$Center/Content/Assets.pressed.connect(
		func() -> void:
			get_tree().change_scene_to_file("res://scenes/asset_browser/asset_browser.tscn")
	)
	$Center/Content/Rendering.pressed.connect(
		func() -> void: get_tree().change_scene_to_file("res://scenes/gameplay/gameplay.tscn")
	)
	$Center/Content/Campaign.pressed.connect(
		func() -> void:
			get_tree().set_meta("campaign_level", $Center/Content/Level.get_selected_id())
			get_tree().set_meta("campaign_score_eligible", false)
			get_tree().change_scene_to_file("res://scenes/campaign/campaign.tscn")
	)
	$Center/Content/Quit.pressed.connect(
		func() -> void:
			preload("res://scripts/runtime/cd_application_lifecycle.gd").request_quit(get_tree())
	)


func _volume_changed(value: float, bus: String) -> void:
	AudioSettings.set_volume(bus, value / 100.0)
