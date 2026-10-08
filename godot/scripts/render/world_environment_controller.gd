extends Node3D
class_name WorldEnvironmentController

@export_node_path("DirectionalLight3D") var sun_path: NodePath = ^"../Sun"
@export_node_path("DirectionalLight3D") var fill_light_path: NodePath = ^"../FillLight"
@export_range(0.0, 24.0, 0.01, "or_greater") var initial_time_of_day := 14.5
@export_range(0.0, 24.0, 0.01, "or_greater") var auto_advance_hours_per_second := 0.0

const PROFILE_STOPS := [
	{
		"hour": 0.0,
		"sun_rotation_degrees": Vector3(-14.0, 90.0, 0.0),
		"sun_color": Color(0.34, 0.43, 0.66), "sun_energy": 0.0,
		"fill_color": Color(0.57, 0.69, 1.0), "fill_energy": 0.22,
		"sky_top_color": Color(0.025, 0.045, 0.10), "sky_horizon_color": Color(0.10, 0.14, 0.24),
		"ground_bottom_color": Color(0.025, 0.035, 0.055), "ground_horizon_color": Color(0.08, 0.10, 0.15),
		"ambient_color": Color(0.34, 0.40, 0.58), "ambient_energy": 0.78,
		"fog_color": Color(0.065, 0.085, 0.14), "fog_density": 0.00020,
	},
	{
		"hour": 5.0,
		"sun_rotation_degrees": Vector3(-5.0, 90.0, 0.0),
		"sun_color": Color(0.55, 0.43, 0.56), "sun_energy": 0.06,
		"fill_color": Color(0.62, 0.70, 0.95), "fill_energy": 0.24,
		"sky_top_color": Color(0.075, 0.12, 0.23), "sky_horizon_color": Color(0.30, 0.25, 0.34),
		"ground_bottom_color": Color(0.035, 0.045, 0.07), "ground_horizon_color": Color(0.15, 0.13, 0.17),
		"ambient_color": Color(0.34, 0.35, 0.48), "ambient_energy": 0.76,
		"fog_color": Color(0.17, 0.16, 0.22), "fog_density": 0.00024,
	},
	{
		"hour": 6.5,
		"sun_rotation_degrees": Vector3(-18.0, 90.0, 0.0),
		"sun_color": Color(1.0, 0.52, 0.29), "sun_energy": 0.62,
		"fill_color": Color(0.63, 0.69, 0.88), "fill_energy": 0.25,
		"sky_top_color": Color(0.16, 0.28, 0.47), "sky_horizon_color": Color(0.94, 0.48, 0.31),
		"ground_bottom_color": Color(0.06, 0.075, 0.10), "ground_horizon_color": Color(0.32, 0.24, 0.20),
		"ambient_color": Color(0.52, 0.40, 0.34), "ambient_energy": 0.76,
		"fog_color": Color(0.68, 0.39, 0.29), "fog_density": 0.00030,
	},
	{
		"hour": 8.0,
		"sun_rotation_degrees": Vector3(-38.0, 58.0, 0.0),
		"sun_color": Color(1.0, 0.80, 0.61), "sun_energy": 1.02,
		"fill_color": Color(0.62, 0.76, 1.0), "fill_energy": 0.20,
		"sky_top_color": Color(0.27, 0.48, 0.74), "sky_horizon_color": Color(0.72, 0.81, 0.88),
		"ground_bottom_color": Color(0.13, 0.18, 0.20), "ground_horizon_color": Color(0.49, 0.52, 0.50),
		"ambient_color": Color(0.55, 0.65, 0.76), "ambient_energy": 0.72,
		"fog_color": Color(0.64, 0.72, 0.77), "fog_density": 0.00010,
	},
	{
		"hour": 12.0,
		"sun_rotation_degrees": Vector3(-67.0, 0.0, 0.0),
		"sun_color": Color(1.0, 0.92, 0.78), "sun_energy": 1.16,
		"fill_color": Color(0.60, 0.74, 1.0), "fill_energy": 0.16,
		"sky_top_color": Color(0.23, 0.44, 0.72), "sky_horizon_color": Color(0.69, 0.80, 0.89),
		"ground_bottom_color": Color(0.14, 0.19, 0.21), "ground_horizon_color": Color(0.48, 0.52, 0.52),
		"ambient_color": Color(0.56, 0.68, 0.80), "ambient_energy": 0.74,
		"fog_color": Color(0.62, 0.72, 0.79), "fog_density": 0.00007,
	},
	{
		"hour": 16.0,
		"sun_rotation_degrees": Vector3(-38.0, -58.0, 0.0),
		"sun_color": Color(1.0, 0.77, 0.54), "sun_energy": 1.04,
		"fill_color": Color(0.64, 0.75, 0.98), "fill_energy": 0.18,
		"sky_top_color": Color(0.26, 0.41, 0.65), "sky_horizon_color": Color(0.78, 0.68, 0.59),
		"ground_bottom_color": Color(0.12, 0.16, 0.19), "ground_horizon_color": Color(0.43, 0.40, 0.38),
		"ambient_color": Color(0.55, 0.58, 0.65), "ambient_energy": 0.70,
		"fog_color": Color(0.62, 0.61, 0.59), "fog_density": 0.00008,
	},
	{
		"hour": 18.0,
		"sun_rotation_degrees": Vector3(-14.0, -90.0, 0.0),
		"sun_color": Color(1.0, 0.50, 0.26), "sun_energy": 0.72,
		"fill_color": Color(0.63, 0.68, 0.91), "fill_energy": 0.22,
		"sky_top_color": Color(0.19, 0.29, 0.48), "sky_horizon_color": Color(0.92, 0.43, 0.30),
		"ground_bottom_color": Color(0.065, 0.08, 0.11), "ground_horizon_color": Color(0.30, 0.21, 0.19),
		"ambient_color": Color(0.49, 0.37, 0.34), "ambient_energy": 0.72,
		"fog_color": Color(0.68, 0.36, 0.28), "fog_density": 0.00029,
	},
	{
		"hour": 19.5,
		"sun_rotation_degrees": Vector3(-5.0, -90.0, 0.0),
		"sun_color": Color(0.63, 0.60, 0.92), "sun_energy": 0.18,
		"fill_color": Color(0.51, 0.63, 1.0), "fill_energy": 0.25,
		"sky_top_color": Color(0.065, 0.11, 0.25), "sky_horizon_color": Color(0.34, 0.26, 0.39),
		"ground_bottom_color": Color(0.035, 0.045, 0.075), "ground_horizon_color": Color(0.15, 0.13, 0.19),
		"ambient_color": Color(0.35, 0.35, 0.50), "ambient_energy": 0.76,
		"fog_color": Color(0.21, 0.18, 0.30), "fog_density": 0.00025,
	},
	{
		"hour": 21.0,
		"sun_rotation_degrees": Vector3(-8.0, 0.0, 0.0),
		"sun_color": Color(0.38, 0.46, 0.70), "sun_energy": 0.015,
		"fill_color": Color(0.57, 0.69, 1.0), "fill_energy": 0.22,
		"sky_top_color": Color(0.03, 0.055, 0.13), "sky_horizon_color": Color(0.13, 0.17, 0.27),
		"ground_bottom_color": Color(0.025, 0.035, 0.055), "ground_horizon_color": Color(0.09, 0.11, 0.16),
		"ambient_color": Color(0.34, 0.40, 0.58), "ambient_energy": 0.78,
		"fog_color": Color(0.075, 0.095, 0.15), "fog_density": 0.00021,
	},
	{
		"hour": 24.0,
		"sun_rotation_degrees": Vector3(-14.0, 90.0, 0.0),
		"sun_color": Color(0.34, 0.43, 0.66), "sun_energy": 0.0,
		"fill_color": Color(0.57, 0.69, 1.0), "fill_energy": 0.22,
		"sky_top_color": Color(0.025, 0.045, 0.10), "sky_horizon_color": Color(0.10, 0.14, 0.24),
		"ground_bottom_color": Color(0.025, 0.035, 0.055), "ground_horizon_color": Color(0.08, 0.10, 0.15),
		"ambient_color": Color(0.34, 0.40, 0.58), "ambient_energy": 0.78,
		"fog_color": Color(0.065, 0.085, 0.14), "fog_density": 0.00020,
	},
]

var time_of_day_hours := 14.5
var _sun: DirectionalLight3D
var _fill_light: DirectionalLight3D
var _world_environment: WorldEnvironment
var _environment: Environment
var _sky_material: ProceduralSkyMaterial


func _ready() -> void:
	time_of_day_hours = _normalize_hour(initial_time_of_day)
	_sun = get_node_or_null(sun_path) as DirectionalLight3D
	_fill_light = get_node_or_null(fill_light_path) as DirectionalLight3D
	_world_environment = WorldEnvironment.new()
	_world_environment.name = "WorldEnvironment"
	_environment = Environment.new()
	_sky_material = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = _sky_material
	_environment.background_mode = Environment.BG_SKY
	_environment.background_sky = sky
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_environment.tonemap_exposure = 1.0
	_environment.fog_enabled = true
	_environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	_environment.fog_aerial_perspective = 0.28
	_environment.fog_sky_affect = 0.12
	_world_environment.environment = _environment
	add_child(_world_environment)
	_apply_profile(profile_for_hour(time_of_day_hours))


func _process(delta: float) -> void:
	if auto_advance_hours_per_second > 0.0:
		advance_time(auto_advance_hours_per_second * delta)


func set_time_of_day(hour: float) -> void:
	if not is_finite(hour):
		return
	var normalized_hour := _normalize_hour(hour)
	if is_equal_approx(time_of_day_hours, normalized_hour):
		return
	time_of_day_hours = normalized_hour
	_apply_profile(profile_for_hour(time_of_day_hours))


func advance_time(hours: float) -> void:
	if not is_finite(hours):
		return
	set_time_of_day(time_of_day_hours + hours)


static func profile_for_hour(hour: float) -> Dictionary:
	if not is_finite(hour):
		hour = 12.0
	var normalized_hour := _normalize_hour(hour)
	var start: Dictionary = PROFILE_STOPS[0]
	var finish: Dictionary = PROFILE_STOPS[1]
	for index in range(PROFILE_STOPS.size() - 1):
		var candidate: Dictionary = PROFILE_STOPS[index + 1]
		if normalized_hour <= float(candidate["hour"]):
			start = PROFILE_STOPS[index]
			finish = candidate
			break
	var span := float(finish["hour"]) - float(start["hour"])
	var blend := clampf((normalized_hour - float(start["hour"])) / span, 0.0, 1.0) if span > 0.0 else 0.0
	blend = blend * blend * (3.0 - 2.0 * blend)
	return {
		"sun_rotation_degrees": (start["sun_rotation_degrees"] as Vector3).lerp(finish["sun_rotation_degrees"], blend),
		"sun_color": (start["sun_color"] as Color).lerp(finish["sun_color"], blend),
		"sun_energy": lerpf(float(start["sun_energy"]), float(finish["sun_energy"]), blend),
		"fill_color": (start["fill_color"] as Color).lerp(finish["fill_color"], blend),
		"fill_energy": lerpf(float(start["fill_energy"]), float(finish["fill_energy"]), blend),
		"sky_top_color": (start["sky_top_color"] as Color).lerp(finish["sky_top_color"], blend),
		"sky_horizon_color": (start["sky_horizon_color"] as Color).lerp(finish["sky_horizon_color"], blend),
		"ground_bottom_color": (start["ground_bottom_color"] as Color).lerp(finish["ground_bottom_color"], blend),
		"ground_horizon_color": (start["ground_horizon_color"] as Color).lerp(finish["ground_horizon_color"], blend),
		"ambient_color": (start["ambient_color"] as Color).lerp(finish["ambient_color"], blend),
		"ambient_energy": lerpf(float(start["ambient_energy"]), float(finish["ambient_energy"]), blend),
		"fog_color": (start["fog_color"] as Color).lerp(finish["fog_color"], blend),
		"fog_density": lerpf(float(start["fog_density"]), float(finish["fog_density"]), blend),
	}


func _apply_profile(profile: Dictionary) -> void:
	var sun_color: Color = profile["sun_color"]
	var fill_color: Color = profile["fill_color"]
	if is_instance_valid(_sun):
		_sun.rotation_degrees = profile["sun_rotation_degrees"]
		_sun.light_color = sun_color
		_sun.light_energy = float(profile["sun_energy"])
	if is_instance_valid(_fill_light):
		_fill_light.light_color = fill_color
		_fill_light.light_energy = float(profile["fill_energy"])
	if not is_instance_valid(_environment) or not is_instance_valid(_sky_material):
		return
	_sky_material.sky_top_color = profile["sky_top_color"]
	_sky_material.sky_horizon_color = profile["sky_horizon_color"]
	_sky_material.ground_bottom_color = profile["ground_bottom_color"]
	_sky_material.ground_horizon_color = profile["ground_horizon_color"]
	_environment.ambient_light_color = profile["ambient_color"]
	_environment.ambient_light_energy = float(profile["ambient_energy"])
	_environment.fog_light_color = profile["fog_color"]
	_environment.fog_density = float(profile["fog_density"])


static func _normalize_hour(hour: float) -> float:
	return fposmod(hour, 24.0)
