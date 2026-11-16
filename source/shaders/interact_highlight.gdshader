shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back;

// Pulsing blue rim glow, used as a material_overlay on objects the player can interact with.

uniform vec3 color : source_color = vec3(0.2, 0.82, 1.0);
uniform float rim_power = 2.5;
uniform float strength = 1.4;
uniform float pulse_speed = 3.0;

void fragment() {
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	float pulse = 0.6 + 0.4 * sin(TIME * pulse_speed);
	ALBEDO = color * rim * strength * pulse;
}
