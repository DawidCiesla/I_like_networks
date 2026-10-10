shader_type spatial;

uniform vec3 base_color : source_color = vec3(0.35, 0.38, 0.31);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.88;
uniform float color_variation : hint_range(0.0, 0.5) = 0.14;
uniform float wind_strength : hint_range(0.0, 0.5) = 0.0;
uniform float wind_speed : hint_range(0.0, 4.0) = 0.8;

varying vec4 detail_instance;
varying float detail_height;

float hash21(vec2 point) {
	vec3 value = fract(vec3(point.xyx) * vec3(0.1031, 0.1030, 0.0973));
	value += dot(value, value.yzx + 33.33);
	return fract((value.x + value.y) * value.z);
}

void vertex() {
	detail_instance = INSTANCE_CUSTOM;
	detail_height = VERTEX.y;
	if (wind_strength > 0.0001) {
		vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float phase = world_position.x * 0.071 + world_position.z * 0.053 + detail_instance.g * 6.28318;
		float sway = sin(TIME * wind_speed + phase) * wind_strength;
		float height_mask = smoothstep(0.05, 1.2, max(detail_height, 0.0));
		VERTEX.x += sway * height_mask;
		VERTEX.z += sway * 0.43 * height_mask;
	}
}

void fragment() {
	float variation = (detail_instance.r - 0.5) * 2.0;
	float warm = (detail_instance.b - 0.5) * 2.0;
	vec3 tint = vec3(1.0 + variation * color_variation);
	tint *= vec3(1.0 + warm * 0.045, 1.0 + warm * 0.018, 1.0 - warm * 0.035);
	ALBEDO = base_color * tint;
	ROUGHNESS = clamp(roughness_value + variation * 0.035, 0.35, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.28;
	AO = 0.92;
	AO_LIGHT_AFFECT = 0.65;
}
