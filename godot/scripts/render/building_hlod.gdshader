shader_type spatial;
render_mode depth_draw_opaque, cull_back;

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
}
