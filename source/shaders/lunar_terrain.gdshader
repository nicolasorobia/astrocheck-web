shader_type spatial;

// Lunar ground: world-space tiling regolith texture, a second rotated
// large-scale sample to break up repetition, and slightly darker slopes.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_tex : hint_roughness_r, filter_linear_mipmap, repeat_enable;
uniform float tile_size = 4.0;          // meters per texture repeat up close
uniform float macro_size = 47.0;        // meters per repeat of the large variation layer
uniform float macro_strength = 0.35;
uniform float slope_darken = 0.3;
uniform float normal_strength = 1.0;
uniform vec3 tint : source_color = vec3(1.0);

varying vec3 world_pos;
varying float world_up;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_up = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
}

void fragment() {
	vec2 uv = world_pos.xz / tile_size;
	vec2 macro_uv = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * world_pos.xz / macro_size;

	vec3 col = texture(albedo_tex, uv).rgb;
	float macro = dot(texture(albedo_tex, macro_uv).rgb, vec3(0.3333));
	col *= mix(1.0, 0.6 + macro, macro_strength);

	float slope = clamp(1.0 - world_up, 0.0, 1.0);
	col *= 1.0 - slope * slope_darken;

	ALBEDO = col * tint;
	NORMAL_MAP = texture(normal_tex, uv).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
	ROUGHNESS = texture(rough_tex, uv).r;
}
