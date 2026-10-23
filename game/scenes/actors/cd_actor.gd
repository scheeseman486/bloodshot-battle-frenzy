extends Node3D
## Native upright billboard. Resources are generated from original CD bytes at
## runtime and are never saved into this scene or into an extracted asset folder.
const CameraProfile = preload("res://scripts/presentation/cd_projection.gd")
const Pixels = preload("res://scripts/assets/cd_immutable_texture.gd")
static var _prepared: Dictionary = {}
static var preparation_builds := 0
const Colours = preload("res://scripts/presentation/player_colours.gd")
const PIXEL_WIDTH := 2.5 / 256.0
const PIXEL_HEIGHT := PIXEL_WIDTH / CameraProfile.SOURCE_PIXEL_ASPECT
var _source: RefCounted
var _catalog: Resource
var _level: Resource
var _frame := -1
var _height := 2147483647
var _colour := -1
var _material: ShaderMaterial
var _materials: Dictionary = {}


func configure(
	source: RefCounted, level: Resource, catalog: Resource, materials: Dictionary = {}
) -> void:
	_source = source
	_level = level
	_catalog = catalog
	_frame = -1
	_height = 2147483647
	_colour = -1
	_materials = materials
	_material = null
	$Billboard.pixel_size = PIXEL_WIDTH
	$Billboard.scale.y = 1.0 / CameraProfile.SOURCE_PIXEL_ASPECT


func present(actor: Dictionary, world: Node3D, presentation_tick: float = 0.0) -> void:
	visible = int(actor.kind) != 0 and not bool(actor.get("local_player", false))
	if not visible:
		return
	position = world.visual_point(Vector2(float(actor.x), float(actor.y)))
	var address := int(actor.frame)
	if not _catalog.frames.has(address):
		visible = false
		return
	var frame: Dictionary = _catalog.frames[address]
	var sprite: Sprite3D = $Billboard
	var colour := int(actor.get("player_colour", 0)) if int(actor.kind) in [20, 23] else 0
	if colour != _colour:
		_colour = colour
		sprite.set_instance_shader_parameter("player_colour", colour)
	var changed := address != _frame
	if changed:
		_frame = address
		sprite.texture = _source.texture_from_cd_actor(_level, _catalog, address)
		# Frame and palette are immutable for this level. Share their material
		# across actors instead of allocating identical GPU shader state per slot.
		_material = _frame_material(address)
		sprite.material_override = _material
		sprite.offset = Vector2(float(frame.width) * 0.5 - float(frame.anchor.x), 0)
	# $03253E/3263E: actor height uses one focal unit; frame dimensions and
	# anchor use two. Default source height 128 puts the anchor at floor level.
	if changed or int(actor.height) != _height:
		_height = int(actor.height)
		sprite.position.y = (
			CameraProfile.WALL_HEIGHT * 0.5
			- float(actor.height) * PIXEL_HEIGHT * 0.5
			+ (float(frame.anchor.y) - float(frame.height) * 0.5) * PIXEL_HEIGHT
		)
	if address == 0x3e156:
		sprite.set_instance_shader_parameter("missile_velocity", Vector2(float(actor.get("vx",0)), -float(actor.get("vy",0))))
		sprite.set_instance_shader_parameter("missile_tick", presentation_tick)
		# Front/side source layers can extend past the original rear quad.
		sprite.extra_cull_margin = 0.25
	else:
		sprite.extra_cull_margin = 0.0
	visible = sprite.texture != null


func _configure_armour(material: ShaderMaterial, address: int) -> void:
	# Negative cache keys are per-level immutable cosmetic resources. Each frame
	# retains one material, shared even by four differently coloured players.
	if not _materials.has(-1):
		_materials[-1] = Colours.mask_profiles()
		_materials[-2] = ImageTexture.create_from_image(Colours.ramp_image())
		var baseline := Image.create_empty(6, 1, false, Image.FORMAT_RGBA8)
		var palette: RefCounted = _source.load_cd_palette(_level)
		for step: int in range(6):
			baseline.set_pixel(step, 0, palette.banks[0][40 + step])
		_materials[-3] = ImageTexture.create_from_image(baseline)
	var profiles: Dictionary = _materials[-1]
	if _catalog.source_sha256 != profiles.source_sha256.shell:
		return
	var profile: Dictionary = profiles.frames.get(str(address), {})
	if profile.is_empty():
		return
	var indices: Texture2D = material.get_shader_parameter("source_indices")
	var mask := Colours.armour_mask(Pixels.pixels(indices), profile)
	if mask == null:
		push_error("Approved armour source mask mismatch at %x" % address)
		return
	material.set_shader_parameter("armour_mask", ImageTexture.create_from_image(mask))
	material.set_shader_parameter("armour_ramps", _materials[-2])
	material.set_shader_parameter("armour_original", _materials[-3])
	material.set_shader_parameter("has_armour_mask", true)


func _frame_material(address: int) -> ShaderMaterial:
	if not _materials.has(address):
		var ink := ShaderMaterial.new()
		ink.shader = preload("res://shaders/cd_palette_billboard.gdshader")
		ink.set_shader_parameter("palette_texture", _source.load_cd_palette(_level).texture)
		ink.set_shader_parameter("source_indices", _source.index_texture_from_cd_actor(_level, _catalog, address))
		if address == 0x3e156:
			ink.shader = preload("res://shaders/cd_missile.gdshader")
			ink.set_shader_parameter("source_pixel_size", PIXEL_WIDTH)
			ink.set_shader_parameter("warhead_indices", _source.index_texture_from_cd_actor(_level, _catalog, 0x3e588))
			ink.set_shader_parameter("exhaust_indices", _source.index_texture_from_cd_actor(_level, _catalog, 0x3e394))
		else:
			_configure_armour(ink, address)
		_materials[address] = ink
	return _materials[address]


static func prepare_materials(source: RefCounted, level: Resource, catalog: Resource) -> Dictionary:
	var key: String = level.source_sha256 + ":" + catalog.source_sha256
	if not _prepared.has(key):
		# No scene nodes or actor state are cached. The helper only constructs
		# immutable frame materials and retained CPU-derived armour masks.
		var helper: Node3D = load("res://scenes/actors/cd_actor.tscn").instantiate()
		helper.configure(source, level, catalog)
		for address: int in catalog.frames:
			if int(catalog.frames[address].offset) <= 0: continue
			source.texture_from_cd_actor(level, catalog, address)
			helper._frame_material(address)
		_prepared[key] = helper._materials
		helper.free()
		preparation_builds += 1
	return _prepared[key]


static func materials_for(source: RefCounted, level: Resource, catalog: Resource) -> Dictionary:
	var result := {}
	var prepared := prepare_materials(source, level, catalog)
	var palette: Texture2D = source.load_cd_palette(level).texture
	for address: int in prepared:
		if address < 0:
			result[address] = prepared[address]
		else:
			var ink: ShaderMaterial = prepared[address].duplicate()
			ink.set_shader_parameter("palette_texture", palette)
			result[address] = ink
	return result
