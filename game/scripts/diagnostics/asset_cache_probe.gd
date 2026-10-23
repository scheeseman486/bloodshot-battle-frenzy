extends Node
## Independent-process cache measurement; only scalar digests enter reports.
const Source = preload("res://scripts/assets/original_asset_source.gd")
const Cache = preload("res://scripts/assets/cd_asset_cache.gd")


func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func(): get_tree().quit(1))
	_run.call_deferred()


func _run() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.has("--asset-cache-probe"):
		arguments.remove_at(arguments.find("--asset-cache-probe"))
	if arguments.size() != 2:
		push_error("Usage: asset_cache_probe.gd -- cache-directory report.json")
		get_tree().quit(1)
		return
	var source = Source.new()
	source.cache_directory = arguments[0]
	var started := Time.get_ticks_usec()
	if (
		not source.mount(Source.configured_disc_path())
		or not await source.prepare_asset_cache(_progress)
	):
		push_error(source.last_error)
		get_tree().quit(1)
		return
	# Keep GPU uploads in the measured startup, and inventory readback outside it.
	if DisplayServer.get_name() == "headless":
		await get_tree().process_frame
		await get_tree().process_frame
	else:
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
	var elapsed := Time.get_ticks_usec() - started
	print("ASSETS_PREPARED_USEC ", elapsed)
	var report := source.cache_info()
	report.total_startup_usec = elapsed
	report.user_directory = OS.get_user_data_dir()
	report.static_memory_bytes = OS.get_static_memory_usage()
	report.rendering_method = RenderingServer.get_current_rendering_method()
	report.inventory = inventory(source)
	var file := FileAccess.open(arguments[1], FileAccess.WRITE)
	if file == null or report.inventory.is_empty():
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print(JSON.stringify(report))
	get_tree().quit()


func _progress(message: String, done: int, total: int) -> void:
	print("ASSET_PROGRESS ", done, "/", total, " ", message)


## Hash every hydrated asset, not just the file container: wall/sprite/UI/font
## pixels, PCM sample formats/data, all source bytes and catalog metadata.
static func inventory(source: RefCounted) -> Dictionary:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	var counts := {"textures": 0, "images": 0, "pcm_streams": 0, "catalogs": 0}
	if not _feed(hash, source.cache_groups(), counts, {}):
		return {}
	counts.sha256 = hash.finish().hex_encode()
	return counts


static func _feed(
	hash: HashingContext, value: Variant, counts: Dictionary, readback: Dictionary
) -> bool:
	if value is Dictionary:
		hash.update("dictionary".to_utf8_buffer())
		var keys: Array = value.keys()
		keys.sort_custom(
			func(a, b): return var_to_bytes(a).hex_encode() < var_to_bytes(b).hex_encode()
		)
		for key: Variant in keys:
			if (
				not _feed(hash, key, counts, readback)
				or not _feed(hash, value[key], counts, readback)
			):
				return false
	elif value is Array:
		hash.update(var_to_bytes(["array", value.size()]))
		for child: Variant in value:
			if not _feed(hash, child, counts, readback):
				return false
	elif value is ImageTexture:
		counts.textures += 1
		var id: int = value.get_instance_id()
		if not readback.has(id):
			readback[id] = value.get_image()
		return _feed(hash, readback[id], counts, readback)
	elif value is Image:
		counts.images += 1
		hash.update(
			var_to_bytes(
				[value.get_width(), value.get_height(), value.get_format(), value.has_mipmaps()]
			)
		)
		hash.update(value.get_data())
	elif value is AudioStreamWAV:
		counts.pcm_streams += 1
		for field: String in [
			"format", "mix_rate", "stereo", "loop_mode", "loop_begin", "loop_end", "data"
		]:
			if not _feed(hash, value.get(field), counts, readback):
				return false
	elif value is Object:
		var path: String = value.get_script().resource_path if value.get_script() != null else ""
		if not Cache.SCRIPTS.has(path):
			push_error("Unreviewed inventory object: " + value.get_class())
			return false
		counts.catalogs += 1
		hash.update(path.to_utf8_buffer())
		return _feed(hash, Cache._stored_fields(value, path), counts, readback)
	else:
		hash.update(var_to_bytes(value))
	return true
