shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float wave_strength : hint_range(0.0, 0.35) = 0.085;
uniform float wave_speed : hint_range(0.0, 4.0) = 0.72;
uniform float fresnel_strength : hint_range(0.0, 1.0) = 0.58;
uniform float refraction_strength : hint_range(0.0, 0.08) = 0.018;
uniform float shore_foam_strength : hint_range(0.0, 1.0) = 0.34;
uniform vec3 sky_reflection_tint : source_color = vec3(0.36, 0.56, 0.67);
uniform vec3 shore_foam_color : source_color = vec3(0.78, 0.86, 0.82);

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

	vec2 world_xz = water_world_position.xz;
	float broad = value_noise(world_xz * 0.010 + vec2(TIME * 0.018, -TIME * 0.012));
	float fine = value_noise(world_xz * 0.055 + vec2(-TIME * 0.026, TIME * 0.021));
	float micro = value_noise(world_xz * 0.19 + vec2(TIME * 0.041, TIME * 0.029));
	float wave_light = (broad - 0.5) * 0.085 + (fine - 0.5) * 0.052 + (micro - 0.5) * 0.020;

	float phase_a = (water_world_position.x + water_world_position.z * 0.71) * 0.028 + TIME * wave_speed;
	float phase_b = (water_world_position.z - water_world_position.x * 0.43) * 0.041 - TIME * wave_speed * 0.74;
	vec3 procedural_normal = normalize(vec3(
		-cos(phase_a) * 0.12 + cos(phase_b) * 0.07,
		1.0,
		-cos(phase_a) * 0.085 - cos(phase_b) * 0.14
	));
	vec3 combined_world_normal = normalize(mix(water_world_normal, procedural_normal, 0.42));
	NORMAL = normalize((VIEW_MATRIX * vec4(combined_world_normal, 0.0)).xyz);

	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, 3.6) * fresnel_strength;
	float shallow = 1.0 - smoothstep(0.34, 0.61, COLOR.a);
	float foam_noise = smoothstep(0.58, 0.82, broad * 0.62 + fine * 0.38);
	float foam = shallow * foam_noise * shore_foam_strength;

	vec2 distortion = NORMAL.xy * refraction_strength * (1.0 - fresnel) * (0.62 + fine * 0.38);
	vec2 refract_uv = clamp(SCREEN_UV + distortion, vec2(0.002), vec2(0.998));
	vec3 refracted_scene = textureLod(screen_texture, refract_uv, 0.0).rgb;

	vec3 water_color = COLOR.rgb * (1.0 + wave_light);
	water_color = mix(water_color, refracted_scene, (1.0 - COLOR.a) * 0.22);
	water_color = mix(water_color, sky_reflection_tint, fresnel);
	water_color = mix(water_color, shore_foam_color, foam);

	ALBEDO = water_color;
	ROUGHNESS = clamp(0.105 + broad * 0.09 + shallow * 0.11 + foam * 0.18, 0.08, 0.34);
	METALLIC = 0.0;
	SPECULAR = 0.48;
	ALPHA = clamp(COLOR.a + fresnel * 0.14 + foam * 0.11, 0.0, 0.86);
	EMISSION = shore_foam_color * foam * 0.035;
}
