shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec3 dry_grass_color : source_color = vec3(0.43, 0.46, 0.19);
uniform vec3 lush_grass_color : source_color = vec3(0.17, 0.34, 0.10);
uniform float wind_strength : hint_range(0.0, 0.35) = 0.11;
uniform float wind_speed : hint_range(0.0, 4.0) = 1.15;
uniform float color_variation : hint_range(0.0, 0.35) = 0.12;

varying vec4 grass_instance_data;
varying vec3 grass_world_position;

float hash21(vec2 point) {
	vec3 value = fract(vec3(point.xyx) * vec3(0.1031, 0.1030, 0.0973));
	value += dot(value, value.yzx + 33.33);
	return fract((value.x + value.y) * value.z);
}

void vertex() {
	grass_instance_data = INSTANCE_CUSTOM;
	grass_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float phase = INSTANCE_CUSTOM.y * 6.2831853;
	float gust = sin(TIME * wind_speed + phase + grass_world_position.x * 0.018 + grass_world_position.z * 0.013);
	float secondary = sin(TIME * wind_speed * 0.63 + phase * 1.7 + grass_world_position.z * 0.027);
	float bend = (gust * 0.72 + secondary * 0.28) * wind_strength * UV.y;
	VERTEX.x += bend;
	VERTEX.z += bend * 0.42;
}

void fragment() {
	float moisture = clamp(grass_instance_data.z, 0.0, 1.0);
	float tint = clamp(grass_instance_data.x, 0.0, 1.0);
	vec3 base = mix(dry_grass_color, lush_grass_color, moisture);
	float macro = hash21(floor(grass_world_position.xz * 0.12));
	float brightness = 1.0 + (tint - 0.5) * color_variation + (macro - 0.5) * 0.045;
	ALBEDO = base * brightness;
	ROUGHNESS = 0.94;
	METALLIC = 0.0;
}
