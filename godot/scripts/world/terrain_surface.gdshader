// Near terrain material. CPU vertex colour carries broad biome tint; UV2.x is
// moisture and UV2.y is ground-cover potential. Expensive sub-pixel procedural
// layers were removed so near terrain remains detailed without dominating GPU time.
shader_type spatial;

uniform float height_tint_strength : hint_range(0.0, 0.12) = 0.045;
uniform float slope_tint_strength : hint_range(0.0, 0.4) = 0.22;
uniform float macro_variation_strength : hint_range(0.0, 0.16) = 0.060;
uniform float rock_slope_strength : hint_range(0.0, 0.75) = 0.38;
uniform float wetness_strength : hint_range(0.0, 1.0) = 0.36;

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
	float a = hash21(cell);
	float b = hash21(cell + vec2(1.0, 0.0));
	float c = hash21(cell + vec2(0.0, 1.0));
	float d = hash21(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, blend.x), mix(c, d, blend.x), blend.y);
}

float fbm3(vec2 point) {
	float value = 0.0;
	float amplitude = 0.57;
	mat2 rotation = mat2(vec2(0.80, -0.60), vec2(0.60, 0.80));
	for (int i = 0; i < 3; i++) {
		value += value_noise(point) * amplitude;
		point = rotation * point * 2.03 + vec2(7.1, 3.7);
		amplitude *= 0.48;
	}
	return value;
}

void vertex() {
	terrain_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	terrain_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	vec2 world_xz = terrain_world_position.xz;
	float macro_noise = fbm3(world_xz * 0.00155) - 0.5;
	float fine_noise = value_noise(world_xz * 0.028) - 0.5;
	float micro_noise = value_noise(world_xz * 0.12) - 0.5;

	float moisture = clamp(UV2.x, 0.0, 1.0);
	float cover = clamp(UV2.y, 0.0, 1.0);
	float upward = clamp(abs(terrain_world_normal.y), 0.0, 1.0);
	float slope = 1.0 - upward;
	float slope_mask = smoothstep(0.05, 0.27, slope);
	float rock_mask = smoothstep(0.14, 0.43, slope) * rock_slope_strength;
	float flat_mask = 1.0 - smoothstep(0.06, 0.28, slope);
	float wet_mask = smoothstep(0.55, 0.90, moisture) * flat_mask;

	float green_bias = clamp(COLOR.g - max(COLOR.r, COLOR.b), 0.0, 0.35) * 2.8;
	float grass_mask = clamp(green_bias * 1.45 + cover * 0.36, 0.0, 1.0) * flat_mask;
	float elevation = smoothstep(-55.0, 125.0, terrain_world_position.y) - 0.5;
	float luminance = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	vec3 muted_slope = vec3(luminance) * vec3(0.95, 0.94, 0.89);
	vec3 rock_color = mix(vec3(0.34, 0.335, 0.305), vec3(0.24, 0.25, 0.24), wet_mask * 0.70);
	vec3 surface_color = mix(COLOR.rgb, muted_slope, slope_mask * slope_tint_strength);
	surface_color = mix(surface_color, rock_color, clamp(rock_mask, 0.0, 0.78));
	surface_color += vec3(-0.022, 0.036, -0.018) * (fine_noise * 0.70 + micro_noise * 0.30) * grass_mask;
	surface_color *= 1.0 + macro_noise * macro_variation_strength + elevation * height_tint_strength;
	surface_color = mix(surface_color, surface_color * vec3(0.77, 0.83, 0.81), wet_mask * wetness_strength);

	ALBEDO = surface_color;
	ROUGHNESS = clamp(0.91 - wet_mask * 0.28 - rock_mask * 0.08 + fine_noise * 0.025, 0.50, 0.97);
	METALLIC = 0.0;
	SPECULAR = mix(0.25, 0.38, wet_mask);
}
