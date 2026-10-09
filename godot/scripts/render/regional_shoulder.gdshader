shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform vec4 gravel_color : source_color = vec4(0.42, 0.39, 0.32, 1.0);
uniform vec4 dirt_color : source_color = vec4(0.32, 0.29, 0.23, 1.0);
uniform vec4 verge_color : source_color = vec4(0.25, 0.34, 0.19, 1.0);

varying vec3 world_position;

float hash21(vec2 point) {
	vec3 value = fract(vec3(point.xyx) * vec3(0.1031, 0.1030, 0.0973));
	value += dot(value, value.yzx + 33.33);
	return fract((value.x + value.y) * value.z);
}

float noise2(vec2 point) {
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
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float edge_distance = min(UV.y, 1.0 - UV.y) * 2.0;
	float edge_blend = smoothstep(0.02, 0.30, edge_distance);
	vec2 p = world_position.xz;
	float macro = noise2(p * 0.025);
	float medium = noise2(p * 0.15);
	float fine = noise2(p * 0.78);
	float gravel = smoothstep(0.28, 0.74, medium + fine * 0.18);
	float vegetation = smoothstep(0.56, 0.84, macro + (1.0 - edge_distance) * 0.20);
	vec3 soil = mix(dirt_color.rgb, gravel_color.rgb, gravel);
	vec3 color = mix(soil, verge_color.rgb, vegetation * (1.0 - edge_distance) * 0.72);
	float tone = 0.90 + fine * 0.16;
	ALBEDO = color * tone;
	ROUGHNESS = mix(0.96, 0.84, gravel);
	SPECULAR = mix(0.14, 0.22, gravel);
	METALLIC = 0.0;
	AO = 0.94 + medium * 0.04;
	ALPHA = edge_blend * 0.96;
}
