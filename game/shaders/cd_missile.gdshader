shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform sampler2D source_indices : filter_nearest, repeat_disable;
uniform sampler2D warhead_indices : filter_nearest, repeat_disable;
uniform sampler2D exhaust_indices : filter_nearest, repeat_disable;
uniform sampler2D palette_texture : source_color, filter_nearest;
uniform float source_pixel_size = 0.009765625;
instance uniform int player_colour = 0;
instance uniform vec2 missile_velocity = vec2(0.0);
instance uniform float missile_tick = 0.0;
// 0: switch only; 1: separated full billboards; 2: axial exhaust/rear layer.
instance uniform int missile_treatment = 2;
varying float front_amount;
varying float side_amount;
varying float face_amount;

void vertex() {
	vec3 forward = normalize(vec3(INV_VIEW_MATRIX[2].x, 0.0, INV_VIEW_MATRIX[2].z));
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), forward));
	vec3 ray = INV_VIEW_MATRIX[3].xyz - MODEL_MATRIX[3].xyz;
	// Orthographic inspectors use parallel rays; perspective gameplay uses the eye.
	if (PROJECTION_MATRIX[3][3] > 0.5 || length(ray.xz) < 0.0001) ray = forward;
	vec2 direction = length(missile_velocity) > 0.0001 ? normalize(missile_velocity) : -forward.xz;
	face_amount = dot(direction, normalize(ray.xz));
	side_amount = dot(direction, right.xz);
	front_amount = face_amount > -0.65 ? 1.0 : 0.0;
	if (front_amount > 0.0) {
		// Expand transparent drawing bounds only. Source rear pixels retain their
		// exact size and anchor when sampled inside the larger canvas.
		VERTEX.x = (VERTEX.x - 1.5 * source_pixel_size) * (44.0 / 21.0);
		VERTEX.y *= 32.0 / 22.0;
	}
	mat4 billboard = mat4(vec4(right * length(MODEL_MATRIX[0].xyz), 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(forward * length(MODEL_MATRIX[2].xyz), 0.0), MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
}

vec4 source_pixel(sampler2D image, vec2 pixel, vec2 size) {
	pixel = floor(pixel);
	if (any(lessThan(pixel, vec2(0.0))) || any(greaterThanEqual(pixel, size))) return vec4(0.0);
	return texture(image, (pixel + 0.5) / size);
}

void fragment() {
	vec4 ink;
	if (front_amount <= 0.0) {
		// Unmodified original sprite, geometry, texture coordinates and alpha.
		ink = texture(source_indices, UV);
	} else {
		vec2 pixel = (UV - vec2(0.5)) * vec2(44.0, 32.0);
		float side = missile_treatment == 0 ? 0.0 : side_amount;
		// Exhaust and the complete rear card share axial foreshortening. The orb
		// casing keeps its original proportions; do not shrink it to expose fins.
		float axial_width = missile_treatment == 2 ? max(abs(face_amount), 0.18) : 1.0;
		// Two original exhaust sizes alternate on presentation time; no new inks.
		float pulse = mod(floor(missile_tick / 3.0), 2.0) < 1.0 ? 1.0 : 0.86;
		vec2 exhaust_pixel = vec2((pixel.x + 9.0 * side) / axial_width, pixel.y) / pulse;
		ink = source_pixel(exhaust_indices, exhaust_pixel + vec2(10.0), vec2(21.0));
		if (missile_treatment == 2) {
			// Keep the complete original rear sprite, including its engine centre.
			// It sits in front of the exhaust and does not flicker.
			vec2 rear_pixel = vec2((pixel.x + 6.0 * side) / axial_width, pixel.y);
			vec4 rear = source_pixel(source_indices, rear_pixel + vec2(9.0, 11.0), vec2(21.0, 22.0));
			if (rear.a > 0.5) ink = rear;
		}
		if (missile_treatment == 2) {
			// Restore the original axial proof's two full-proportion orb slices.
			for (int slice = 0; slice < 2; slice++) {
				vec2 body_pixel = pixel - vec2((float(slice) * 6.0 - 3.0) * side, 0.0);
				vec4 body = source_pixel(warhead_indices, body_pixel + vec2(7.0, 6.0), vec2(15.0));
				if (body.a > 0.5) ink = body;
			}
		}
		vec2 nose_pixel = pixel - vec2(9.0 * side, 0.0);
		vec4 nose = source_pixel(warhead_indices, nose_pixel + vec2(7.0, 6.0), vec2(15.0));
		if (nose.a > 0.5) ink = nose;

	}
	float index = round(ink.r * 255.0);
	ALBEDO = texture(palette_texture, vec2((index + 0.5) / 64.0, 0.5)).rgb;
	ALPHA = ink.a;
}
