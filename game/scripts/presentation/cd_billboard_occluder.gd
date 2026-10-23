class_name CdBillboardOccluder
extends RefCounted
## Share an existing native mesh and its transform for billboard-only depth.
## A child follows moving doors automatically; no duplicate source data or offsets.
const DepthShader = preload("res://shaders/billboard_occluder.gdshader")
const Layers = preload("res://scripts/presentation/cd_render_layers.gd")
static var _material: ShaderMaterial


static func attach(geometry: MeshInstance3D) -> MeshInstance3D:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = DepthShader
		# Both this mesh and the billboards use the transparent pipeline. Write
		# wall depth first; sprites retain native depth testing and distance sort.
		_material.render_priority = -128
	var proxy := MeshInstance3D.new()
	proxy.name = "BillboardDepth"
	proxy.mesh = geometry.mesh
	proxy.material_override = _material
	proxy.layers = Layers.BILLBOARD_OCCLUDERS
	proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	geometry.add_child(proxy)
	return proxy
