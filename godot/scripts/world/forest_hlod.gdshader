shader_type spatial;
render_mode depth_draw_opaque, cull_back;

varying vec4 forest_style;

void vertex() {
	forest_style = INSTANCE_CUSTOM;
}

void fragment() {
	vec3 base = max(forest_style.rgb, vec3(0.02));
	float crown = 0.88 + forest_style.a * 0.16;
	ALBEDO = base * crown;
	ROUGHNESS = 0.96;
	SPECULAR = 0.12;
	METALLIC = 0.0;
}
