extends SceneTree

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSampler = preload("res://scripts/world/terrain_sampler.gd")


class SamplerJob extends RefCounted:
	var sampler: TerrainSampler
	var seed: int

	func _init(sampler_value: TerrainSampler, seed_value: int) -> void:
		sampler = sampler_value
		seed = seed_value

	func run() -> Array[Dictionary]:
		var results: Array[Dictionary] = []
		for point in [Vector2(-1320.5, 804.25), Vector2(170.0, -2110.0), Vector2(4250.75, 309.5)]:
			results.append(sampler.regional_surface_sample(seed, point.x, point.y))
		return results


var _failures := 0


func _init() -> void:
	_test_legacy_api_forwarding()
	_test_regional_api_forwarding()
	_test_combined_surface_sample()
	_test_concurrent_independent_samplers()
	if _failures == 0:
		print("TERRAIN SAMPLER TEST: PASS")
		quit(0)
		return
	push_error("TERRAIN SAMPLER TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _test_legacy_api_forwarding() -> void:
	var sampler := Terrain.create_sampler()
	for seed in [731945, 123456]:
		for point in [Vector2.ZERO, Vector2(420.0, -180.0), Vector2(-2480.5, 619.25)]:
			_expect_near(sampler.height(seed, point.x, point.y), Terrain.height(seed, point.x, point.y), "legacy height forwarding")
			_expect_near(sampler.slope_degrees(seed, point.x, point.y), Terrain.slope_degrees(seed, point.x, point.y), "legacy slope forwarding")
			_expect_near(sampler.moisture(seed, point.x, point.y), Terrain.moisture(seed, point.x, point.y), "legacy moisture forwarding")
			_expect_near(sampler.forest_potential(seed, point.x, point.y), Terrain.forest_potential(seed, point.x, point.y), "legacy forest forwarding")
			_expect(sampler.biome(seed, point.x, point.y) == Terrain.biome(seed, point.x, point.y), "legacy biome forwarding")
			_expect_color_near(sampler.terrain_color(seed, point.x, point.y), Terrain.terrain_color(seed, point.x, point.y), "legacy color forwarding")
	_expect_near(Terrain.height(284731, 0.0, 0.0), -9.1623813419, "legacy terrain anchor unchanged")
	var anchor := Terrain._random01(731945, "terrain-sampler-alias")
	_expect(Terrain._random_cache.size() > 0, "legacy random cache alias remains populated")
	_expect_near(Terrain._random01(731945, "terrain-sampler-alias"), anchor, "legacy random cache alias remains deterministic")


func _test_regional_api_forwarding() -> void:
	var sampler := Terrain.create_sampler()
	for seed in [731945, 412309]:
		for point in [Vector2(-1320.5, 804.25), Vector2(0.0, 0.0), Vector2(2275.0, -3110.75)]:
			_expect_near(sampler.regional_height(seed, point.x, point.y), Terrain.regional_height(seed, point.x, point.y), "regional height forwarding")
			_expect_near(sampler.regional_slope_degrees(seed, point.x, point.y), Terrain.regional_slope_degrees(seed, point.x, point.y), "regional slope forwarding")
			_expect_near(sampler.regional_moisture(seed, point.x, point.y), Terrain.regional_moisture(seed, point.x, point.y), "regional moisture forwarding")
			_expect_near(sampler.regional_forest_potential(seed, point.x, point.y), Terrain.regional_forest_potential(seed, point.x, point.y), "regional forest forwarding")
			_expect_near(sampler.regional_ground_cover_potential(seed, point.x, point.y), Terrain.regional_ground_cover_potential(seed, point.x, point.y), "regional ground-cover forwarding")
			_expect(sampler.regional_biome(seed, point.x, point.y) == Terrain.regional_biome(seed, point.x, point.y), "regional biome forwarding")
			_expect_color_near(sampler.regional_terrain_color(seed, point.x, point.y), Terrain.regional_terrain_color(seed, point.x, point.y), "regional color forwarding")
			_expect_dictionary_near(sampler.river_profile(seed, point.x, point.y), Terrain.river_profile(seed, point.x, point.y), "river profile forwarding")


func _test_combined_surface_sample() -> void:
	var sampler := Terrain.create_sampler()
	for seed in [731945, 412309]:
		for point in [Vector2(-1320.5, 804.25), Vector2(0.0, 0.0), Vector2(2275.0, -3110.75)]:
			var sample := sampler.regional_surface_sample(seed, point.x, point.y)
			_expect_near(float(sample["height"]), sampler.regional_height(seed, point.x, point.y), "combined height matches individual query")
			_expect_near(float(sample["slope"]), sampler.regional_slope_degrees(seed, point.x, point.y), "combined slope matches individual query")
			_expect_near(float(sample["moisture"]), sampler.regional_moisture(seed, point.x, point.y), "combined moisture matches individual query")
			_expect_near(float(sample["forest"]), sampler.regional_forest_potential(seed, point.x, point.y), "combined forest matches individual query")
			_expect_color_near(sample["color"], sampler.regional_terrain_color(seed, point.x, point.y), "combined color matches individual query")
			_expect_near(float(sample["ground_cover"]), sampler.regional_ground_cover_potential(seed, point.x, point.y), "combined ground cover matches individual query")
			var forwarded := Terrain.regional_surface_sample(seed, point.x, point.y)
			_expect_dictionary_near(sample, forwarded, "combined static forwarding")


func _test_concurrent_independent_samplers() -> void:
	var seed_a := 712301
	var seed_b := 990217
	var sampler_a := Terrain.create_sampler()
	var sampler_b := Terrain.create_sampler()
	var expected_a := _expected_samples(seed_a)
	var expected_b := _expected_samples(seed_b)
	var job_a := SamplerJob.new(sampler_a, seed_a)
	var job_b := SamplerJob.new(sampler_b, seed_b)
	var thread_a := Thread.new()
	var thread_b := Thread.new()
	var start_a := thread_a.start(Callable(job_a, "run"))
	var start_b := thread_b.start(Callable(job_b, "run"))
	_expect(start_a == OK and start_b == OK, "independent sampler worker threads start")
	if start_a != OK or start_b != OK:
		if start_a == OK:
			thread_a.wait_to_finish()
		if start_b == OK:
			thread_b.wait_to_finish()
		return
	var actual_a: Array[Dictionary] = thread_a.wait_to_finish()
	var actual_b: Array[Dictionary] = thread_b.wait_to_finish()
	_expect_samples_near(actual_a, expected_a, "thread A retains independent sampler state")
	_expect_samples_near(actual_b, expected_b, "thread B retains independent sampler state")
	_expect(sampler_a._random_cache_seed == seed_a, "thread A random cache retains its seed")
	_expect(sampler_b._random_cache_seed == seed_b, "thread B random cache retains its seed")
	_expect(sampler_a._regional_sample_seed == seed_a, "thread A regional cache retains its seed")
	_expect(sampler_b._regional_sample_seed == seed_b, "thread B regional cache retains its seed")


func _expected_samples(seed: int) -> Array[Dictionary]:
	var sampler := Terrain.create_sampler()
	var results: Array[Dictionary] = []
	for point in [Vector2(-1320.5, 804.25), Vector2(170.0, -2110.0), Vector2(4250.75, 309.5)]:
		results.append(sampler.regional_surface_sample(seed, point.x, point.y))
	return results


func _expect_samples_near(actual: Array[Dictionary], expected: Array[Dictionary], message: String) -> void:
	_expect(actual.size() == expected.size(), "%s (sample count)" % message)
	for index in range(mini(actual.size(), expected.size())):
		_expect_dictionary_near(actual[index], expected[index], "%s #%d" % [message, index])


func _expect_dictionary_near(actual: Dictionary, expected: Dictionary, message: String) -> void:
	_expect(actual.keys().size() == expected.keys().size(), "%s (field count)" % message)
	for key in expected:
		_expect(actual.has(key), "%s (missing %s)" % [message, key])
		if not actual.has(key):
			continue
		var actual_value: Variant = actual[key]
		var expected_value: Variant = expected[key]
		if actual_value is float or actual_value is int:
			_expect_near(float(actual_value), float(expected_value), "%s.%s" % [message, key])
		elif actual_value is Color:
			_expect_color_near(actual_value, expected_value, "%s.%s" % [message, key])
		else:
			_expect(actual_value == expected_value, "%s.%s" % [message, key])


func _expect_color_near(actual: Color, expected: Color, message: String) -> void:
	_expect_near(actual.r, expected.r, "%s.r" % message)
	_expect_near(actual.g, expected.g, "%s.g" % message)
	_expect_near(actual.b, expected.b, "%s.b" % message)
	_expect_near(actual.a, expected.a, "%s.a" % message)


func _expect_near(actual: float, expected: float, message: String) -> void:
	_expect(is_equal_approx(actual, expected), "%s (%.10f vs %.10f)" % [message, actual, expected])


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("TerrainSampler: %s" % message)
