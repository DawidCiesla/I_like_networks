shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec3 dry_grass_color : source_color = vec3(0.38, 0.43, 0.16);
uniform vec3 lush_grass_color : source_color = vec3(0.12, 0.31, 0.075);
uniform float wind_strength : hint_range(0.0, 0.35) = 0.10;
uniform float wind_speed : hint_range(0.0, 4.0) = 1.05;
uniform float color_variation : hint_range(0.0, 0.35) = 0.15;

varying vec4 grass_instance_data;
varying vec3 grass_world_position;
varying float blade_height_mask;

float hash21(vec2 point) {
	vec3 value = fract(vec3(point.xyx) * vec3(0.1031, 0.1030, 0.0973));
	value += dot(value, value.yzx + 33.33);
	return fract((value.x + value.y) * value.z);
}

void vertex() {
	grass_instance_data = INSTANCE_CUSTOM;
	grass_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	blade_height_mask = clamp(UV.y, 0.0, 1.0);
	float phase = INSTANCE_CUSTOM.y * 6.2831853;
	float gust = sin(TIME * wind_speed + phase + grass_world_position.x * 0.018 + grass_world_position.z * 0.013);
	float secondary = sin(TIME * wind_speed * 0.63 + phase * 1.7 + grass_world_position.z * 0.027);
	float broad_gust = sin(TIME * wind_speed * 0.31 + grass_world_position.x * 0.004 + grass_world_position.z * 0.005);
	float bend = (gust * 0.56 + secondary * 0.25 + broad_gust * 0.19) * wind_strength * UV.y * UV.y;
	VERTEX.x += bend;
	VERTEX.z += bend * 0.42;
}

void fragment() {
	float moisture = clamp(grass_instance_data.z, 0.0, 1.0);
	float tint = clamp(grass_instance_data.x, 0.0, 1.0);
	vec3 base = mix(dry_grass_color, lush_grass_color, smoothstep(0.18, 0.86, moisture));
	float macro = hash21(floor(grass_world_position.xz * 0.11));
	float micro = hash21(floor(grass_world_position.xz * 0.83));
	float brightness = 1.0 + (tint - 0.5) * color_variation + (macro - 0.5) * 0.055 + (micro - 0.5) * 0.025;
	float root_darkening = mix(0.72, 1.0, smoothstep(0.0, 0.72, blade_height_mask));
	float tip_sun_bleach = smoothstep(0.70, 1.0, blade_height_mask) * (1.0 - moisture) * 0.08;
	vec3 tip_color = vec3(0.65, 0.68, 0.28);
	vec3 color = base * brightness * root_darkening;
	color = mix(color, tip_color, tip_sun_bleach);

	ALBEDO = color;
	ROUGHNESS = clamp(0.96 - moisture * 0.10 + (micro - 0.5) * 0.025, 0.78, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.24;
	AO = mix(0.82, 0.98, blade_height_mask);
	AO_LIGHT_AFFECT = 0.56;
}
