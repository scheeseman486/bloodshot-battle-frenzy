extends Control
## Original gameplay artwork and map, composed as native 2D drawing. The source
## HUD canvas keeps its measured pixel aspect; the camera renders square pixels.
signal layout_changed
const Layout = preload("res://scripts/presentation/cd_hud_layout.gd")
const Data = preload("res://scripts/assets/cd_level_decoder.gd")
const UiCatalog = preload("res://scripts/assets/cd_ui_catalog.gd")
const Model = preload("res://scripts/presentation/cd_hud_model.gd")
const Progression = preload("res://scripts/simulation/cd_level_progression.gd")
const HealthDisplay = preload("res://scripts/simulation/cd_health_display.gd")
const StatusOverlay = preload("res://scripts/simulation/cd_status_overlay.gd")
const Colours = preload("res://scripts/presentation/player_colours.gd")
const VsPanel = preload("res://scripts/presentation/vs_hud_panel.gd")
const STANDARD_WEAPON_POSITIONS: Array[Vector2] = [
	Vector2(72,8), Vector2(72,24), Vector2(72,40),
	Vector2(88,8), Vector2(88,24), Vector2(88,40),
	Vector2(104,8), Vector2(104,24), Vector2(104,40)
]
@export_enum("English:69", "French:70", "German:68", "Spanish:83") var status_language: int = 69
var ui: RefCounted
var view_rect := Rect2()
var widescreen := false
var display_layout: Dictionary = {}
var _frame_regions: Dictionary = {}
var _world: Node3D
var pause_overlay := false
var _session: RefCounted
var _pose: Dictionary = {}
var _time := 0.0
var _frame_origin := Vector2.ZERO
var _frame_scale := Vector2.ONE
var _key_signatures: Array = []
var _weapon_signatures: Array = []
var _key_flash_until: Array[float] = []
var _weapon_flash_until: Array[float] = []
var _map_key := Vector3i(0x7fffffff, 0x7fffffff, 0x7fffffff)
var _map_texture: ImageTexture
var _reward_bonuses := 0
var _reward_flash_until := 0.0
var _life_count := 3
var _life_previous := 3
var _life_flash_until := 0.0
var _weapon_sight := {"visible": false}
var _player_colour := 0
var _life_skulls: Array[TextureRect] = []
var _skull_materials: Array[ShaderMaterial] = []
var _versus: Dictionary = {}
var _vs_font: RefCounted
var _vs_panel: ImageTexture
var _vs_kills := -1
var _vs_white := 0
var _vs_status := ""
var _large_message_layouts: Dictionary = {}
var _vs_phase := ""
var _vs_tick := 0


func configure(world: Node3D, session: RefCounted) -> bool:
	_world = world
	_session = session
	ui = world.source.load_cd_ui(world.level)
	_frame_regions.clear()
	if ui == null:
		return false
	ui.prepare_minimap(world.level)
	var palette_material := ShaderMaterial.new()
	palette_material.shader = preload("res://shaders/cd_palette_ui.gdshader")
	palette_material.set_shader_parameter("palette_texture", world.palette.texture)
	material = palette_material
	_configure_coloured_skulls(world.palette.texture)
	_vs_font = world.source.load_cd_small_font()
	_vs_panel = null
	_vs_kills = -1
	_vs_white = world.palette.colors.find(Color.WHITE)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not get_viewport().size_changed.is_connected(_layout):
		get_viewport().size_changed.connect(_layout)
	reset(session)
	_layout()
	return ui.frame(true) != null


func reset(session: RefCounted) -> void:
	_session = session
	_time = 0.0
	_reward_bonuses = int(session.actor_system.encounter.get("bonuses", 0))
	_reward_flash_until = 0.0
	_life_count = int(session.fighter.lives)
	_life_previous = _life_count
	_life_flash_until = 0.0
	_weapon_sight = session.weapon_sight()
	_key_signatures.clear()
	_weapon_signatures.clear()
	_key_flash_until.assign([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	_weapon_flash_until.assign([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	_map_key = Vector3i(0x7fffffff, 0x7fffffff, 0x7fffffff)


func set_widescreen(enabled: bool) -> void:
	if enabled == widescreen:
		return
	widescreen = enabled
	_layout()


func _layout() -> void:
	_large_message_layouts.clear()
	display_layout = Layout.calculate(get_viewport().get_visible_rect().size, widescreen, not _versus.is_empty())
	_frame_origin = display_layout.frame_origin
	_frame_scale = display_layout.full_scale
	view_rect = display_layout.view_rect
	queue_redraw()
	_present_coloured_skulls()
	layout_changed.emit()


func set_player_colour(colour: int) -> void:
	if clampi(colour, 0, 3) == _player_colour:
		return
	_player_colour = clampi(colour, 0, 3)
	_present_coloured_skulls()
	queue_redraw()


func _configure_coloured_skulls(palette: Texture2D) -> void:
	for skull: TextureRect in _life_skulls:
		skull.free()
	_life_skulls.clear()
	_skull_materials.clear()
	var original: Texture2D = ui.icon(4)
	var baseline: Texture2D = original
	for colour: int in range(4):
		var ink := ShaderMaterial.new()
		ink.shader = preload("res://shaders/cd_palette_ui.gdshader")
		ink.set_shader_parameter("palette_texture", palette)
		ink.set_shader_parameter("use_colour_override", colour != 0)
		ink.set_shader_parameter("colour_baseline", baseline)
		ink.set_shader_parameter("colour_override", Colours.skull_texture(original, colour))
		_skull_materials.append(ink)
	for index: int in range(4):
		var skull := TextureRect.new()
		skull.name = "PlayerSkull%d" % index
		skull.texture = ui.icon(4, true)
		skull.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		skull.mouse_filter = Control.MOUSE_FILTER_IGNORE
		skull.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		skull.hide()
		add_child(skull)
		_life_skulls.append(skull)


func _present_coloured_skulls() -> void:
	if display_layout.is_empty():
		return
	var placement := Layout.transform_for(display_layout, "lives")
	var lives := [4, 0, 0, 0] if not _versus.is_empty() else Model.life_icons(_life_count, _life_previous, _time < _life_flash_until)
	for index: int in range(_life_skulls.size()):
		var skull := _life_skulls[index]
		skull.visible = _player_colour != 0 and lives[index] == 4
		skull.material = _skull_materials[_player_colour]
		skull.position = placement.origin + Vector2(152 + index * 24, 8) * placement.scale
		skull.size = Vector2(16, 16) * placement.scale


func set_versus_player(entry: Dictionary, phase: String = "", tick: int = 0) -> void:
	var mode_changed := entry.is_empty() != _versus.is_empty()
	_versus = entry
	if mode_changed:
		_layout()
	_vs_phase = phase
	_vs_tick = tick
	if entry.is_empty():
		_vs_kills = -1
		return
	if int(entry.kills) != _vs_kills and ui != null:
		_vs_kills = int(entry.kills)
		var pixels := VsPanel.compose(ui, _vs_font, _vs_kills, _vs_white)
		if _vs_panel == null:
			_vs_panel = ImageTexture.create_from_image(pixels)
		else:
			_vs_panel.update(pixels)


func _set_group_transform(group: String) -> void:
	var placement := Layout.transform_for(display_layout, group)
	draw_set_transform(placement.origin, 0.0, placement.scale)


func displayed_health() -> int:
	return int(_session.fighter.health_copy)


func weapon_positions() -> Array[Vector2]:
	# Only the VS view changes. Source inventory records retain their nine fields,
	# and campaign/co-op retain all nine wells and their original positions.
	if _versus.is_empty():
		return STANDARD_WEAPON_POSITIONS
	return VsPanel.WIDE_WEAPON_POSITIONS if widescreen else VsPanel.WEAPON_POSITIONS


func present(session: RefCounted, pose: Dictionary, time: float) -> void:
	if ui == null:
		return
	_session = session
	_pose = pose
	_time = time
	_weapon_sight = session.weapon_sight()
	var lives := int(session.fighter.lives)
	if lives != _life_count:
		_life_previous = _life_count
		_life_count = lives
		_life_flash_until = _time + 35.0
	var bonuses := int(_versus.get("awards", session.actor_system.encounter.get("bonuses", 0)))
	if bonuses != _reward_bonuses:
		_reward_bonuses = bonuses
		_reward_flash_until = _time + 70.0
	_update_flashes(session.keys, _key_signatures, _key_flash_until, false)
	_update_flashes(session.weapon_state.inventory, _weapon_signatures, _weapon_flash_until, true)
	var bytes: PackedByteArray = _world.level.source_bytes
	var map_scale := 64 if _world.level.has_meta("native_spawns") else maxi(Data._u16(bytes, 30), 1)
	var key := Vector3i(
		int((float(pose.x) - Data._s16(bytes, 26)) / map_scale),
		int((float(pose.y) - Data._s16(bytes, 28)) / map_scale),
		posmod(int(pose.angle) + 1024, 16384) >> 11
	)
	if key != _map_key:
		_map_key = key
		var image: Image = ui.minimap_image(
			_world.level, Vector2i(int(pose.x), int(pose.y)), int(pose.angle), true
		)
		if image != null:
			if _map_texture == null:
				_map_texture = ImageTexture.create_from_image(image)
			else:
				_map_texture.update(image)
	_present_coloured_skulls()
	_vs_status = ""
	if not pause_overlay and _vs_phase == "waiting":
		_vs_status = "WAITING FOR PLAYERS"
	elif not pause_overlay and _vs_phase == "playing" and _versus.get("dead", false):
		var seconds := ceili(maxi(0, int(_versus.respawn_at) - _vs_tick) * 1070460.0 / (53203424.0 * 4.0))
		_vs_status = "RESPAWN IN %d" % seconds if seconds > 0 else "WAITING FOR SPAWN"
	queue_redraw()


func _update_flashes(
	slots: Array, signatures: Array, deadlines: Array[float], weapon: bool
) -> void:
	for index: int in range(9):
		var slot: Dictionary = slots[index]
		var signature := [int(slot.kind), int(slot.get("ammo", 0)) if weapon else 0]
		if index >= signatures.size():
			signatures.append(signature)
		elif signature != signatures[index]:
			var gained := (
				not weapon
				or int(slot.kind) != int(signatures[index][0])
				or int(slot.get("ammo", 0)) > int(signatures[index][1])
			)
			if gained and int(slot.get("extra" if weapon else "timer", 0)) > 0:
				deadlines[index] = _time + 35.0
			signatures[index] = signature


func _draw() -> void:
	if ui == null or _session == null:
		return
	if widescreen:
		# Cover the world before drawing the corner panels, so health/inventory
		# retain their source priority when the world fills the entire screen.
		if int(_session.fighter.get("flash_active", 0)) != 0:
			draw_set_transform(Vector2.ZERO, 0.0, display_layout.full_scale)
			draw_texture_rect(
				ui.player_flash_tile(),
				Rect2(Vector2.ZERO, view_rect.size / display_layout.full_scale),
				true
			)
		_draw_wide_frame()
	else:
		var viewport_size := get_viewport().get_visible_rect().size
		# Opaque native masks reserve the source UI bands and fit-frame margins.
		# Multiplication by black remains black through the palette material.
		draw_rect(Rect2(0, 0, viewport_size.x, view_rect.position.y), Color.BLACK)
		draw_rect(
			Rect2(0, view_rect.position.y, view_rect.position.x, view_rect.size.y), Color.BLACK
		)
		draw_rect(
			Rect2(
				view_rect.end.x,
				view_rect.position.y,
				viewport_size.x - view_rect.end.x,
				view_rect.size.y
			),
			Color.BLACK
		)
		draw_rect(
			Rect2(0, view_rect.end.y, viewport_size.x, viewport_size.y - view_rect.end.y),
			Color.BLACK
		)
		draw_set_transform(_frame_origin, 0.0, _frame_scale)
		draw_texture(ui.frame(true), Vector2.ZERO)
		if not _versus.is_empty():
			draw_texture(ui.classic_versus_weapon_frame(true),Vector2(64,0))
	_set_group_transform("keys")
	var selected := int(_session.weapon_state.selected)
	for index: int in range(9):
		@warning_ignore("integer_division")
		var destination := Vector2((index / 3) * 16, (index % 3) * 16)
		_set_group_transform("keys")
		var key: Dictionary = _session.keys[index]
		draw_texture(
			_notification_icon(int(key.kind), _key_flash_until[index]), Vector2(8, 8) + destination
		)
	_set_group_transform("weapons")
	var positions := weapon_positions()
	for index: int in range(positions.size()):
		var weapon: Dictionary = _session.weapon_state.inventory[index]
		var icon := int(weapon.kind)
		if icon != 0:
			icon += 10 + (11 if index == selected else 0)
		draw_texture(
			_notification_icon(icon, _weapon_flash_until[index]), positions[index]
		)
	_set_group_transform("health")
	var health := Model.health_tiles(
		displayed_health(), HealthDisplay.highlighted(_session.fighter)
	)
	for row: int in range(16):
		for column: int in range(2):
			draw_texture(
				ui.meter_tile(health[row] + column, true), Vector2(8 + column * 8, 80 + row * 8)
			)
	if widescreen:
		# Close only the meter rows; the cap overlaps the first body row.
		_frame_piece(Rect2i(0, 80, 8, 128), Vector2(23, 80), true)
	_set_group_transform("lives")
	if widescreen:
		_frame_piece(Rect2i(144, 0, 112, 62), Vector2(144, 0))
	var lives := Model.life_icons(_life_count, _life_previous, _time < _life_flash_until)
	if not _versus.is_empty() and _vs_panel != null:
		draw_texture_rect(_vs_panel, Rect2(144, 0, 112, 28), false)
		lives = [4]
	for index: int in range(lives.size()):
		if _player_colour != 0 and lives[index] == 4:
			continue  # Child canvas keeps the local cosmetic separate from other HUD icons.
		draw_texture(
			ui.pickup_static(_time, true) if lives[index] == 33 else ui.icon(lives[index], true),
			Vector2(152 + index * 24, 8)
		)
	_set_group_transform("ammo")
	var ammo := 0 if selected < 0 else int(_session.weapon_state.inventory[selected].ammo)
	var ammo_tiles := Model.ammo_tiles(ammo)
	for row: int in range(6):
		draw_texture(ui.meter_tile(ammo_tiles[row], true), Vector2(120, 8 + row * 8))
		draw_texture(ui.meter_tile(ammo_tiles[row], true, true), Vector2(128, 8 + row * 8))
	# $00BE46 uses this meter for the three-kill reward cycle. The native
	# flash uses elapsed presentation time, independent of gameplay/render FPS.
	_set_group_transform("lives")
	var bonus_flash := _time < _reward_flash_until
	var meter := Model.reward_meter_tiles(int(_session.fighter.kill_chain), bonus_flash)
	for segment: int in range(3):
		for row: int in range(2):
			for column: int in range(3):
				draw_texture(
					ui.meter_tile(
						meter[segment] + (1 if column == 1 else 0), true, column == 2, row == 1
					),
					Vector2(152 + segment * 24 + column * 8, 32 + row * 8)
				)
	var reward_index := int(_session.fighter.get("reward_index", 0))
	var reward_icon := 36 if not _versus.is_empty() else int(_session.tables.rewards[reward_index])
	draw_texture(_notification_icon(reward_icon, _reward_flash_until), Vector2(224, 32))
	if widescreen:
		_frame_piece(Rect2i(144, 1, 110, 1), Vector2(144, 61))
	_set_group_transform("map")
	if _map_texture != null:
		# The original formatter replaces this part of the world image. Index
		# zero must cover the native world beneath the map, not reveal it.
		draw_rect(Rect2(192, 64, 48, 40), Color.BLACK)
		if int(_session.fighter.map_timer) != 0:
			if int(_session.fighter.panel_weapon) >= 0:
				draw_texture(
					ui.weapon_panel(
						int(_session.fighter.panel_weapon), int(_session.fighter.panel_phase), true
					),
					Vector2(192, 64)
				)
		else:
			draw_texture(_map_texture, Vector2(192, 64))
	_set_group_transform("overlay")
	var seconds := Progression.displayed_seconds(
		_session.actor_system.encounter, int(_session.fighter.state)
	)
	if not pause_overlay and seconds >= 0 and int(_session.fighter.message_timer) == 0:
		_draw_large_message(("%02d" % seconds).to_ascii_buffer())
	_set_group_transform("message")
	if (
		not pause_overlay
		and StatusOverlay.visible(
			_session.fighter,
			int(_session.fighter.flash_active),
			int(_session.actor_system.encounter.exit_delay)
		)
	):
		var layout: Dictionary = ui.message_layout(
			int(_session.fighter.message_id), status_language
		)
		if not layout.is_empty():
			_draw_large_message(layout.bytes)
	if not widescreen and int(_session.fighter.get("flash_active", 0)) != 0:
		# Source art plus a native palette texture reproduces the committed
		# hit/death cover. The real floor, meshes and camera remain unchanged.
		draw_texture_rect(ui.player_flash_tile(), Rect2(UiCatalog.VIEW_RECT), true)
	_set_group_transform("overlay")
	if not pause_overlay and _weapon_sight.visible:
		# The source sight is a high-priority sprite over the view cover. Native
		# drawing preserves that order and the HUD's measured source pixel aspect.
		draw_texture(ui.weapon_sight(int(_weapon_sight.frame), true), _weapon_sight.position)
	if not pause_overlay and not _vs_status.is_empty():
		_draw_large_message(_vs_status.to_ascii_buffer())
	draw_set_transform(Vector2.ZERO)


func _draw_wide_frame() -> void:
	# Reserve opaque panel interiors FIRST. Individual source patches keep their
	# transparency so overlapping rims reproduce the composition's layer order.
	draw_set_transform(Vector2.ZERO)
	for group: String in Layout.panel_rects(display_layout):
		if group != "map":
			draw_rect(Layout.panel_rects(display_layout)[group], Color.BLACK)
	for group: String in ["keys", "weapons", "ammo"]:
		_set_group_transform(group)
		if group == "weapons" and display_layout.compact_weapons:
			draw_texture(ui.multiplayer_weapon_frame(true),Vector2(64,0))
			continue
		var source: Rect2i = {
			"keys": Rect2i(0, 0, 64, 61),
			"weapons": Rect2i(64, 0, 56, 61),
			"ammo": Rect2i(120, 0, 22, 61)
		}[group]
		_frame_piece(source, Vector2(source.position))
	_set_group_transform("health")
	_frame_piece(Rect2i(0, 64, 24, 160), Vector2(0, 64))
	_frame_piece(Rect2i(0, 64, 10, 160), Vector2(21, 64), true)
	_frame_piece(Rect2i(0, 58, 31, 6), Vector2(0, 58))
	_frame_piece(Rect2i(0, 64, 8, 3), Vector2(23, 62), true)
	_frame_piece(Rect2i(0, 73, 6, 3), Vector2(25, 58), true)


func _frame_piece(source: Rect2i, destination: Vector2, flip_x: bool = false) -> void:
	if not _frame_regions.has(source):
		var region := AtlasTexture.new()
		region.atlas = ui.frame(true)
		region.region = Rect2(source)
		region.filter_clip = true
		_frame_regions[source] = region
	var rect := Rect2(destination, Vector2(source.size))
	if flip_x:
		# CanvasItem treats a negative size as a texture flip at the given origin;
		# adding the width here would incorrectly translate the mirrored patch.
		rect.size.x = -rect.size.x
	draw_texture_rect(_frame_regions[source], rect, false)


func _notification_icon(icon: int, deadline: float) -> Texture2D:
	return ui.pickup_static(_time, true) if _time < deadline else ui.icon(icon, true)


## Native alignment policy only: original byte IDs, glyph pixels and message
## timing remain intact. Measure visible ink so source cell padding cannot shift
## a string off centre. Long VS notices wrap at spaces, keeping the same font.
func large_message_layout(value: PackedByteArray) -> Array:
	var key := value.hex_encode()
	if _large_message_layouts.has(key):
		return _large_message_layouts[key]
	var words: Array = [[]]
	for code: int in value:
		if code == 32: words.append([])
		else: words[-1].append(code)
	var lines: Array = [[]]
	var width := 0.0
	var maximum: float = view_rect.size.x / display_layout.full_scale.x - 16.0
	var space: float = ui.character(32,true).get_width()
	for word: Array in words:
		if word.is_empty(): continue
		var word_width := 0.0
		for code: int in word: word_width += ui.character(code,true).get_width()
		if width > 0.0 and width + space + word_width > maximum:
			lines.append([])
			width = 0.0
		if width > 0.0:
			lines[-1].append(32)
			width += space
		lines[-1].append_array(word)
		width += word_width
	var rows: Array = []
	for line: Array in lines:
		var glyphs: Array = []
		var ink := Rect2()
		var x := 0.0
		for code: int in line:
			var texture: Texture2D = ui.character(code,true)
			# Space reserves its source advance, as in the menu writer. Its
			# table cell contains unrelated artwork and must not draw as a glyph.
			if code == 32:
				x += texture.get_width()
				continue
			var pixels: Image = preload("res://scripts/assets/cd_immutable_texture.gd").pixels(texture)
			var bounds := Rect2(pixels.get_used_rect())
			if bounds.has_area():
				bounds.position.x += x
				ink = bounds if not ink.has_area() else ink.merge(bounds)
			glyphs.append({"code":code,"position":Vector2(x,0)})
			x += texture.get_width()
		var origin := Vector2(136.0 - ink.get_center().x,112.0 + (rows.size() - (lines.size()-1) * 0.5) * 24.0)
		rows.append({"position":origin,"ink":ink,"glyphs":glyphs})
	_large_message_layouts[key] = rows
	return rows


func _draw_large_message(value: PackedByteArray) -> void:
	_set_group_transform("message")
	for row: Dictionary in large_message_layout(value):
		for glyph: Dictionary in row.glyphs:
			draw_texture(ui.character(glyph.code,true),row.position + glyph.position)
