shader_type spatial;

uniform vec4 base_color : source_color = vec4(0.22, 0.23, 0.22, 1.0);
uniform float roughness_base : hint_range(0.3, 1.0) = 0.88;
uniform float variation_strength : hint_range(0.0, 0.2) = 0.055;
uniform float aggregate_strength : hint_range(0.0, 0.2) = 0.045;

varying vec3 surface_world_position;

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

void vertex() {
	surface_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = surface_world_position.xz;
	float luminance = dot(base_color.rgb, vec3(0.299, 0.587, 0.114));
	float asphalt = 1.0 - smoothstep(0.31, 0.48, luminance);
	float macro = value_noise(p * 0.018) - 0.5;
	float medium = value_noise(p * 0.19) - 0.5;
	float fine = value_noise(p * 0.88) - 0.5;
	float speck = hash21(floor(p * 2.7)) - 0.5;
	float aggregate = medium * 0.50 + fine * 0.34 + speck * 0.16;
	float tone = 1.0 + macro * variation_strength + aggregate * aggregate_strength * mix(0.55, 1.0, asphalt);

	vec3 asphalt_cool = vec3(0.965, 0.975, 0.970);
	vec3 concrete_warm = vec3(1.025, 1.012, 0.985);
	vec3 material_tint = mix(concrete_warm, asphalt_cool, asphalt);
	ALBEDO = base_color.rgb * tone * material_tint;
	ROUGHNESS = clamp(
		roughness_base
		+ fine * 0.035
		+ mix(0.035, -0.025, asphalt),
		0.64,
		0.98
	);
	METALLIC = 0.0;
	SPECULAR = mix(0.24, 0.31, asphalt);
	AO = clamp(0.97 - max(0.0, -aggregate) * 0.07, 0.90, 1.0);
	AO_LIGHT_AFFECT = 0.42;
}
