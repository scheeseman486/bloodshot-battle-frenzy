class_name DisplayGeometry
extends RefCounted
## Convert a measured source raster to a display aspect. This applies to flat
## artwork only; a native Camera3D renders square pixels in the output viewport.

static func pixel_aspect(source_size: Vector2i, display_aspect: float) -> float:
	if source_size.x <= 0 or source_size.y <= 0 or display_aspect <= 0:
		return 1.0
	return display_aspect * float(source_size.y) / float(source_size.x)


static func vertical_fov(horizontal_degrees: float, viewport_aspect: float) -> float:
	if viewport_aspect <= 0 or horizontal_degrees <= 0 or horizontal_degrees >= 180:
		return 0.0
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(horizontal_degrees) / 2.0) / viewport_aspect))
