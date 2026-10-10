extends SceneTree

const WorldEnvironmentController = preload("res://scripts/render/world_environment_controller.gd")

var _failures := 0


func _initialize() -> void:
	await _run_tests()
	if _failures == 0:
		print("WORLD ENVIRONMENT CONTROLLER TEST: PASS")
		quit(0)
		return
	push_error("WORLD ENVIRONMENT CONTROLLER TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _run_tests() -> void:
	var midnight := WorldEnvironmentController.profile_for_hour(0.0)
	var end_of_day := WorldEnvironmentController.profile_for_hour(24.0)
	var wrapped_negative := WorldEnvironmentController.profile_for_hour(-1.0)
	var late_night := WorldEnvironmentController.profile_for_hour(23.0)
	var dawn := WorldEnvironmentController.profile_for_hour(6.5)
	var golden_hour := WorldEnvironmentController.profile_for_hour(18.0)
	var noon := WorldEnvironmentController.profile_for_hour(12.0)
	var dawn_sun_rotation: Vector3 = dawn["sun_rotation_degrees"]
	var noon_sun_rotation: Vector3 = noon["sun_rotation_degrees"]
	var dusk_sun_rotation: Vector3 = golden_hour["sun_rotation_degrees"]
	var day_sky: Color = noon["sky_top_color"]
	var night_sky: Color = midnight["sky_top_color"]
	var dusk_horizon: Color = golden_hour["sky_horizon_color"]

	_expect(midnight == end_of_day, "24:00 wraps to the same night profile as 00:00")
	_expect(wrapped_negative == late_night, "negative hours wrap deterministically into the previous day")
	_expect(float(noon["sun_energy"]) > float(golden_hour["sun_energy"]), "noon has stronger direct sunlight than golden hour")
	_expect(float(golden_hour["sun_energy"]) > float(dawn["sun_energy"]), "golden hour retains more direct light than dawn")
	_expect(float(midnight["sun_energy"]) < 0.02, "night disables direct sunlight")
	_expect(float(midnight["fill_energy"]) > 0.0 and float(midnight["ambient_energy"]) > 0.0, "night retains fill and ambient light for readable streets")
	_expect((dawn["sun_color"] as Color).r > (dawn["sun_color"] as Color).b, "dawn sunlight is warmer than blue")
	_expect((golden_hour["sun_color"] as Color).r > (golden_hour["sun_color"] as Color).b, "dusk sunlight keeps a warm amber tint")
	_expect(day_sky.b > day_sky.r, "daytime sky remains blue")
	_expect(night_sky.r < day_sky.r and night_sky.b < day_sky.b, "night sky is darker than the daytime sky")
	_expect((midnight["ambient_color"] as Color).b > (midnight["ambient_color"] as Color).r, "night fill stays cool while keeping the city readable")
	_expect(dusk_horizon.r > dusk_horizon.b, "dusk horizon carries a warm sunset band")
	_expect(dawn_sun_rotation.x > noon_sun_rotation.x, "dawn sun sits lower than the midday sun")
	_expect(dawn_sun_rotation.y > noon_sun_rotation.y, "sun approaches from the morning side")
	_expect(dusk_sun_rotation.y < noon_sun_rotation.y, "sun moves across the sky toward evening")
	_expect(float(WorldEnvironmentController.profile_for_hour(7.25)["sun_energy"]) > float(dawn["sun_energy"]), "profiles interpolate smoothly between dawn stops")
	var mid_morning: Dictionary = WorldEnvironmentController.profile_for_hour(10.0)
	var mid_morning_rotation: Vector3 = mid_morning["sun_rotation_degrees"]
	_expect(
		mid_morning_rotation.y < dawn_sun_rotation.y and mid_morning_rotation.y > noon_sun_rotation.y,
		"sun direction eases between the horizon and midday"
	)
	_expect(float(midnight["fog_density"]) > 0.0 and float(noon["fog_density"]) > 0.0, "all times receive a finite atmospheric haze profile")
	for sample_hour in [0.0, 3.5, 6.5, 10.0, 12.0, 16.0, 18.0, 20.0, 24.0]:
		var sample_profile: Dictionary = WorldEnvironmentController.profile_for_hour(sample_hour)
		var sample_rotation: Vector3 = sample_profile["sun_rotation_degrees"]
		_expect(
			is_finite(sample_rotation.x) and is_finite(sample_rotation.y) and is_finite(sample_rotation.z),
			"every sampled time has a finite sun direction"
		)

	var rig := Node3D.new()
	rig.name = "LightingRig"
	root.add_child(rig)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	rig.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	rig.add_child(fill)
	var controller := WorldEnvironmentController.new()
	controller.initial_time_of_day = 6.5
	rig.add_child(controller)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 16000.0, 0.0)
	rig.add_child(camera)
	camera.make_current()
	await process_frame
	var world_environment := controller.get_node_or_null("WorldEnvironment") as WorldEnvironment
	_expect(world_environment != null, "controller installs its environment inside the lighting rig")
	_expect(
		is_equal_approx(sun.rotation_degrees.x, dawn_sun_rotation.x)
		and is_equal_approx(sun.rotation_degrees.y, dawn_sun_rotation.y),
		"controller applies the dawn direction to the directional sun"
	)
	if world_environment != null:
		var environment := world_environment.environment
		_expect(environment.fog_density * 16000.0 <= 0.281, "overview fog preserves region contrast over 16 km")
		_expect(environment.volumetric_fog_density * 4200.0 < 0.1, "overview volumetric fog cannot obscure the map")
		_expect(environment.fog_height_density == 0.0, "below-zero terrain does not amplify height fog")
		var overview_density := environment.fog_density
		camera.position = Vector3(0.0, 180.0, 0.0)
		await process_frame
		await process_frame
		_expect(environment.fog_density > overview_density, "zooming in restores the local atmosphere profile")
		controller.set_time_of_day(0.0)
		camera.position = Vector3(0.0, 16000.0, 0.0)
		await process_frame
		await process_frame
		_expect(environment.fog_density * 16000.0 <= 0.281, "night fog also respects the overview contrast budget")
		controller.set_time_of_day(6.5)
		_expect(world_environment.environment.background_mode == Environment.BG_SKY, "controller installs a procedural sky")
		_expect(world_environment.environment.tonemap_mode == Environment.TONE_MAPPER_FILMIC, "controller enables filmic tonemapping")
		_expect(world_environment.environment.fog_enabled, "controller enables atmospheric fog")
		controller.set_time_of_day(12.0)
		_expect(is_equal_approx(world_environment.environment.ambient_light_energy, float(noon["ambient_energy"])), "time setter applies the selected ambient profile")
		_expect(
			is_equal_approx(sun.rotation_degrees.x, noon_sun_rotation.x)
			and is_equal_approx(sun.rotation_degrees.y, noon_sun_rotation.y),
			"time setter moves the sun to its midday direction"
		)
		controller.set_time_of_day(NAN)
		_expect(is_equal_approx(controller.time_of_day_hours, 12.0), "non-finite time input leaves the active lighting unchanged")
		controller.advance_time(14.0)
		_expect(is_equal_approx(controller.time_of_day_hours, 2.0), "advance API wraps normalized time past midnight")


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("WorldEnvironmentController: %s" % message)
