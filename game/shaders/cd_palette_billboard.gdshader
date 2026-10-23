shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform sampler2D source_indices : filter_nearest;
uniform sampler2D palette_texture : source_color, filter_nearest;
uniform sampler2D armour_mask : filter_nearest;
uniform sampler2D armour_ramps : source_color, filter_nearest;
uniform sampler2D armour_original : source_color, filter_nearest;
uniform bool has_armour_mask = false;
instance uniform int player_colour = 0;
void vertex() {
	// Native fixed-Y billboard, retaining source anchor and node scale.
	vec3 forward = normalize(vec3(INV_VIEW_MATRIX[2].x, 0.0, INV_VIEW_MATRIX[2].z));
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), forward));
	mat4 billboard = mat4(vec4(right * length(MODEL_MATRIX[0].xyz), 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(forward * length(MODEL_MATRIX[2].xyz), 0.0), MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
}
void fragment() {
	vec4 indices_sample = texture(source_indices, UV);
	float index = round(indices_sample.r * 255.0);
	ALBEDO = texture(palette_texture, vec2((index + 0.5) / 64.0, 0.5)).rgb;
	if (has_armour_mask && player_colour > 0 && player_colour < 4 && texture(armour_mask, UV).r > 0.5) {
		float step = index - 40.0;
		vec3 original = texture(armour_original, vec2((step + 0.5) / 6.0, 0.5)).rgb;
		// A changed live palette entry takes priority over the cosmetic ramp.
		// Non-armour pixels, blood, hit cover and source alpha stay untouched.
		if (distance(ALBEDO, original) < 0.001) {
			ALBEDO = texture(armour_ramps, vec2((step + 0.5) / 6.0, (float(player_colour) + 0.5) / 4.0)).rgb;
		}
	}
	ALPHA = indices_sample.a;
}
