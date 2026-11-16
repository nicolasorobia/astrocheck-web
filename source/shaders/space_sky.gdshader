shader_type sky;

// Lunar space sky: stars, a sharp sun that follows DirectionalLight3D, and a sunlit Earth.

uniform float star_density : hint_range(0.0, 0.2) = 0.03;
uniform float star_scale = 350.0;
uniform float star_brightness = 2.5;
uniform vec3 earth_direction = vec3(0.4, 0.35, -0.85);
uniform float earth_size : hint_range(0.005, 0.3) = 0.035; // angular radius in radians
uniform vec3 earth_color : source_color = vec3(0.15, 0.4, 0.9);
uniform float sun_size : hint_range(0.0001, 0.01) = 0.0025;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

void sky() {
	vec3 col = vec3(0.0);

	// --- Stars (no twinkle: there's no atmosphere on the Moon) ---
	vec3 p = EYEDIR * star_scale;
	vec3 cell = floor(p);
	float h = hash(cell);
	if (h > 1.0 - star_density) {
		float d = length(p - (cell + 0.5));
		float b = pow(hash(cell + 7.0), 4.0) * star_brightness;
		vec3 tint = mix(vec3(1.0, 0.85, 0.7), vec3(0.7, 0.8, 1.0), hash(cell + 3.0));
		col += tint * b * smoothstep(0.35, 0.0, d);
	}

	// --- Sun (follows DirectionalLight3D) ---
	if (LIGHT0_ENABLED) {
		float s = acos(clamp(dot(EYEDIR, LIGHT0_DIRECTION), -1.0, 1.0));
		col += LIGHT0_COLOR * LIGHT0_ENERGY * 30.0 * smoothstep(sun_size, sun_size * 0.8, s);
		col += LIGHT0_COLOR * 0.15 * exp(-s * 60.0); // small halo for glow
	}

	// --- Earth ---
	vec3 ed = normalize(earth_direction);
	float ang = acos(clamp(dot(EYEDIR, ed), -1.0, 1.0));
	if (ang < earth_size) {
		vec3 right = normalize(cross(ed, vec3(0.0, 1.0, 0.0)));
		vec3 up = cross(right, ed);
		vec2 uv = vec2(dot(EYEDIR, right), dot(EYEDIR, up)) / sin(earth_size);
		float z = sqrt(max(1.0 - dot(uv, uv), 0.0));
		vec3 n = uv.x * right + uv.y * up - ed * z;
		float lit = LIGHT0_ENABLED ? max(dot(n, LIGHT0_DIRECTION), 0.0) : 1.0;
		vec3 earth = earth_color * lit + vec3(0.4, 0.6, 1.0) * pow(1.0 - z, 3.0) * lit;
		col = mix(col, earth, smoothstep(earth_size, earth_size * 0.97, ang));
	}

	COLOR = col;
}
