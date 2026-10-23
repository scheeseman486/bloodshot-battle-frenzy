shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform sampler2D source_indices : filter_nearest;
uniform sampler2D palette_texture : source_color, filter_nearest;
uniform float departure_phase = 0.0;
uniform sampler2D armour_mask : filter_nearest;
uniform sampler2D armour_ramps : source_color, filter_nearest;
uniform sampler2D armour_original : source_color, filter_nearest;
uniform bool has_armour_mask = false;
instance uniform int player_colour = 0;
void vertex() {
	vec3 forward = normalize(vec3(INV_VIEW_MATRIX[2].x, 0.0, INV_VIEW_MATRIX[2].z));
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), forward));
	mat4 billboard = mat4(vec4(right * length(MODEL_MATRIX[0].xyz), 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(forward * length(MODEL_MATRIX[2].xyz), 0.0), MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
}
void fragment() {
	vec4 source = texture(source_indices, UV);
	vec2 pixel = floor(UV * vec2(textureSize(source_indices, 0)));
	float frame = floor(departure_phase * 30.0);
	float noise = fract(sin(dot(pixel + vec2(frame * 17.0, frame * 31.0), vec2(12.9898, 78.233))) * 43758.5453);
	// Keep source alpha, add transparent noise holes and progressively dissolve.
	float mask = step(0.25 + departure_phase * 0.75, noise);
	float ink = noise < 0.5 ? 1.0 : (noise < 0.75 ? 4.0 : 5.0);
	ALBEDO = texture(palette_texture, vec2((32.0 + ink + 0.5) / 64.0, 0.5)).rgb;
	if (has_armour_mask && player_colour > 0 && player_colour < 4 && texture(armour_mask, UV).r > 0.5) {
		float step = round(source.r * 255.0) - 40.0;
		vec3 live_ink = texture(palette_texture, vec2((40.0 + step + 0.5) / 64.0, 0.5)).rgb;
		vec3 original = texture(armour_original, vec2((step + 0.5) / 6.0, 0.5)).rgb;
		ALBEDO = distance(live_ink, original) < 0.001
			? texture(armour_ramps, vec2((step + 0.5) / 6.0, (float(player_colour) + 0.5) / 4.0)).rgb : live_ink;
	}
	ALPHA = source.a * mask;
}
