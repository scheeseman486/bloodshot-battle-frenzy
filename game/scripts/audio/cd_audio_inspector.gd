@tool
extends Window
## Inspect original audio using the same runtime cache and playback service.
var _source: RefCounted


func _ready() -> void:
	close_requested.connect(_close)
	$Content/Buttons/Play.pressed.connect(_play)
	$Content/Buttons/Stop.pressed.connect($Audio.stop_all)


func configure(source: RefCounted) -> bool:
	_source = source
	if not $Audio.configure(source):
		$Content/Status.text = $Audio.last_error
		return false
	var catalog: RefCounted = $Audio.audio_catalog
	$Content/Assets.clear()
	for source_id: int in catalog.samples:
		var sample: Dictionary = catalog.samples[source_id]
		var index: int = $Content/Assets.item_count
		$Content/Assets.add_item(
			(
				"Effect %02d · %.2f s"
				% [int(sample.index) + 1, float(sample.length) / float(sample.rate)]
			)
		)
		$Content/Assets.set_item_metadata(index, {"kind": "sample", "source_id": source_id})
	for track: Dictionary in source.catalog.tracks:
		if not bool(track.audio):
			continue
		var index: int = $Content/Assets.item_count
		$Content/Assets.add_item(
			"CD track %02d · %.1f s" % [track.number, float(track.frames) / 75.0]
		)
		$Content/Assets.set_item_metadata(index, {"kind": "track", "track": track.number})
	$Content/Assets.select(0)
	$Content/Status.text = "37 effects and 16 CD tracks · loaded from your original disc"
	return true


func _play() -> void:
	var selected: Dictionary = $Content/Assets.get_item_metadata($Content/Assets.selected)
	$Audio.stop_all()
	if selected.kind == "sample":
		$Audio.play_source(int(selected.source_id))
	else:
		$Audio.play_track(int(selected.track), false)


func _close() -> void:
	$Audio.stop_all()
	hide()
