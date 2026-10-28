shader_type canvas_item;
#include "res://shaders/sharp_bilinear.gdshaderinc"
uniform sampler2D palette_texture : filter_nearest;
uniform bool use_colour_override = false;
uniform sampler2D colour_override : filter_nearest;
uniform sampler2D colour_baseline : filter_nearest;
varying vec4 vertex_tint;
varying vec2 original_uv;
void vertex() { vertex_tint = COLOR; original_uv = UV; }
vec4 resolved_ink(vec4 indices_sample, vec2 center) {
	float index = round(indices_sample.r * 255.0);
	vec3 ink = texture(palette_texture, vec2((index + 0.5) / 64.0, 0.5)).rgb;
	if (use_colour_override && distance(ink, texture(colour_baseline, center).rgb) < 0.001) {
		ink = texture(colour_override, center).rgb;
	}
	return vec4(ink, indices_sample.a);
}

void fragment() {
	vec2 dimensions = vec2(textureSize(TEXTURE, 0));
	vec2 width = sharp_footprint(UV * dimensions, original_uv * dimensions, dimensions);
	vec2 coordinate = sharp_position_with_footprint(UV * dimensions, width) - vec2(0.5);
	vec2 base = floor(coordinate);
	// Resolve each exact index before interpolation; neighboring index numbers
	// are unrelated colors. Transparent taps blend using premultiplied alpha.
	vec2 uv_a = sharp_tap_uv(base, dimensions, REGION_RECT);
	vec2 uv_b = sharp_tap_uv(base + vec2(1.0, 0.0), dimensions, REGION_RECT);
	vec2 uv_c = sharp_tap_uv(base + vec2(0.0, 1.0), dimensions, REGION_RECT);
	vec2 uv_d = sharp_tap_uv(base + vec2(1.0), dimensions, REGION_RECT);
	vec4 a = resolved_ink(textureLod(TEXTURE, uv_a, 0.0), uv_a);
	vec4 b = resolved_ink(textureLod(TEXTURE, uv_b, 0.0), uv_b);
	vec4 c = resolved_ink(textureLod(TEXTURE, uv_c, 0.0), uv_c);
	vec4 d = resolved_ink(textureLod(TEXTURE, uv_d, 0.0), uv_d);
	COLOR = sharp_mix(a, b, c, d, fract(coordinate)) * vertex_tint;
}
