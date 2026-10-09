extends Node3D
class_name CloudLayerRenderer

const CloudShader = preload("res://scripts/render/cloud_layer.gdshader")

const LAYER_SIZE := Vector2(30000.0, 30000.0)
const LOW_ALTITUDE := 900.0
const HIGH_ALTITUDE := 1320.0

var _store: Node
var _low_layer: MeshInstance3D
var _high_layer: MeshInstance3D
var _low_material: ShaderMaterial
var _high_material: ShaderMaterial
var _last_hour := -100.0
var _last_weather_phase := -100.0


func _ready() -> void:
	_store = get_node_or_null("/root/GameStore")
	_create_layers()
	_update_layers(true)


func _process(_delta: float) -> void:
	_follow_camera()
	_update_layers(false)


func _create_layers() -> void:
	_low_material = _make_material(0.49, 0.50, 5.2, Vector2(0.82, 0.31), 0.0)
	_high_material = _make_material(0.43, 0.32, 7.8, Vector2(0.54, 0.69), 13.7)
	_low_layer = _make_layer("CloudLayerLow", _low_material)
	_high_layer = _make_layer("CloudLayerHigh", _high_material)
	add_child(_low_layer)
	add_child(_high_layer)


func _make_layer(instance_name: String, material: ShaderMaterial) -> MeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = LAYER_SIZE
	mesh.subdivide_width = 1
	mesh.subdivide_depth = 1
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.name = instance_name
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _make_material(
	coverage: float,
	opacity: float,
	noise_scale: float,
	wind: Vector2,
	phase: float
) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = CloudShader
	material.set_shader_parameter("coverage", coverage)
	material.set_shader_parameter("opacity", opacity)
	material.set_shader_parameter("noise_scale", noise_scale)
	material.set_shader_parameter("wind_direction", wind)
	material.set_shader_parameter("layer_phase", phase)
	return material


func _follow_camera() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var camera_position := camera.global_position
	_low_layer.global_position = Vector3(camera_position.x, camera_position.y + LOW_ALTITUDE, camera_position.z)
	_high_layer.global_position = Vector3(camera_position.x, camera_position.y + HIGH_ALTITUDE, camera_position.z)


func _update_layers(force: bool) -> void:
	if _store == null:
		_store = get_node_or_null("/root/GameStore")
	if _store == null or _low_material == null or _high_material == null:
		return
	var city_value: Variant = _store.get("city")
	if typeof(city_value) != TYPE_DICTIONARY:
		return
	var city: Dictionary = city_value
	var simulation_seconds := maxf(0.0, float(city.get("time_seconds", 0.0)))
	var hour := fposmod(8.0 + simulation_seconds / 3600.0, 24.0)
	var seed := int(_store.get("city_seed"))
	var weather_phase := sin(simulation_seconds / 2400.0 + float(posmod(seed, 997)) * 0.017)
	if not force and absf(hour - _last_hour) < 0.04 and absf(weather_phase - _last_weather_phase) < 0.02:
		return
	_last_hour = hour
	_last_weather_phase = weather_phase

	var tint := _cloud_tint(hour)
	var overcast := clampf(0.5 + weather_phase * 0.5, 0.0, 1.0)
	_low_material.set_shader_parameter("cloud_tint", tint)
	_high_material.set_shader_parameter("cloud_tint", tint.lerp(Color(0.92, 0.95, 1.0), 0.12))
	_low_material.set_shader_parameter("coverage", lerpf(0.41, 0.64, overcast))
	_high_material.set_shader_parameter("coverage", lerpf(0.34, 0.52, overcast))
	_low_material.set_shader_parameter("opacity", lerpf(0.36, 0.58, overcast))
	_high_material.set_shader_parameter("opacity", lerpf(0.20, 0.38, overcast))


func _cloud_tint(hour: float) -> Color:
	if hour < 5.5 or hour >= 20.5:
		return Color(0.23, 0.28, 0.39)
	if hour < 7.4:
		var blend := smoothstep(5.5, 7.4, hour)
		return Color(0.58, 0.37, 0.34).lerp(Color(0.91, 0.91, 0.89), blend)
	if hour < 17.2:
		return Color(0.94, 0.95, 0.95)
	if hour < 20.5:
		var blend := smoothstep(17.2, 20.5, hour)
		return Color(0.95, 0.91, 0.86).lerp(Color(0.40, 0.28, 0.34), blend)
	return Color(0.23, 0.28, 0.39)
