shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_always, shadows_disabled, fog_disabled;

// Transparent colour preserves the main view's real surface rendering. Depth
// still writes in the billboard view, before the ordinary transparent sprites.
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
