shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform float wave_strength : hint_range(0.0, 0.35) = 0.085;
uniform float wave_speed : hint_range(0.0, 4.0) = 0.72;
uniform float fresnel_strength : hint_range(0.0, 1.0) = 0.42;
uniform vec3 sky_reflection_tint : source_color = vec3(0.36, 0.56, 0.67);

varying vec3 water_world_position;
varying vec3 water_world_normal;

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
	water_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	water_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
	float wave_a = sin((water_world_position.x + water_world_position.z * 0.71) * 0.028 + TIME * wave_speed);
	float wave_b = sin((water_world_position.z - water_world_position.x * 0.43) * 0.041 - TIME * wave_speed * 0.74);
	VERTEX.y += (wave_a * 0.62 + wave_b * 0.38) * wave_strength * COLOR.a;
}

void fragment() {
	if (COLOR.a <= 0.001) {
		discard;
	}
	float broad = value_noise(water_world_position.xz * 0.010 + vec2(TIME * 0.018, -TIME * 0.012));
	float fine = value_noise(water_world_position.xz * 0.055 + vec2(-TIME * 0.026, TIME * 0.021));
	float wave_light = (broad - 0.5) * 0.10 + (fine - 0.5) * 0.055;
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, 3.0) * fresnel_strength;
	vec3 water_color = COLOR.rgb * (1.0 + wave_light);
	water_color = mix(water_color, sky_reflection_tint, fresnel);
	ALBEDO = water_color;
	ROUGHNESS = clamp(0.16 + broad * 0.12, 0.12, 0.32);
	METALLIC = 0.0;
	ALPHA = clamp(COLOR.a + fresnel * 0.16, 0.0, 0.82);
}
