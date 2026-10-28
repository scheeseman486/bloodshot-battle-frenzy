shader_type canvas_item;
render_mode unshaded;
#include "res://shaders/sharp_bilinear.gdshaderinc"
varying vec4 artwork_tint;
varying vec2 original_uv;

void vertex() {
	artwork_tint = COLOR;
	original_uv = UV;
}

void fragment() {
	vec2 dimensions = vec2(textureSize(TEXTURE, 0));
	// Godot clips atlas UVs before fragment code. Preserve their unclipped
	// derivative; nine-patch mapping may instead enlarge the sample footprint.
	vec2 width = sharp_footprint(UV * dimensions, original_uv * dimensions, dimensions);
	vec2 coordinate = sharp_position_with_footprint(UV * dimensions, width) - vec2(0.5);
	vec2 base = floor(coordinate);
	vec4 a = textureLod(TEXTURE, sharp_tap_uv(base, dimensions, REGION_RECT), 0.0);
	vec4 b = textureLod(TEXTURE, sharp_tap_uv(base + vec2(1.0, 0.0), dimensions, REGION_RECT), 0.0);
	vec4 c = textureLod(TEXTURE, sharp_tap_uv(base + vec2(0.0, 1.0), dimensions, REGION_RECT), 0.0);
	vec4 d = textureLod(TEXTURE, sharp_tap_uv(base + vec2(1.0), dimensions, REGION_RECT), 0.0);
	COLOR = sharp_mix(a, b, c, d, fract(coordinate)) * artwork_tint;
}
