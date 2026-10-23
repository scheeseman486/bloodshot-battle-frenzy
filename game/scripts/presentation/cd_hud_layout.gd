class_name CdHudLayout
extends RefCounted
## Native placement policy inferred from the finished HUD composition. Art stays
## in original CD resources. The corner HUD is half scale; map, sight and large messages are full.
const Ui = preload("res://scripts/assets/cd_ui_catalog.gd")
const CameraProfile = preload("res://scripts/presentation/cd_projection.gd")
const SOURCE_ORIGINS := {
	"keys": Vector2.ZERO, "weapons": Vector2(64, 0), "ammo": Vector2(120, 0),
	"lives": Vector2(144, 0), "health": Vector2(0, 58), "map": Vector2(192, 64)
}


static func calculate(viewport: Vector2, wide: bool, versus: bool = false) -> Dictionary:
	var height := minf(viewport.y, viewport.x * 0.75)
	var full := Vector2(CameraProfile.SOURCE_PIXEL_ASPECT, 1.0) * height / 224.0
	var frame_size := Vector2(256, 224) * full
	var frame_origin := (viewport - frame_size) * 0.5
	var result := {
		"wide": wide, "compact_weapons": wide and versus, "frame_origin": frame_origin, "full_scale": full,
		"hud_scale": full, "safe_rect": Rect2(frame_origin, frame_size),
		"view_rect": Rect2(frame_origin + Vector2(Ui.VIEW_RECT.position) * full,
			Vector2(Ui.VIEW_RECT.size) * full)
	}
	if not wide:
		return result
	var safe_width := minf(viewport.x, viewport.y * 16.0 / 9.0)
	var safe := Rect2(Vector2((viewport.x - safe_width) * 0.5, 0), Vector2(safe_width, viewport.y))
	var half := full * 0.5
	var right := safe.end - Vector2(126 if versus else 142, 61) * half
	result.hud_scale = half
	result.safe_rect = safe
	result.view_rect = Rect2(Vector2.ZERO, viewport)
	result.groups = {
		"keys": right, "weapons": right + Vector2(64, 0) * half,
		"ammo": right + Vector2(104 if versus else 120, 0) * half,
		"health": Vector2(safe.position.x, safe.end.y - 166 * half.y),
		"lives": Vector2(safe.position.x + 30 * half.x, safe.end.y - 62 * half.y),
		"map": Vector2(safe.end.x - 49.25 * full.x, safe.position.y + 1.25 * full.y)
	}
	return result


static func transform_for(layout: Dictionary, group: String) -> Dictionary:
	if not layout.wide:
		return {"origin": layout.frame_origin, "scale": layout.full_scale}
	if group in ["overlay", "message"]:
		# Full-size messages share the countdown's band around the world centre.
		# The sight keeps its separate original offset, four source rows below it.
		var scale: Vector2 = layout.full_scale
		return {
			"origin": layout.view_rect.get_center() - Vector2(Ui.VIEW_RECT.get_center()) * scale,
			"scale": scale
		}
	var scale: Vector2 = layout.full_scale if group == "map" else layout.hud_scale
	return {"origin": layout.groups[group] - SOURCE_ORIGINS[group] * scale, "scale": scale}


static func panel_rects(layout: Dictionary) -> Dictionary:
	var sizes := {"keys": Vector2(64, 61), "weapons": Vector2(56, 61),
		"ammo": Vector2(22, 61), "health": Vector2(31, 166),
		"lives": Vector2(112, 62), "map": Vector2(48, 40)}
	if layout.get("compact_weapons",false):
		sizes.weapons.x = 40
	var result := {}
	for group: String in sizes:
		result[group] = Rect2(layout.groups[group], sizes[group] * (
			layout.full_scale if group == "map" else layout.hud_scale))
	return result
