shader_type canvas_item;
render_mode unshaded;
// Native title overlay/authored small-font noise. Original large glyphs use the
// source word generator and decoded noisy resources, including transparent holes.
uniform sampler2D static_pattern : filter_nearest, repeat_enable;
uniform vec4 ink_1 : source_color;
uniform vec4 ink_4 : source_color;
uniform vec4 ink_5 : source_color;
varying float unresolved;
varying vec4 artwork_tint;

void vertex() {
	unresolved = float(COLOR.r < 0.001 && COLOR.g > 0.999 && COLOR.b > 0.999);
	artwork_tint = COLOR;
}

void fragment() {
	vec4 glyph = texture(TEXTURE, UV);
	vec2 pixel = floor(UV * vec2(textureSize(TEXTURE, 0)));
	float index = round(texture(static_pattern, (mod(pixel, 16.0) + 0.5) / 16.0).r * 255.0);
	vec4 noise = vec4(0.0);
	if (index > 4.5) { noise = ink_5; }
	else if (index > 3.5) { noise = ink_4; }
	else if (index > 0.5) { noise = ink_1; }
	COLOR = mix(glyph * artwork_tint, vec4(noise.rgb, noise.a * glyph.a * artwork_tint.a), unresolved);
}
