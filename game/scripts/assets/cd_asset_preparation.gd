extends RefCounted
## Finite original asset inventory. Runs before intro/simulation clocks, yielding
## between batches for loading feedback. CD-DA bytes are never requested here.
const Cache = preload("res://scripts/assets/cd_asset_cache.gd")
const LevelDecoder = preload("res://scripts/assets/cd_level_decoder.gd")
const Actors = preload("res://scripts/assets/cd_actor_catalog.gd")
const Palette = preload("res://scripts/assets/cd_palette_data.gd")
const Ui = preload("res://scripts/assets/cd_ui_catalog.gd")
const MANIFEST := "res://resources/assets/cd_data_file_hashes.json"
var _progress: Callable
var _counts: Dictionary = {}


func prepare(source: RefCounted, progress: Callable = Callable()) -> bool:
	var started = Time.get_ticks_usec()
	_progress = progress
	_counts = {
		"source_files": 0,
		"campaign_levels": 0,
		"arena_assets": 0,
		"actor_frames": 0,
		"empty_frame_descriptors": 0,
		"wall_images": 0,
		"pcm_effects": 0,
		"cached_music_bytes": 0,
		"persisted": false,
		"warm": false,
		"prepare_usec": 0
	}
	if source.catalog.is_empty():
		source.last_error = "Mount original media before preparing assets"
		return false
	if source._asset_cache == null:
		source._asset_cache = Cache.new()
		source._asset_cache.open(
			Cache.source_identity(source.catalog, source.disc_path()),
			Cache.decoder_identity(),
			source.cache_directory
		)
	var cache = source._asset_cache
	var prepared: Dictionary = cache.prepared_inventory()
	if cache.ready() and not prepared.is_empty():
		# Returning from an attract demo/game-over is another startup scene, not
		# another application launch. The complete immutable inventory is already
		# resident; new consumers hydrate only their own private catalog wrappers.
		prepared.warm = true
		prepared.memory_ready = true
		prepared.prepare_usec = Time.get_ticks_usec() - started
		source._preparation_info = prepared
		source.last_error = ""
		await _report("Game data ready", 20, 20)
		return true
	var warm = cache.ready()
	_counts.warm = warm
	if warm and not cache.warm_graphics():
		cache.discard()
		warm = false
		_counts.warm = false
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not manifest is Dictionary or manifest.get("chd_sha1") != source.CHD_SHA1 or not source.supported_media():
		source.last_error = "Unsupported source identity for asset preparation"
		return false
	await _report("Reading game data", 0, 20)
	for path: String in manifest.files:
		var bytes: PackedByteArray = source.read_range(path)
		if (
			bytes.size() != int(manifest.files[path].size)
			or Cache._sha(bytes) != manifest.files[path].sha256
		):
			source.last_error = "Original source hash mismatch: " + path
			return false
		_counts.source_files += 1
	if source.load_cd_behaviour_tables() == null:
		return false
	var frontend = source.load_cd_frontend_catalog()
	if frontend == null:
		return false
	if not _frontend(frontend):
		source.last_error = "Could not prepare frontend graphics"
		return false
	var font = source.load_cd_small_font()
	if font == null:
		return false
	for code: int in font.available_codes():
		if font.glyph(code) == null:
			source.last_error = "Could not prepare font glyph"
			return false
	font.native_font()
	var audio = source.load_cd_audio_catalog()
	if audio == null:
		return false
	for id: int in audio.samples:
		if audio.stream(id) == null:
			source.last_error = "Could not prepare PCM effect"
			return false
		_counts.pcm_effects += 1
	for index: int in range(1, 17):
		var level = source.load_cd_level("/LEVEL%d.LEV" % index)
		if level == null:
			return false
		var actors = source.load_cd_actor_catalog(level)
		var ui = source.load_cd_ui(level)
		if actors == null or ui == null:
			return false
		if not _level(source, level, actors, ui):
			return false
		_counts.campaign_levels += 1
		await _report("Preparing level %d of 16" % index, index, 20)
	# Cache the three arenas alongside campaign assets. The separate battle
	# loader verifies their hashes; campaign admission remains sixteen levels.
	for index: int in range(1, 4):
		var path = "/ARENA%d.LEV" % index
		var level = source._level_cache.get(path)
		if level == null:
			level = source._cached_asset("levels", path)
		if level != null:
			source._level_cache[path] = level
		var actors: Resource
		var ui: RefCounted
		if level == null:
			level = LevelDecoder.decode(source.read_range(path))
			if level == null:
				source.last_error = "Unsupported arena asset layout"
				return false
			level.source_path = path
			level.source_sha256 = manifest.files[path].sha256
			actors = Actors.new()
			if not actors.decode(source.read_range("/SHELL.BIN"), level):
				source.last_error = actors.last_error
				return false
			actors.source_sha256 = source.SHELL_SHA256
			var palette = Palette.new()
			if not palette.decode(level, source.read_range("/SHELL.BIN")):
				source.last_error = "Invalid arena palette"
				return false
			ui = Ui.new()
			if not ui.decode(
				source.read_range("/MAINOS.BIN"), source.read_range("/SHELL.BIN"), palette.banks[0]
			):
				source.last_error = ui.last_error
				return false
			source._level_cache[path] = level
			source._actor_cache[level.source_sha256] = actors
			source._palette_cache[level.source_sha256] = palette
			source._ui_cache[level.source_sha256] = ui
		else:
			source._palette_cache[level.source_sha256] = source._cached_asset(
				"palettes", level.source_sha256
			)
			actors = source._actor_cache.get(level.source_sha256)
			if actors == null:
				actors = source._cached_asset("actors", level.source_sha256)
				source._actor_cache[level.source_sha256] = actors
			ui = source._ui_cache.get(level.source_sha256)
			if ui == null:
				ui = source._cached_asset("ui", level.source_sha256)
				source._ui_cache[level.source_sha256] = ui
		if actors == null or ui == null or not _level(source, level, actors, ui):
			return false
		_counts.arena_assets += 1
		await _report("Preparing arena artwork", 16 + index, 20)
	if not cache.last_error.is_empty():
		warm = false
		_counts.warm = false
	if not warm:
		await _report("Saving prepared assets", 19, 20)
		if not cache.capture(source.cache_groups()):
			source.last_error = cache.last_error
			return false
		_counts.persisted = cache.save()
		# A full user folder must not prevent play. The prepared RAM cache remains
		# usable for this process; diagnostics retain the actual storage failure.
		if not _counts.persisted:
			_counts.storage_error = cache.last_error
	else:
		_counts.persisted = true
	_counts.prepare_usec = Time.get_ticks_usec() - started
	source._preparation_info = _counts.duplicate(true)
	cache.retain_runtime_views(source.cache_groups())
	cache.mark_prepared(_counts)
	source.last_error = ""
	await _report("Game data ready", 20, 20)
	return true


func _level(source: RefCounted, level: Resource, actors: Resource, ui: RefCounted) -> bool:
	for index: int in range(level.walls.size()):
		if (
			source.texture_from_cd_wall(level, index) == null
			or source.index_texture_from_cd_wall(level, index) == null
		):
			source.last_error = "Could not prepare wall artwork"
			return false
	_counts.wall_images += level.walls.size()
	for address: int in actors.frames:
		if int(actors.frames[address].offset) == 0:
			_counts.empty_frame_descriptors += 1
			continue  # A zero source pointer explicitly means absent artwork in this map.
		if (
			source.texture_from_cd_actor(level, actors, address) == null
			or source.index_texture_from_cd_actor(level, actors, address) == null
		):
			source.last_error = (
				"Could not prepare actor frame %x in %s" % [address, level.source_path]
			)
			return false
		_counts.actor_frames += 1
	if not _ui(ui):
		source.last_error = "Could not prepare HUD graphics"
		return false
	for indexed: bool in [false, true]:
		for heading: int in range(8):
			ui._minimap_background(level, heading, indexed)
	return true


func _frontend(frontend: RefCounted) -> bool:
	for index: int in range(frontend.descriptors.size()):
		if frontend.slide(index) == null or frontend.slide(index, true) == null:
			return false
	if frontend.title() == null or frontend.noise_tiles() == null or frontend.noise_seeds() == null:
		return false
	if not _ui(frontend.ui):
		return false
	for index: int in range(3):
		if frontend.demo(index).is_empty():
			return false
	for language: int in [69, 70, 68, 83]:
		frontend.credit_pages(language)
		frontend.pause_layout(language)
		for name: String in frontend.menus:
			for item: Dictionary in frontend.menus[name].items:
				frontend.text_bytes(item.text, language)
	return true


func _ui(ui: RefCounted) -> bool:
	for indexed: bool in [false, true]:
		if ui.frame(indexed) == null:
			return false
		if ui.multiplayer_weapon_frame(indexed) == null:
			return false
		if ui.classic_versus_weapon_frame(indexed) == null:
			return false
		for icon: int in range(38):
			if ui.icon(icon, indexed) == null:
				return false
		for frame: int in range(12):
			if ui.weapon_sight(frame, indexed) == null:
				return false
		for weapon: int in range(10):
			for phase: int in range(8):
				if ui.weapon_panel(weapon, phase, indexed) == null:
					return false
		for code: int in ui.glyphs:
			if ui.character(code, indexed) == null:
				return false
		for tile: int in range(160, 202):
			if ui.meter_tile(tile, indexed) == null:
				return false
		for tile: int in range(200, 230):
			for flip: bool in [false, true]:
				if ui.meter_tile(tile, indexed, flip) == null:
					return false
		for tile: int in range(229, 233):
			for flip_x: bool in [false, true]:
				for flip_y: bool in [false, true]:
					if ui.meter_tile(tile, indexed, flip_x, flip_y) == null:
						return false
		for address: int in Ui.STATUS_SPANS:
			for language: int in [69, 70, 68, 83]:
				# Empty untranslated text is an original table property, not an asset miss.
				if (
					not ui.message_layout(address, language).is_empty()
					and ui.message_texture(address, language, indexed) == null
				):
					return false
	return ui.player_flash_tile() != null


func _report(message: String, done: int, total: int) -> void:
	if _progress.is_valid():
		_progress.call(message, done, total)
	var tree = Engine.get_main_loop()
	if tree is SceneTree:
		await tree.process_frame
