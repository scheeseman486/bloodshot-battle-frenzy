shader_type canvas_item;
uniform sampler2D palette_texture : filter_nearest;
uniform bool use_colour_override = false;
uniform sampler2D colour_override : filter_nearest;
uniform sampler2D colour_baseline : filter_nearest;
varying vec4 vertex_tint;
void vertex() { vertex_tint = COLOR; }
void fragment() {
	// Fractional UI scales can put a texel edge exactly on a screen-pixel
	// center. Interpolated UV roundoff otherwise selects alternating columns
	// along that edge. Resolve near-integer source coordinates consistently;
	// the tolerance is in source pixels and does not change the artwork scale.
	ivec2 dimensions = textureSize(TEXTURE, 0);
	vec2 position = UV * vec2(dimensions);
	vec2 boundary = round(position);
	// Small corner icons near the bottom edge accumulate more float32 transform
	// error than the large meters. One thousandth of a source texel covers that
	// roundoff while retaining nearest sampling and the original artwork scale.
	position = mix(position, boundary, lessThan(abs(position - boundary), vec2(0.001)));
	// Sample the selected texel's center while retaining the native sampler's
	// repeat/clamp mode (the hit/death cover also uses this material).
	vec2 center = (floor(position) + vec2(0.5)) / vec2(dimensions);
	vec4 indices_sample = textureLod(TEXTURE, center, 0.0);
	float index = round(indices_sample.r * 255.0);
	vec3 ink = texture(palette_texture, vec2((index + 0.5) / 64.0, 0.5)).rgb;
	if (use_colour_override && distance(ink, texture(colour_baseline, center).rgb) < 0.001) {
		ink = texture(colour_override, center).rgb;
	}
	COLOR = vec4(ink, indices_sample.a) * vertex_tint;
}
