extends RefCounted
## Per-process native resources prepared behind the existing launch screen.
## Only immutable geometry/material/font/navigation resources survive this pass.
const World = preload("res://scripts/world/native_cd_world.gd")
const Navigation = preload("res://scripts/game/bot_navigation.gd")
const Actor = preload("res://scenes/actors/cd_actor.gd")
const Colours = preload("res://scripts/presentation/player_colours.gd")
const CANVAS_SHADERS := {
	"cd_sharp_bilinear":preload("res://shaders/cd_sharp_bilinear.gdshader"),
	"cd_palette_ui":preload("res://shaders/cd_palette_ui.gdshader"),
	"cd_menu_background":preload("res://shaders/cd_menu_background.gdshader"),
	"cd_menu_text_static":preload("res://shaders/cd_menu_text_static.gdshader")
}
static var _identity := ""
static var _statistics: Dictionary = {}
static var _scenes: Array[PackedScene] = []


static func ready() -> bool:
	return not _identity.is_empty()


static func statistics() -> Dictionary:
	return _statistics.duplicate(true)


static func prepare(source: RefCounted, progress: Callable = Callable()) -> bool:
	var identity: String = source.catalog.get("verified_edition", "")
	if not source.supported_media():
		source.last_error = "Mount verified original media before native preparation"
		return false
	if _identity == identity: return true
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: return false
	var started := Time.get_ticks_usec()
	# Keep scene resources and their complete script/shader dependency graphs
	# resident too. Parsing them on the first match is still first-use work.
	for path: String in ["res://scenes/gameplay/gameplay.tscn", "res://scenes/campaign/campaign.tscn", "res://scenes/network_gameplay/network_gameplay.tscn", "res://scenes/audio_settings/audio_settings.tscn", "res://scenes/video_settings/video_settings.tscn", "res://scenes/small_notice/small_notice.tscn"]:
		var scene := load(path) as PackedScene
		if scene == null:
			source.last_error = "Could not prepare gameplay scenes"
			return false
		_scenes.append(scene)
		# Instantiate defaults off-tree: no _ready(), authority configuration,
		# input capture, audio playback or simulation clock can run here.
		var defaults := scene.instantiate()
		defaults.free()
	var stats := {"maps":0, "navigation_maps":0, "billboard_frames":0, "prepare_usec":0}
	var paths: Array[String] = ["/NATIVE/LOBBY"]
	for index: int in range(1,17): paths.append("/LEVEL%d.LEV" % index)
	for index: int in range(1,4): paths.append("/ARENA%d.LEV" % index)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(tree.root.get_visible_rect().size).max(Vector2i(2,2))
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.current = true
	camera.position = Vector3(0,0.5,0)
	# Exercise the real full-resolution two-pass composition, including its
	# transparent billboard render target, before the first game uses it.
	var billboard_pass: CanvasLayer = preload("res://scenes/presentation/cd_billboard_pass.tscn").instantiate()
	viewport.add_child(billboard_pass)
	billboard_pass.configure(camera)
	var font: FontFile = source.load_cd_small_font().native_font()
	var menu_ui: RefCounted = source.load_cd_frontend_catalog().ui
	var menu_theme := preload("res://scripts/frontend/native_small_theme.gd")
	for index: int in range(4):
		for ink: Color in [menu_theme.INK, menu_theme.ACCENT]:
			menu_ui.menu_slider_texture(index, ink)
	var text := Label.new()
	text.text = "0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	text.add_theme_font_override("font",font)
	text.add_theme_font_size_override("font_size",12)
	preload("res://scripts/presentation/sharp_bilinear_ui.gd").apply(text)
	viewport.add_child(text)
	for path: String in paths:
		if progress.is_valid(): progress.call("Preparing maps and graphics", stats.maps,20)
		var world := World.new()
		if not world.load_original(path):
			source.last_error = world.last_error
			world.free()
			viewport.queue_free()
			return false
		var catalog: Resource
		if path == "/NATIVE/LOBBY":
			var definition := preload("res://scripts/game/world_definition.gd").new()
			if not definition.load_map(world.source,"lobby"):
				world.free()
				viewport.queue_free()
				return false
			catalog = definition.catalog
		else:
			catalog = world.source.load_cd_actor_catalog(world.level)
			var navigation := Navigation.new()
			navigation.configure(world.level)
			stats.navigation_maps += 1
		preload("res://scenes/actors/native_inventory_layer.gd").prepare_pickups(world.source,world.level,catalog)
		var materials := Actor.prepare_materials(world.source,world.level,catalog)
		stats.billboard_frames += materials.keys().filter(func(address): return address >= 0).size()
		var ui: RefCounted = source.load_cd_ui(world.level)
		for indexed: bool in [false,true]:
			for heading: int in range(8): ui._minimap_background(world.level,heading,indexed)
		for colour: int in range(4):
			Colours.skull_texture(ui.icon(4),colour)
			Colours.skull_texture(ui.icon(4),colour,true)
		viewport.add_child(world)
		# Each real map submits its wall/surface/depth pipelines. Billboard and
		# canvas variants are additionally drawn in camera space, never culled by
		# a spawn-facing wall or masked by another warmup surface.
		var sprites: Array[Node] = []
		var frame: int = materials.keys().filter(func(address): return address >= 0)[0]
		for colour: int in range(4):
			var sprite := Sprite3D.new()
			sprite.texture = world.source.texture_from_cd_actor(world.level,catalog,frame)
			sprite.material_override = materials[frame]
			sprite.position = Vector3(-0.3+colour*0.2,0.5,-0.5)
			sprite.layers = 4
			sprite.pixel_size = 0.002
			sprite.set_instance_shader_parameter("player_colour",colour)
			viewport.add_child(sprite)
			sprites.append(sprite)
		# Submit the directional missile shader during launch, including its front path.
		var missile := Sprite3D.new()
		missile.texture = world.source.texture_from_cd_actor(world.level,catalog,0x3e156)
		missile.material_override = materials[0x3e156]
		missile.pixel_size = Actor.PIXEL_WIDTH
		missile.position = Vector3(0,0.5,-0.5)
		missile.layers = 4
		missile.set_instance_shader_parameter("missile_velocity",Vector2(0,1))
		viewport.add_child(missile)
		sprites.append(missile)
		var departure := Sprite3D.new()
		departure.texture = sprites[0].texture
		departure.position = Vector3(0,0.5,-0.3)
		departure.layers = 4
		departure.pixel_size = 0.001
		var noise: ShaderMaterial = materials[frame].duplicate()
		noise.shader = preload("res://shaders/native_departure.gdshader")
		departure.material_override = noise
		viewport.add_child(departure)
		sprites.append(departure)
		for shader: String in CANVAS_SHADERS:
			var image := TextureRect.new()
			image.texture = ui.frame(true)
			image.size = Vector2(48,48)
			image.position = Vector2(0,24+sprites.size()*8)
			var ink := ShaderMaterial.new()
			ink.shader = CANVAS_SHADERS[shader]
			if shader == "cd_palette_ui":
				ink.set_shader_parameter("palette_texture", world.palette.texture)
			elif shader == "cd_menu_background":
				var frontend: RefCounted = source.load_cd_frontend_catalog()
				ink.set_shader_parameter("source_tiles", frontend.noise_tiles())
				ink.set_shader_parameter("seeds", frontend.noise_seeds())
				var menu_palette := preload("res://scripts/presentation/cd_menu_palette.gd").new()
				menu_palette.configure(frontend.noise_targets())
				ink.set_shader_parameter("colour_palette", menu_palette.texture)
			elif shader == "cd_menu_text_static":
				ink.set_shader_parameter("static_pattern",ui.text_noise_pattern(0))
			image.material = ink
			viewport.add_child(image)
			sprites.append(image)
		if DisplayServer.get_name() == "headless":
			await tree.process_frame
		else:
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
		viewport.remove_child(world)
		world.free()
		for sprite: Node in sprites: sprite.free()
		stats.maps += 1
		await tree.process_frame
	viewport.queue_free()
	await tree.process_frame
	stats.prepare_usec = Time.get_ticks_usec()-started
	source._asset_cache.retain_runtime_views(source.cache_groups())
	_statistics = stats
	_identity = identity
	return true
