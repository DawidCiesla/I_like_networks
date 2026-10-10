shader_type spatial;
render_mode cull_disabled;

uniform float night_strength : hint_range(0.0, 1.0) = 0.0;
uniform float emission_energy : hint_range(0.0, 8.0) = 3.2;

varying vec4 instance_style;

void vertex() {
	instance_style = INSTANCE_CUSTOM;
}

void fragment() {
	vec3 glass = vec3(0.035, 0.045, 0.055);
	vec3 light_color = max(instance_style.rgb, vec3(0.02));
	float occupancy = clamp(instance_style.a, 0.0, 1.0);
	ALBEDO = mix(glass, light_color * 0.16, night_strength * occupancy);
	ROUGHNESS = 0.28;
	SPECULAR = 0.52;
	METALLIC = 0.0;
	EMISSION = light_color * night_strength * occupancy * emission_energy;
}
