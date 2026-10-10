// Far terrain material: intentionally almost free. At multi-kilometre ranges
// CPU-provided biome colour and the mesh normal carry all visible information.
shader_type spatial;

varying vec3 terrain_world_position;
varying vec3 terrain_world_normal;

void vertex() {
	terrain_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	terrain_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	float slope = 1.0 - clamp(abs(terrain_world_normal.y), 0.0, 1.0);
	float slope_mask = smoothstep(0.08, 0.36, slope);
	float elevation = smoothstep(-60.0, 145.0, terrain_world_position.y) - 0.5;
	float luminance = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	vec3 muted_slope = vec3(luminance) * vec3(0.96, 0.95, 0.91);
	vec3 surface_color = mix(COLOR.rgb, muted_slope, slope_mask * 0.16);
	surface_color *= 1.0 + elevation * 0.025;
	ALBEDO = surface_color;
	ROUGHNESS = 0.91;
	METALLIC = 0.0;
	SPECULAR = 0.22;
}
