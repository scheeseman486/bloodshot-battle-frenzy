shader_type spatial;
render_mode unshaded, cull_disabled;
// Real native surfaces, with their own semantic entry in the runtime CD palette.
// Shared texture updates also carry original hit/death and countdown changes.
uniform sampler2D palette_texture : source_color, filter_nearest;
uniform int color_index : hint_range(0, 63) = 0;
void fragment() {
	ALBEDO = texture(palette_texture, vec2((float(color_index) + 0.5) / 64.0, 0.5)).rgb;
}
