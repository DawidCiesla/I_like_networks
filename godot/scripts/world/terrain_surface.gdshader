// Procedural PBR terrain material for the 24 km regional landscape.
// CPU vertex colour carries the broad biome tint. UV2 carries material metadata:
// UV2.x = moisture, UV2.y = ground-cover potential.
shader_type spatial;

uniform float grain_strength : hint_range(0.0, 0.12) = 0.046;
uniform float height_tint_strength : hint_range(0.0, 0.12) = 0.052;
uniform float slope_tint_strength : hint_range(0.0, 0.4) = 0.24;
uniform float macro_variation_strength : hint_range(0.0, 0.16) = 0.075;
uniform float micro_variation_strength : hint_range(0.0, 0.12) = 0.055;
uniform float rock_slope_strength : hint_range(0.0, 0.75) = 0.42;
uniform float micro_normal_strength : hint_range(0.0, 0.8) = 0.32;
uniform float wetness_strength : hint_range(0.0, 1.0) = 0.44;
uniform float cavity_strength : hint_range(0.0, 0.8) = 0.26;

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

float remap01(float edge_low, float edge_high, float value) {
	return smoothstep(edge_low, edge_high, value);
}

void vertex() {
	terrain_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	terrain_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	vec2 world_xz = terrain_world_position.xz;
	float macro_noise = fbm4(world_xz * 0.00135) - 0.5;
	float broad_noise = fbm4(world_xz * 0.0048) - 0.5;
	float medium_noise = value_noise(world_xz * 0.015) - 0.5;
	float fine_noise = value_noise(world_xz * 0.075) - 0.5;
	float micro_noise = value_noise(world_xz * 0.31) - 0.5;
	float pebble_noise = value_noise(world_xz * 0.72) - 0.5;

	float moisture = clamp(UV2.x, 0.0, 1.0);
	float cover = clamp(UV2.y, 0.0, 1.0);
	float upward = clamp(abs(terrain_world_normal.y), 0.0, 1.0);
	float slope = 1.0 - upward;
	float slope_mask = smoothstep(0.045, 0.26, slope);
	float rock_mask = smoothstep(0.13, 0.43, slope) * rock_slope_strength;
	float flat_mask = 1.0 - smoothstep(0.05, 0.28, slope);

	float green_bias = clamp(COLOR.g - max(COLOR.r, COLOR.b), 0.0, 0.35) * 2.8;
	float grass_mask = clamp(green_bias * 1.55 + cover * 0.42, 0.0, 1.0) * flat_mask;
	float soil_mask = clamp((1.0 - grass_mask) * flat_mask * (0.62 + moisture * 0.28), 0.0, 1.0);
	float wet_mask = clamp(remap01(0.54, 0.92, moisture) * flat_mask * (0.62 + cover * 0.20), 0.0, 1.0);

	float grain = medium_noise * 0.42 + fine_noise * 0.34 + micro_noise * 0.18 + pebble_noise * 0.06;
	float grain_tint = 1.0 + grain * grain_strength;
	float macro_tint = 1.0 + (macro_noise * 0.74 + broad_noise * 0.26) * macro_variation_strength;
	float micro_tint = 1.0 + (fine_noise * 0.54 + micro_noise * 0.34 + pebble_noise * 0.12) * micro_variation_strength;

	float elevation = smoothstep(-55.0, 125.0, terrain_world_position.y) - 0.5;
	float height_tint = 1.0 + elevation * height_tint_strength;
	float biome_luminance = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	vec3 muted_slope_color = vec3(biome_luminance) * vec3(0.95, 0.94, 0.88);
	vec3 dry_rock = vec3(0.34, 0.335, 0.305);
	vec3 wet_rock = vec3(0.235, 0.245, 0.235);
	vec3 rock_color = mix(dry_rock, wet_rock, wet_mask * 0.72) * (0.91 + medium_noise * 0.12);
	vec3 surface_color = mix(COLOR.rgb, muted_slope_color, slope_mask * slope_tint_strength);
	surface_color = mix(surface_color, rock_color, clamp(rock_mask, 0.0, 0.82));

	vec3 grass_variation = vec3(-0.030, 0.050, -0.025) * (fine_noise * 0.72 + micro_noise * 0.28) * grass_mask;
	vec3 soil_variation = vec3(0.050, 0.020, -0.018) * broad_noise * soil_mask;
	surface_color += grass_variation + soil_variation;

	// Damp ground is darker and slightly more saturated, creating visually
	// readable floodplains and river-adjacent soil without a texture atlas.
	vec3 damp_color = surface_color * vec3(0.76, 0.82, 0.80);
	surface_color = mix(surface_color, damp_color, wet_mask * wetness_strength);

	// Procedural close-range micro-normal on flatter surfaces. The world-space
	// gradient is transformed to view space before feeding Godot's lighting model.
	float normal_scale = 0.43;
	float normal_step = 0.36;
	float center_h = value_noise(world_xz * normal_scale);
	float x_h = value_noise((world_xz + vec2(normal_step, 0.0)) * normal_scale);
	float z_h = value_noise((world_xz + vec2(0.0, normal_step)) * normal_scale);
	vec3 detail_world_normal = normalize(vec3((center_h - x_h) * 1.9, 1.0, (center_h - z_h) * 1.9));
	vec3 blended_world_normal = normalize(mix(terrain_world_normal, detail_world_normal, micro_normal_strength * flat_mask));
	NORMAL = normalize((VIEW_MATRIX * vec4(blended_world_normal, 0.0)).xyz);

	float cavity_noise = clamp(0.5 - (fine_noise * 0.58 + micro_noise * 0.42), 0.0, 1.0);
	float cavity = cavity_noise * cavity_strength * (0.45 + rock_mask * 0.55);

	ALBEDO = surface_color * grain_tint * macro_tint * micro_tint * height_tint;
	ROUGHNESS = clamp(
		0.91
		- wet_mask * 0.34
		- rock_mask * 0.10
		+ fine_noise * 0.035
		+ grass_mask * 0.035,
		0.44,
		0.98
	);
	METALLIC = 0.0;
	SPECULAR_IOR_LEVEL = mix(0.26, 0.42, wet_mask);
	AO = clamp(1.0 - cavity, 0.68, 1.0);
	AO_LIGHT_AFFECT = 0.72;
}
