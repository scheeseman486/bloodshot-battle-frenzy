shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D source_indices : filter_nearest;
uniform sampler2D palette_texture : source_color, filter_nearest;
void fragment() {
	float index = round(texture(source_indices, UV).r * 255.0);
	ALBEDO = texture(palette_texture, vec2((index + 0.5) / 64.0, 0.5)).rgb;
}
