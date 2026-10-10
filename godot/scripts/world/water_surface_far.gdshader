// Far-water material: no screen texture/refraction and no procedural fragment noise.
shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform float wave_strength : hint_range(0.0, 0.2) = 0.035;
uniform float wave_speed : hint_range(0.0, 4.0) = 0.52;
uniform vec3 sky_reflection_tint : source_color = vec3(0.32, 0.52, 0.64);

varying vec3 water_world_position;
varying vec3 water_world_normal;

void vertex() {
	water_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	water_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
	float wave = sin((water_world_position.x + water_world_position.z * 0.73) * 0.018 + TIME * wave_speed);
	VERTEX.y += wave * wave_strength * COLOR.a;
}

void fragment() {
	if (COLOR.a <= 0.001) {
		discard;
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(water_world_normal, 0.0)).xyz);
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, 3.0) * 0.42;
	vec3 water_color = mix(COLOR.rgb, sky_reflection_tint, fresnel);
	ALBEDO = water_color;
	ROUGHNESS = 0.20;
	METALLIC = 0.0;
	SPECULAR = 0.38;
	ALPHA = clamp(COLOR.a + fresnel * 0.10, 0.0, 0.78);
}
