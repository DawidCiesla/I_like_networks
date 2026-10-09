// Procedural terrain material tuned for large-scale regional landscapes.
// Vertex colour carries the CPU biome blend; this shader adds multi-scale surface
// variation, slope rock and material roughness without requiring texture assets.
shader_type spatial;

uniform float grain_strength : hint_range(0.0, 0.12) = 0.046;
uniform float height_tint_strength : hint_range(0.0, 0.12) = 0.052;
uniform float slope_tint_strength : hint_range(0.0, 0.4) = 0.24;
uniform float macro_variation_strength : hint_range(0.0, 0.16) = 0.075;
uniform float micro_variation_strength : hint_range(0.0, 0.12) = 0.055;
uniform float rock_slope_strength : hint_range(0.0, 0.75) = 0.42;

varying vec3 terrain_world_position;
varying vec3 terrain_world_normal;

float hash21(vec2 point) {
	vec3 value = fract(vec3(point.xyx) * vec3(0.1031, 0.1030, 0.0973));
	value += dot(value, value.yzx + 33.33);
	return fract((value.x + value.y) * value.z);
}

float value_noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 blend = fract(point);
	blend = blend * blend * (3.0 - 2.0 * blend);
	float southwest = hash21(cell);
	float southeast = hash21(cell + vec2(1.0, 0.0));
	float northwest = hash21(cell + vec2(0.0, 1.0));
	float northeast = hash21(cell + vec2(1.0, 1.0));
	return mix(mix(southwest, southeast, blend.x), mix(northwest, northeast, blend.x), blend.y);
}

float fbm4(vec2 point) {
	float value = 0.0;
	float amplitude = 0.53;
	mat2 rotation = mat2(vec2(0.80, -0.60), vec2(0.60, 0.80));
	for (int i = 0; i < 4; i++) {
		value += value_noise(point) * amplitude;
		point = rotation * point * 2.03 + vec2(7.1, 3.7);
		amplitude *= 0.49;
	}
	return value;
}

void vertex() {
	terrain_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	terrain_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	vec2 world_xz = terrain_world_position.xz;
	float macro_noise = fbm4(world_xz * 0.00155) - 0.5;
	float medium_noise = value_noise(world_xz * 0.015) - 0.5;
	float fine_noise = value_noise(world_xz * 0.075) - 0.5;
	float micro_noise = value_noise(world_xz * 0.22) - 0.5;

	float grain = medium_noise * 0.48 + fine_noise * 0.34 + micro_noise * 0.18;
	float grain_tint = 1.0 + grain * grain_strength;
	float macro_tint = 1.0 + macro_noise * macro_variation_strength;
	float micro_tint = 1.0 + (fine_noise * 0.62 + micro_noise * 0.38) * micro_variation_strength;

	float elevation = smoothstep(-55.0, 125.0, terrain_world_position.y) - 0.5;
	float height_tint = 1.0 + elevation * height_tint_strength;

	float upward = clamp(abs(terrain_world_normal.y), 0.0, 1.0);
	float slope = 1.0 - upward;
	float slope_mask = smoothstep(0.045, 0.26, slope);
	float rock_mask = smoothstep(0.13, 0.43, slope) * rock_slope_strength;
	float biome_luminance = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	vec3 muted_slope_color = vec3(biome_luminance) * vec3(0.95, 0.94, 0.88);
	vec3 rock_color = vec3(0.34, 0.335, 0.305) * (0.91 + medium_noise * 0.12);
	vec3 surface_color = mix(COLOR.rgb, muted_slope_color, slope_mask * slope_tint_strength);
	surface_color = mix(surface_color, rock_color, clamp(rock_mask, 0.0, 0.78));

	// Meadow/grass surfaces get a very subtle high-frequency breakup at close
	// range while rock remains visually heavier and less saturated.
	float green_bias = clamp(COLOR.g - max(COLOR.r, COLOR.b), 0.0, 0.35) * 2.8;
	vec3 grass_variation = vec3(-0.02, 0.035, -0.018) * fine_noise * green_bias;
	surface_color += grass_variation;

	ALBEDO = surface_color * grain_tint * macro_tint * micro_tint * height_tint;
	ROUGHNESS = clamp(0.84 + fine_noise * 0.06 + rock_mask * 0.08, 0.74, 1.0);
	METALLIC = 0.0;
}
