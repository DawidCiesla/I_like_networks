shader_type spatial;
render_mode depth_draw_opaque, cull_back;

uniform float night_strength : hint_range(0.0, 1.0) = 0.0;
uniform float skyline_emission : hint_range(0.0, 4.0) = 0.62;

varying vec4 instance_style;

void vertex() {
	instance_style = INSTANCE_CUSTOM;
}

void fragment() {
	vec3 tint = max(instance_style.rgb, vec3(0.02));
	float variation = 0.94 + instance_style.a * 0.10;
	ALBEDO = tint * variation;
	ROUGHNESS = 0.88;
	SPECULAR = 0.22;
	METALLIC = 0.0;
	float occupancy = smoothstep(0.18, 0.92, instance_style.a);
	vec3 warm_city_light = mix(vec3(1.0, 0.58, 0.28), vec3(0.72, 0.84, 1.0), instance_style.a * 0.42);
	EMISSION = warm_city_light * night_strength * occupancy * skyline_emission;
}
