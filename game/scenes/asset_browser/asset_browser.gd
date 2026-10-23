@tool
extends VBoxContainer
## The same inspection scene runs in the editor dock and as a standalone mode.
## Raw diagnostic previews require explicit layout/offset; they are not verified
## game assets. Verified CD wall/actor catalogs use the runtime source/cache API.

const Source = preload("res://scripts/assets/original_asset_source.gd")

var _source := Source.new()
var _selected: String = ""
var _level: Resource
var _actors: Resource
var _audio_window: Window
var _ui: RefCounted
var _frontend: RefCounted
var _static_preview := false
var _static_time := 0.0

@onready var _status: Label = $Status
@onready var _files: ItemList = $Files
@onready var _bytes: TextEdit = $Bytes
@onready var _preview: TextureRect = $Preview


func _ready() -> void:
	$Reload.pressed.connect(_reload)
	$Decode.pressed.connect(_decode)
	$LoadWalls.pressed.connect(_load_walls)
	$LoadActors.pressed.connect(_load_actors)
	$LoadAudio.pressed.connect(_load_audio)
	$LoadUi.pressed.connect(_load_ui)
	$LoadFrontend.pressed.connect(_load_frontend)
	$FrontendGraphics.item_selected.connect(_select_frontend)
	$UiGraphics.item_selected.connect(_select_ui)
	for number: int in range(1, 17):
		$Level.add_item("LEVEL %d" % number, number)
	$Level.item_selected.connect(_change_level)
	$ActorFrames.item_selected.connect(_select_actor)
	$WallTextures.item_selected.connect(_select_wall)
	_files.item_selected.connect(_select)
	_reload.call_deferred()


func _reload() -> void:
	_static_preview = false
	_files.clear()
	_preview.texture = null
	_bytes.text = ""
	_selected = ""
	_level = null
	_actors = null
	_ui = null
	_frontend = null
	$ActorFrames.clear()
	$WallTextures.clear()
	$UiGraphics.clear()
	$FrontendGraphics.clear()
	if not _source.mount(Source.configured_disc_path()):
		_status.text = _source.last_error
		return
	var files: Array = _source.catalog.get("files", [])
	_status.text = "%d original CD files • decoded data stays in memory" % files.size()
	for entry: Dictionary in files:
		var index: int = _files.add_item("%s  (%d bytes)" % [entry["path"], entry["size"]])
		_files.set_item_metadata(index, entry)
	if not files.is_empty():
		_files.select(0)
		_select(0)


func _select(index: int) -> void:
	_static_preview = false
	var entry: Dictionary = _files.get_item_metadata(index)
	_selected = entry["path"]
	_preview.texture = null
	var header := _source.read_range(_selected, 0, mini(int(entry["size"]), 64))
	_bytes.text = (
		"LBA %d\nHeader (hex):\n%s\n\nGraphics layout and palette: not yet identified."
		% [entry["lba"], header.hex_encode()]
	)
	if not _source.last_error.is_empty():
		_status.text = _source.last_error


func _decode() -> void:
	_static_preview = false
	if _selected.is_empty():
		return
	var palette := PackedColorArray()
	for i: int in range(16):
		palette.append(Color(float(i) / 15.0, float(i) / 15.0, float(i) / 15.0, 1.0))
	var size := Vector2i(int($Layout/Width.value), int($Layout/Height.value))
	_preview.texture = _source.texture_from_linear_4bpp(
		_selected, int($Offset.value), size, palette
	)
	_status.text = (
		_source.last_error
		if not _source.last_error.is_empty()
		else "Diagnostic 4bpp span • grayscale palette • unverified game layout"
	)


func _load_walls() -> void:
	_static_preview = false
	$WallTextures.clear()
	_level = _source.load_cd_level(_level_path())
	if _level == null:
		_status.text = _source.last_error
		return
	var seen: Dictionary = {}
	for i: int in range(_level.walls.size()):
		var wall: Dictionary = _level.walls[i]
		var key := "%x:%d:%s" % [wall.texture_offset, wall.texture_width, str(wall.mirror)]
		if seen.has(key):
			continue
		seen[key] = true
		$WallTextures.add_item(
			(
				"%05X • %d px%s"
				% [wall.texture_offset, wall.texture_width, " mirrored" if wall.mirror else ""]
			)
		)
		$WallTextures.set_item_metadata($WallTextures.item_count - 1, i)
	if $WallTextures.item_count > 0:
		$WallTextures.select(0)
		_select_wall(0)


func _select_wall(index: int) -> void:
	_static_preview = false
	var wall_index: int = $WallTextures.get_item_metadata(index)
	_preview.texture = _source.texture_from_cd_wall(_level, wall_index)
	_status.text = (
		"%s wall • reflected lower half uses the second source palette • cached in memory"
		% _level.source_path
	)


func _load_actors() -> void:
	_static_preview = false
	$ActorFrames.clear()
	_level = _source.load_cd_level(_level_path())
	_actors = _source.load_cd_actor_catalog(_level)
	if _actors == null:
		_status.text = _source.last_error
		return
	var kinds: Dictionary = {}
	for actor: Dictionary in _actors.actors:
		var address := int(actor.frame)
		if not kinds.has(address):
			kinds[address] = []
		if not kinds[address].has(int(actor.kind)):
			kinds[address].append(int(actor.kind))
	for address: int in _actors.frames:
		var frame: Dictionary = _actors.frames[address]
		if int(frame.offset) == 0:
			continue
		var category := "animation / effect"
		if kinds.has(address):
			category = "actor kinds " + str(kinds[address])
		$ActorFrames.add_item("%05X · %d×%d · %s" % [address, frame.width, frame.height, category])
		$ActorFrames.set_item_metadata($ActorFrames.item_count - 1, address)
	if $ActorFrames.item_count > 0:
		$ActorFrames.select(0)
		_select_actor(0)


func _select_actor(index: int) -> void:
	_static_preview = false
	var address: int = $ActorFrames.get_item_metadata(index)
	_preview.texture = _source.texture_from_cd_actor(_level, _actors, address)
	_status.text = (
		"CD actor frame %05X · original palette · transparent index zero · memory cache" % address
	)


func _load_audio() -> void:
	if not is_instance_valid(_audio_window):
		_audio_window = preload("res://scenes/asset_browser/audio_inspector.tscn").instantiate()
		add_child(_audio_window)
	if _audio_window.configure(_source):
		_audio_window.popup_centered()


func _exit_tree() -> void:
	if is_instance_valid(_audio_window):
		_audio_window.queue_free()


func _level_path() -> String:
	return "/LEVEL%d.LEV" % maxi($Level.get_selected_id(), 1)


func _change_level(_index: int) -> void:
	_static_preview = false
	# Old list entries address their own source file. Discard them together so
	# selecting another catalog cannot accidentally decode against a new level.
	_level = null
	_actors = null
	_ui = null
	$WallTextures.clear()
	$ActorFrames.clear()
	$UiGraphics.clear()
	_preview.texture = null
	_status.text = "%s selected · load a graphics catalog to preview" % _level_path()


func _load_frontend() -> void:
	_frontend = _source.load_cd_frontend_catalog()
	$FrontendGraphics.clear()
	if _frontend == null:
		_status.text = _source.last_error
		return
	$FrontendGraphics.add_item("European CD title composite")
	for index: int in range(15):
		$FrontendGraphics.add_item("Original CD slide %02d" % index)
	for label: String in [
		"Level-clear card", "Final-level completion card", "Final power rating card"
	]:
		$FrontendGraphics.add_item(label)
	$FrontendGraphics.add_item("High-score heading and font")
	$FrontendGraphics.add_item("Original localized pause overlay")
	$FrontendGraphics.select(0)
	_select_frontend(0)


func _select_frontend(index: int) -> void:
	if _frontend == null:
		return
	_static_preview = false
	if index == 20:
		_preview.texture = _frontend.pause_preview(
			int(preload("res://scripts/frontend/cd_frontend_settings.gd").values().language)
		)
	elif index == 19:
		_preview.texture = _frontend.score_preview()
	elif index >= 16:
		_preview.texture = _frontend.campaign_preview(
			index - 16,
			int(preload("res://scripts/frontend/cd_frontend_settings.gd").values().language)
		)
	else:
		_preview.texture = _frontend.title() if index == 0 else _frontend.slide(index - 1)
	_status.text = "Runtime original CD frontend artwork · 7:6 source pixels"


func _load_ui() -> void:
	_static_preview = false
	$UiGraphics.clear()
	_level = _source.load_cd_level(_level_path())
	_ui = _source.load_cd_ui(_level)
	if _ui == null:
		_status.text = _source.last_error
		return
	for entry: Dictionary in [
		{"kind": "frame", "id": 0, "label": "Original gameplay HUD frame"},
		{"kind": "map", "id": 0, "label": "Original level minimap at spawn"}
	]:
		$UiGraphics.add_item(entry.label)
		$UiGraphics.set_item_metadata($UiGraphics.item_count - 1, entry)
	for icon: int in range(38):
		$UiGraphics.add_item("Pickup static (animated)" if icon == 33 else "HUD icon %d" % icon)
		$UiGraphics.set_item_metadata($UiGraphics.item_count - 1, {"kind": "icon", "id": icon})
	for code: int in _ui.glyphs:
		$UiGraphics.add_item("Original font · " + String.chr(code))
		$UiGraphics.set_item_metadata($UiGraphics.item_count - 1, {"kind": "glyph", "id": code})
	for sight: int in range(12):
		$UiGraphics.add_item("Weapon lock-on sight" if sight == 11 else "Weapon sight %d" % sight)
		$UiGraphics.set_item_metadata($UiGraphics.item_count - 1, {"kind": "sight", "id": sight})
	for weapon: int in range(10):
		for phase: int in range(8):
			$UiGraphics.add_item("Weapon %d notice · phase %d" % [weapon + 1, phase])
			$UiGraphics.set_item_metadata(
				$UiGraphics.item_count - 1, {"kind": "panel", "weapon": weapon, "phase": phase}
			)
	for source_id: int in _ui.STATUS_SPANS:
		for language: int in [69, 70, 68, 83]:
			$UiGraphics.add_item(
				"Original status text · %05X · %s" % [source_id, String.chr(language)]
			)
			$UiGraphics.set_item_metadata(
				$UiGraphics.item_count - 1,
				{"kind": "message", "id": source_id, "language": language}
			)
	$UiGraphics.select(0)
	_select_ui(0)


func _select_ui(index: int) -> void:
	_static_preview = false
	var entry: Dictionary = $UiGraphics.get_item_metadata(index)
	if entry.kind == "frame":
		_preview.texture = _ui.frame()
	elif entry.kind == "map":
		_preview.texture = ImageTexture.create_from_image(
			_ui.minimap_image(_level, _level.spawn, (int(_level.spawn_angle) & 255) << 6)
		)
	elif entry.kind == "icon":
		_static_preview = int(entry.id) == 33
		_static_time = 0.0
		_preview.texture = (
			_ui.pickup_static(_static_time) if _static_preview else _ui.icon(int(entry.id))
		)
	elif entry.kind == "sight":
		_preview.texture = _ui.weapon_sight(int(entry.id))
	elif entry.kind == "panel":
		_preview.texture = _ui.weapon_panel(int(entry.weapon), int(entry.phase))
	elif entry.kind == "message":
		_preview.texture = _ui.message_texture(int(entry.id), int(entry.language))
	else:
		_preview.texture = _ui.character(int(entry.id))
	_status.text = "%s · original CD UI/map artwork · runtime memory cache" % _level.source_path


func _process(delta: float) -> void:
	if _static_preview and _ui != null and is_visible_in_tree():
		_static_time += delta * 53203424.0 / (313.0 * 3420.0)
		_preview.texture = _ui.pickup_static(_static_time)
