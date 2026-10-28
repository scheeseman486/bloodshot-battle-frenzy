shader_type canvas_item;
render_mode unshaded;
#include "res://shaders/sharp_bilinear.gdshaderinc"
// Native title overlay/authored small-font noise. Original large glyphs use the
// source word generator and decoded noisy resources, including transparent holes.
uniform sampler2D static_pattern : filter_nearest, repeat_enable;
uniform vec4 ink_1 : source_color;
uniform vec4 ink_4 : source_color;
uniform vec4 ink_5 : source_color;
varying float unresolved;
varying vec4 artwork_tint;
varying vec2 original_uv;

void vertex() {
	unresolved = float(COLOR.r < 0.001 && COLOR.g > 0.999 && COLOR.b > 0.999);
	artwork_tint = COLOR;
	original_uv = UV;
}

vec4 text_ink(vec4 glyph, vec2 pixel) {
	float index = round(texture(static_pattern, (mod(pixel, 16.0) + 0.5) / 16.0).r * 255.0);
	vec4 noise = vec4(0.0);
	if (index > 4.5) { noise = ink_5; }
	else if (index > 3.5) { noise = ink_4; }
	else if (index > 0.5) { noise = ink_1; }
	return mix(glyph * artwork_tint, vec4(noise.rgb, noise.a * glyph.a * artwork_tint.a), unresolved);
}

void fragment() {
	vec2 dimensions = vec2(textureSize(TEXTURE, 0));
	vec2 width = sharp_footprint(UV * dimensions, original_uv * dimensions, dimensions);
	vec2 coordinate = sharp_position_with_footprint(UV * dimensions, width) - vec2(0.5);
	vec2 base = floor(coordinate);
	vec2 uv_a = sharp_tap_uv(base, dimensions, REGION_RECT);
	vec2 uv_b = sharp_tap_uv(base + vec2(1.0, 0.0), dimensions, REGION_RECT);
	vec2 uv_c = sharp_tap_uv(base + vec2(0.0, 1.0), dimensions, REGION_RECT);
	vec2 uv_d = sharp_tap_uv(base + vec2(1.0), dimensions, REGION_RECT);
	vec4 a = text_ink(textureLod(TEXTURE, uv_a, 0.0), floor(uv_a * dimensions));
	vec4 b = text_ink(textureLod(TEXTURE, uv_b, 0.0), floor(uv_b * dimensions));
	vec4 c = text_ink(textureLod(TEXTURE, uv_c, 0.0), floor(uv_c * dimensions));
	vec4 d = text_ink(textureLod(TEXTURE, uv_d, 0.0), floor(uv_d * dimensions));
	COLOR = sharp_mix(a, b, c, d, fract(coordinate));
}
