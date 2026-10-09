extends SceneTree

const Data = preload("res://scripts/core/game_data.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const WorldLayers = preload("res://scripts/world/world_layers.gd")

var _failures := 0


func _init() -> void:
	var previous_map := MapDefinition.active_definition()
	var seed := 731945
	MapDefinition.set_active(MapDefinition.create(MapDefinition.DEFAULT_MAP_ID, seed))
	_run_tests(seed)
	MapDefinition.set_active(previous_map)
	if _failures == 0:
		print("REGIONAL NATURAL TERRAIN TEST: PASS")
		quit(0)
		return
	push_error("REGIONAL NATURAL TERRAIN TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _run_tests(seed: int) -> void:
	var repeated_a := Terrain.regional_height(seed, 1640.0, -2180.0)
	var repeated_b := Terrain.regional_height(seed, 1640.0, -2180.0)
	_expect(is_equal_approx(repeated_a, repeated_b), "regional height is deterministic")
	_expect(
		not is_equal_approx(repeated_a, Terrain.height(seed, 1640.0, -2180.0)),
		"regional terrain is independent from the legacy Bus Era profile"
	)

	var min_height := INF
	var max_height := -INF
	var min_forest := 1.0
	var max_forest := 0.0
	var grass_points := 0
	var river_count := 0
	var lake_count := 0
	var shallow_river := INF
	var deep_river := 0.0
	for grid_z in range(-10, 11):
		for grid_x in range(-10, 11):
			var point := Vector2(float(grid_x) * 950.0, float(grid_z) * 950.0)
			var terrain_height := Terrain.regional_height(seed, point.x, point.y)
			var forest := Terrain.regional_forest_potential(seed, point.x, point.y)
			var cover := Terrain.regional_ground_cover_potential(seed, point.x, point.y)
			min_height = minf(min_height, terrain_height)
			max_height = maxf(max_height, terrain_height)
			min_forest = minf(min_forest, forest)
			max_forest = maxf(max_forest, forest)
			if cover > 0.34:
				grass_points += 1
			var water := WorldLayers.sample_water(seed, point)
			var kind := str(water.get("water_kind", "none"))
			var depth := float(water.get("water_depth", 0.0))
			if kind == "river":
				river_count += 1
				shallow_river = minf(shallow_river, depth)
				deep_river = maxf(deep_river, depth)
			elif kind == "lake":
				lake_count += 1

	_expect(max_height - min_height > 45.0, "regional relief spans meaningful lowlands and highlands")
	_expect(max_forest - min_forest > 0.18, "forest potential varies enough to form groves and clearings")
	_expect(grass_points > 30, "regional landscape exposes broad ground-cover habitat")
	_expect(river_count > 0, "regional drainage produces rivers")
	_expect(lake_count > 0, "regional drainage produces lakes")
	if river_count > 1:
		_expect(deep_river - shallow_river > 0.20, "rivers expose multiple depth/size classes")

	var bounds := TerrainSurface.world_bounds()
	var steps := TerrainSurface.grid_steps(bounds)
	var step_x := bounds.size.x / float(steps.x)
	var step_z := bounds.size.y / float(steps.y)
	var vertex := bounds.position + Vector2(step_x * 3.0, step_z * 5.0)
	_expect_near(
		TerrainSurface.height(seed, vertex.x, vertex.y),
		Terrain.regional_height(seed, vertex.x, vertex.y),
		0.0001,
		"visible regional terrain uses the regional analytic profile at mesh vertices"
	)

	# Changing map profile with the same seed must invalidate TerrainSurface's
	# vertex cache rather than leaking heights between legacy and regional maps.
	var regional_vertex_height := TerrainSurface.height(seed, vertex.x, vertex.y)
	MapDefinition.set_active(MapDefinition.create(MapDefinition.LEGACY_CITY_MAP_ID, seed))
	var legacy_height := TerrainSurface.height(seed, 0.0, 0.0)
	_expect_near(legacy_height, TerrainSurface.height(seed, 0.0, 0.0), 0.0001, "legacy terrain remains stable after profile switch")
	MapDefinition.set_active(MapDefinition.create(MapDefinition.DEFAULT_MAP_ID, seed))
	_expect_near(
		TerrainSurface.height(seed, vertex.x, vertex.y),
		regional_vertex_height,
		0.0001,
		"regional terrain cache rebuilds consistently after profile switch"
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("RegionalNaturalTerrain: %s" % message)


func _expect_near(actual: float, expected: float, tolerance: float, message: String) -> void:
	_expect(absf(actual - expected) <= tolerance, "%s (%.6f vs %.6f)" % [message, actual, expected])
