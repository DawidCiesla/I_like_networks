// Medium-distance terrain material. Keeps biome/slope readability while avoiding
// near-field micro detail that is sub-pixel at kilometre camera distances.
shader_type spatial;

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

float fbm2(vec2 point) {
	float first = value_noise(point) * 0.67;
	float second = value_noise(point * 2.07 + vec2(5.7, 2.9)) * 0.33;
	return first + second;
}

void vertex() {
	terrain_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	terrain_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	float macro_noise = fbm2(terrain_world_position.xz * 0.0018) - 0.5;
	float moisture = clamp(UV2.x, 0.0, 1.0);
	float upward = clamp(abs(terrain_world_normal.y), 0.0, 1.0);
	float slope = 1.0 - upward;
	float slope_mask = smoothstep(0.06, 0.30, slope);
	float rock_mask = smoothstep(0.16, 0.46, slope);
	float wet_mask = smoothstep(0.58, 0.90, moisture) * (1.0 - slope_mask * 0.45);
	float elevation = smoothstep(-55.0, 125.0, terrain_world_position.y) - 0.5;

	float luminance = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	vec3 slope_color = vec3(luminance) * vec3(0.95, 0.94, 0.89);
	vec3 rock_color = mix(vec3(0.35, 0.345, 0.315), vec3(0.25, 0.26, 0.25), wet_mask);
	vec3 surface_color = mix(COLOR.rgb, slope_color, slope_mask * 0.20);
	surface_color = mix(surface_color, rock_color, rock_mask * 0.33);
	surface_color *= 1.0 + macro_noise * 0.055 + elevation * 0.035;
	surface_color = mix(surface_color, surface_color * vec3(0.80, 0.85, 0.83), wet_mask * 0.22);

	ALBEDO = surface_color;
	ROUGHNESS = clamp(0.90 - wet_mask * 0.20 - rock_mask * 0.05, 0.58, 0.96);
	METALLIC = 0.0;
	SPECULAR = mix(0.24, 0.34, wet_mask);
}
