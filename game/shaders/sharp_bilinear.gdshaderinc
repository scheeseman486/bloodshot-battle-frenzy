// Preserve flat texel interiors; integrate a one-output-pixel-wide transition.
// Below 1:1, the unit footprint reduces to ordinary bilinear sampling.
vec2 sharp_position_with_footprint(vec2 position, vec2 width) {
	vec2 footprint = clamp(width, vec2(0.0001), vec2(1.0));
	vec2 within = fract(position);
	return floor(position) + vec2(0.5)
		+ (within - clamp(within, footprint * 0.5, vec2(1.0) - footprint * 0.5)) / footprint;
}

vec2 sharp_position(vec2 position) {
	return sharp_position_with_footprint(position, fwidth(position));
}

vec2 sharp_footprint(vec2 position, vec2 original, vec2 dimensions) {
	// Native tiled nine-patches wrap UVs before fragment code. Unwrap their
	// derivative across the full-texture seam instead of widening that edge.
	vec2 dx = abs(dFdx(position));
	vec2 dy = abs(dFdy(position));
	dx = min(dx, abs(dimensions - dx));
	dy = min(dy, abs(dimensions - dy));
	return max(dx + dy, fwidth(original));
}

vec2 sharp_tap_uv(vec2 tap, vec2 dimensions, vec4 region) {
	vec2 center = tap + vec2(0.5);
	vec2 end = region.xy + abs(region.zw);
	// Native rectangle draws expose normalized source UVs. Clamp atlas taps to
	// that draw's region, retaining the sampler's clamp/repeat for full textures.
	// Non-rectangle primitives expose pixel dimensions instead; ignore those.
	if (all(greaterThanEqual(region.xy, vec2(0.0)))
		&& all(lessThanEqual(end, vec2(1.0001)))
		&& all(greaterThan(abs(region.zw), vec2(0.0)))
		&& any(lessThan(abs(region.zw), vec2(0.9999)))) {
		vec2 first = ceil(region.xy * dimensions - vec2(0.01)) + vec2(0.5);
		vec2 last = floor(end * dimensions + vec2(0.01)) - vec2(0.5);
		center = clamp(center, first, max(first, last));
	}
	return center / dimensions;
}

vec4 sharp_premultiply(vec4 ink) {
	return vec4(ink.rgb * ink.a, ink.a);
}

vec4 sharp_mix(vec4 a, vec4 b, vec4 c, vec4 d, vec2 weight) {
	vec4 ink = mix(mix(sharp_premultiply(a), sharp_premultiply(b), weight.x),
		mix(sharp_premultiply(c), sharp_premultiply(d), weight.x), weight.y);
	return ink.a > 0.0 ? vec4(ink.rgb / ink.a, ink.a) : vec4(0.0);
}
