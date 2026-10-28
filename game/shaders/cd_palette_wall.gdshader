shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D source_indices : filter_nearest;
uniform sampler2D palette_texture : source_color, filter_nearest;
void fragment() {
	// Native backfaces must retain the CD's screen-left-to-right column order.
	// UV2 reflects within the wall's atlas region; source pointer flips are
	// already present in the runtime image and must not be applied again here.
	vec2 wall_uv = FRONT_FACING ? UV : UV2;
	float index = round(texture(source_indices, wall_uv).r * 255.0);
	ALBEDO = texture(palette_texture, vec2((index + 0.5) / 64.0, 0.5)).rgb;
}
