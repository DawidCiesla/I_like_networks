// GL Compatibility-friendly terrain material: no textures, derivatives, or renderer-specific features.
// Keep its noise broad and low-contrast; it shades the entire opaque terrain surface.
shader_type spatial;

uniform float grain_strength : hint_range(0.0, 0.08) = 0.034;
uniform float height_tint_strength : hint_range(0.0, 0.08) = 0.035;
uniform float slope_tint_strength : hint_range(0.0, 0.3) = 0.16;

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

void vertex() {
	terrain_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	terrain_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	vec2 world_xz = terrain_world_position.xz;
	float broad_grain = value_noise(world_xz * 0.017);
	float fine_grain = value_noise(world_xz * 0.061);
	float grain = (broad_grain - 0.5) * 0.72 + (fine_grain - 0.5) * 0.28;
	float grain_tint = 1.0 + grain * grain_strength;

	float elevation = smoothstep(-24.0, 84.0, terrain_world_position.y) - 0.5;
	float height_tint = 1.0 + elevation * height_tint_strength;

	float slope = 1.0 - clamp(abs(terrain_world_normal.y), 0.0, 1.0);
	float slope_mask = smoothstep(0.035, 0.24, slope);
	float biome_luminance = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	vec3 muted_slope_color = vec3(biome_luminance) * vec3(0.97, 0.97, 0.93);
	vec3 slope_tint = mix(COLOR.rgb, muted_slope_color, slope_mask * slope_tint_strength);

	ALBEDO = slope_tint * grain_tint * height_tint;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
