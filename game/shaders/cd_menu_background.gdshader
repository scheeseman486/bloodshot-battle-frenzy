shader_type canvas_item;
render_mode unshaded;
#include "res://shaders/sharp_bilinear.gdshaderinc"
// Original nine-triangle sample field ($2EE8A), expressed as native pixel
// drawing. Hardware timer entropy is replaced with a fixed independent seed.
uniform sampler2D source_tiles : filter_nearest, repeat_disable;
uniform sampler2D seeds : filter_nearest, repeat_disable;
uniform float phase = 0.0;
uniform vec2 logical_size = vec2(256.0, 224.0);
uniform vec2 logical_origin = vec2(0.0);
uniform sampler2D colour_palette : source_color, filter_nearest, repeat_disable;

float triangle(float value) {
	float folded = mod(value, 64.0);
	return folded < 32.0 ? folded : 63.0 - folded;
}

vec4 background_ink(vec2 pixel) {
	vec2 cell = floor(pixel / 8.0);
	float position = cell.y * 32.0 + cell.x;
	float total = 0.0;
	for (int row = 0; row < 3; row++) {
		for (int column = 0; column < 3; column++) {
			float index = position + float(row * 32 + column);
			// Continue the source entropy field beyond the original horizontal frame.
			// Preserve its existing center samples, including its clamped tail.
			if (cell.x < 0.0 || cell.x >= 32.0) {
				index = mod(index, 960.0);
			}
			float seed = texture(seeds, vec2((index + 0.5) / 960.0, 0.5)).r * 255.0;
			total += triangle(floor(seed + 0.5) + phase);
		}
	}
	float tile = min(31.0, floor(total / 8.0));
	vec2 tile_pixel = mod(pixel, 8.0);
	float ink = texture(source_tiles, vec2((tile * 8.0 + tile_pixel.x + 0.5) / 256.0, (tile_pixel.y + 0.5) / 8.0)).r;
	// MAINOS tiles already encode the dithered sixteen-colour gradient.
	float palette_index = round(ink * 15.0);
	return vec4(texture(colour_palette, vec2((palette_index + 0.5) / 16.0, 0.5)).rgb, 1.0);
}

void fragment() {
	vec2 coordinate = sharp_position(UV * logical_size + logical_origin) - vec2(0.5);
	vec2 base = floor(coordinate);
	vec2 weight = fract(coordinate);
	vec4 a = background_ink(base);
	// Flat interiors need only the original nine-seed evaluation. Evaluate
	// neighbors at transitions, keeping the common fullscreen case inexpensive.
	vec4 b = weight.x > 0.0001 ? background_ink(base + vec2(1.0, 0.0)) : a;
	vec4 c = weight.y > 0.0001 ? background_ink(base + vec2(0.0, 1.0)) : a;
	vec4 d = a;
	if (weight.x > 0.0001 && weight.y > 0.0001) {
		d = background_ink(base + vec2(1.0));
	} else if (weight.x > 0.0001) {
		d = b;
	} else if (weight.y > 0.0001) {
		d = c;
	}
	COLOR = mix(mix(a, b, weight.x), mix(c, d, weight.x), weight.y);
}
