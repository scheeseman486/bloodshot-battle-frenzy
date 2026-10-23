class_name CdProjection
extends RefCounted
## Campaign-start calibration from the European CD reference. The native camera
## uses square output pixels; compensate the original projection's unequal axes
## in world height, not by stretching the viewport. See cd-level-format.md.

const HALF_VIEW_WIDTH := 112.0
const RASTER_FOCAL_X := 160.0
const SOURCE_PIXEL_ASPECT := 7.0 / 6.0
const PLANAR_SOURCE_UNITS := 256.0
const PROJECTED_WALL_SOURCE_HEIGHT := 320.0
const WALL_HEIGHT := PROJECTED_WALL_SOURCE_HEIGHT / PLANAR_SOURCE_UNITS / SOURCE_PIXEL_ASPECT

static func horizontal_fov() -> float:
	return rad_to_deg(2.0 * atan(HALF_VIEW_WIDTH / RASTER_FOCAL_X))
