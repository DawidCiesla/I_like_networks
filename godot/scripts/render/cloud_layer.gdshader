shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform vec4 cloud_tint : source_color = vec4(0.92, 0.94, 0.96, 1.0);
uniform float coverage : hint_range(0.0, 1.0) = 0.52;
uniform float opacity : hint_range(0.0, 1.0) = 0.48;
uniform float noise_scale : hint_range(0.5, 20.0) = 5.0;
uniform vec2 wind_direction = vec2(0.78, 0.36);
uniform float wind_speed : hint_range(0.0, 0.1) = 0.006;
uniform float layer_phase = 0.0;

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

// These layers cover most of the viewport. Three broad octaves preserve the
// cloud silhouette while avoiding the previous ten noise-octave evaluations
// per fragment (5 broad + 5 wisps) on two transparent full-screen layers.
float fbm_fast(vec2 point) {
	float sum = 0.0;
	float amplitude = 0.58;
	float normalization = 0.0;
	for (int octave = 0; octave < 3; octave++) {
		sum += value_noise(point) * amplitude;
		normalization += amplitude;
		point = point * 2.03 + vec2(17.3, 9.1);
		amplitude *= 0.46;
	}
	return sum / max(normalization, 0.001);
}

void fragment() {
	vec2 wind = normalize(wind_direction + vec2(0.0001)) * TIME * wind_speed;
	vec2 p = UV * noise_scale + wind + vec2(layer_phase, layer_phase * 0.57);
	float broad = fbm_fast(p);
	float wisps = value_noise(p * 2.35 + vec2(4.1, -2.8));
	float density = broad * 0.82 + wisps * 0.18;
	float threshold = mix(0.68, 0.30, coverage);
	float cloud = smoothstep(threshold, threshold + 0.17, density);
	float inner = smoothstep(threshold + 0.08, threshold + 0.28, density);
	vec3 shade = cloud_tint.rgb * mix(0.72, 1.08, inner);
	ALBEDO = shade;
	EMISSION = shade * 0.08;
	ALPHA = cloud * opacity;
}
