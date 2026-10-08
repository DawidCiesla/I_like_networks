extends SceneTree

const WorldLayers = preload("res://scripts/world/world_layers.gd")

const NORMALIZED_FIELDS := ["moisture", "forest_potential", "fertility", "forest", "ore", "oil", "groundwater"]

var _failures := 0


func _init() -> void:
	_run_tests()
	if _failures == 0:
		print("WORLD LAYERS TEST: PASS")
		quit(0)
		return
	push_error("WORLD LAYERS TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _run_tests() -> void:
	var seed := 41731
	var point := Vector2(1234.5, -987.25)
	var first := WorldLayers.sample(seed, point)
	var other_seed := WorldLayers.sample(seed + 1, point)
	var repeated := WorldLayers.sample(seed, point)
	var route_sample := WorldLayers.sample_route_terrain(seed, point)
	var water_sample := WorldLayers.sample_water(seed, point)
	var expected_fields := [
		"height",
		"slope_degrees",
		"moisture",
		"biome",
		"forest_potential",
		"water_depth",
		"water_kind",
		"fertility",
		"forest",
		"ore",
		"oil",
		"groundwater",
	]
	for field in expected_fields:
		_expect(first.has(field), "sample has field %s" % field)
	_expect(first == repeated, "same seed and point return identical values")
	_expect(first["height"] != other_seed["height"], "seed changes terrain sample")
	_expect(first["biome"] in ["grassland", "meadow", "forest", "hillside"], "biome uses a known label")
	_expect(is_equal_approx(float(route_sample["slope_degrees"]), float(first["slope_degrees"])), "route sampler reuses exact slope values")
	_expect(is_equal_approx(float(route_sample["forest_potential"]), float(first["forest_potential"])), "route sampler reuses exact forest costs")
	_expect(is_equal_approx(float(route_sample["water_depth"]), float(first["water_depth"])), "route sampler reuses exact water depth")
	_expect(str(water_sample["water_kind"]) == str(first["water_kind"]), "water sampler reuses exact water kind")

	var river_count := 0
	var lake_count := 0
	var wet_count := 0
	for grid_x in range(-9, 10):
		for grid_z in range(-9, 10):
			var data: Dictionary = WorldLayers.sample(
				seed,
				Vector2(float(grid_x) * 300.0, float(grid_z) * 300.0)
			)
			for field in NORMALIZED_FIELDS:
				var value := float(data[field])
				_expect(value >= 0.0 and value <= 1.0, "%s stays normalized" % field)
			var water_depth := float(data["water_depth"])
			var water_kind := str(data["water_kind"])
			_expect(water_depth >= 0.0 and water_depth <= 9.0, "water depth stays bounded")
			_expect(water_kind in ["none", "river", "lake"], "water kind uses a known label")
			if water_kind == "none":
				_expect(water_depth == 0.0, "dry samples have zero depth")
			else:
				_expect(water_depth > 0.0, "water samples have positive depth")
				wet_count += 1
			if water_kind == "river":
				river_count += 1
			elif water_kind == "lake":
				lake_count += 1
	_expect(wet_count > 0, "seeded region contains water")
	_expect(river_count > 0, "seeded region contains queryable river samples")
	_expect(lake_count > 0, "seeded region contains queryable lake samples")


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("WorldLayers: %s" % message)
