shader_type spatial;
// Flag cloth: a solid color with a logo printed on it, and frozen wrinkles
// (no wind on the Moon - like the Apollo flags, it hangs from a top crossbar).
// The logo reads correctly from both sides.
render_mode cull_disabled;

uniform sampler2D logo : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 cloth_color : source_color = vec3(0.035, 0.075, 0.2);
uniform vec4 logo_rect = vec4(0.08, 0.255, 0.84, 0.49); // x, y, width, height in flag UV
uniform float wrinkle_depth = 0.035;                   // meters
uniform float backlight = 1.0;                         // how much light passes through the cloth

float folds(vec2 uv) {
	return sin(uv.x * 14.0 + uv.y * 3.0) * 0.65 + sin(uv.x * 31.0 - uv.y * 6.0) * 0.25;
}

void vertex() {
	// Fixed at the pole (u = 0), crumpled toward the free edge, smoother at the top bar.
	float amount = smoothstep(0.0, 0.2, UV.x) * mix(0.35, 1.0, UV.y);
	VERTEX.z += folds(UV) * wrinkle_depth * amount;
}

void fragment() {
	vec2 uv = UV;
	if (!FRONT_FACING) {
		uv.x = 1.0 - uv.x; // mirror on the back so the logo isn't backwards
	}
	vec3 col = cloth_color;
	vec2 l = (uv - logo_rect.xy) / logo_rect.zw;
	if (l.x >= 0.0 && l.x <= 1.0 && l.y >= 0.0 && l.y <= 1.0) {
		vec4 t = texture(logo, l);
		col = mix(col, t.rgb, t.a);
	}
	// Fake fold shading so the wrinkles read without per-vertex normals.
	float shade = 0.82 + 0.18 * cos(UV.x * 14.0 + UV.y * 3.0);
	ALBEDO = col * shade;
	ROUGHNESS = 0.92;
	// Thin fabric: sunlight shows through from behind, so the side in shadow
	// still reads (and the logo stays visible from either side).
	BACKLIGHT = col * backlight;
}
