extends SceneTree

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const Terrain = preload("res://scripts/world/terrain_model.gd")
const StoreScript = preload("res://scripts/core/game_store.gd")
const PlanGenerator = preload("res://scripts/city/city_plan_generator.gd")
const BrowserImporter = preload("res://scripts/persistence/browser_save_importer.gd")
const BuildingFoundation = preload("res://scripts/render/building_foundation.gd")
const BuildingOrientation = preload("res://scripts/render/building_orientation.gd")
const BuildingAssets = preload("res://scripts/render/building_asset_library.gd")
const RoadGeometry = preload("res://scripts/render/road_geometry.gd")

var _self_test_failed := false

func _init() -> void:
	_test_shared_interchanges()
	_test_route_geometry()
	_test_road_geometry()
	_test_terrain_determinism()
	_test_building_foundation_sampling()
	_test_building_frontage_orientation()
	_test_building_visual_archetypes()
	_test_arrival_fare_simulation()
	_test_master_plan_fixture()
	_test_native_plan_generation()
	_test_city_growth_runtime()
	_test_browser_save_import()
	if _self_test_failed:
		push_error("GODOT PORT SELF-TEST: FAIL")
		quit(1)
		return
	print("GODOT PORT SELF-TEST: PASS")
	quit(0)

func _test_shared_interchanges() -> void:
	_expect(Data.STATION_IDS.line1[2] == Data.STATION_IDS.line2[0])
	_expect(Data.STATION_IDS.line1[3] == Data.STATION_IDS.line3[0])
	_expect(Data.STATION_IDS.line2[3] == Data.STATION_IDS.line4[0])
	_expect(Data.STATION_IDS.line1[4] == Data.STATION_IDS.line4[4])

func _test_route_geometry() -> void:
	for line_key in Data.LINE_KEYS:
		var max_stops := int(Data.LINE_CONFIG[line_key].max_stops)
		var route := Layout.built_route(line_key, max_stops)
		_expect(route.size() >= 2)
		_expect(Layout.route_length(route) > 300.0)

	for line_key in ["line3", "line4"]:
		var segments: Array = Layout.BASE_SEGMENTS[line_key]
		for segment_index in range(segments.size()):
			var points := Layout.segment_points(line_key, segment_index)
			var distance := Layout.route_length(points)
			_expect(distance >= 350.0)
			_expect(distance <= 1250.0)

func _test_road_geometry() -> void:
	var straight: Array[Vector2] = [Vector2(0.0, 0.0), Vector2(100.0, 0.0)]
	var sampled := RoadGeometry.resample_polyline(straight, 8.0)
	_expect(sampled.size() >= 13)
	_expect(sampled.front().is_equal_approx(straight.front()))
	_expect(sampled.back().is_equal_approx(straight.back()))

	var bent: Array[Vector2] = [
		Vector2(0.0, 0.0),
		Vector2(50.0, 0.0),
		Vector2(50.0, 50.0),
	]
	var ribbon = RoadGeometry.create_ribbon_mesh(
		Data.DEFAULT_CITY_SEED,
		bent,
		16.0,
		Color.WHITE,
		0.05,
		8.0,
		true
	)
	_expect(ribbon != null)
	if ribbon != null:
		_expect(ribbon.get_surface_count() == 1)

	var arms := [
		{"direction": Vector2.RIGHT, "width": 20.0},
		{"direction": Vector2.LEFT, "width": 20.0},
		{"direction": Vector2.DOWN, "width": 14.0},
	]
	var polygon := RoadGeometry.junction_polygon(Vector2.ZERO, arms)
	_expect(polygon.size() >= 4)
	var patch = RoadGeometry.create_junction_patch_mesh(
		Data.DEFAULT_CITY_SEED,
		Vector2.ZERO,
		arms,
		Color.WHITE,
		0.05
	)
	_expect(patch != null)
	if patch != null:
		_expect(patch.get_surface_count() == 1)

func _test_terrain_determinism() -> void:
	var samples := [
		Vector2.ZERO,
		Vector2(420.0, -180.0),
		Vector2(-900.0, 700.0),
		Vector2(1400.0, -600.0),
	]

	for point in samples:
		var first := Terrain.height(Data.DEFAULT_CITY_SEED, point.x, point.y)
		var second := Terrain.height(Data.DEFAULT_CITY_SEED, point.x, point.y)
		_expect(is_equal_approx(first, second))

		var slope := Terrain.slope_degrees(Data.DEFAULT_CITY_SEED, point.x, point.y)
		_expect(is_finite(slope))
		_expect(slope >= 0.0)

		var forest := Terrain.forest_potential(Data.DEFAULT_CITY_SEED, point.x, point.y)
		_expect(forest >= 0.0 and forest <= 1.0)

func _test_building_foundation_sampling() -> void:
	var seed := Data.DEFAULT_CITY_SEED
	var cases := [
		{"center": Vector2(-320.0, 140.0), "rotation": 0.0, "width": 24.0, "depth": 16.0},
		{"center": Vector2(510.0, -430.0), "rotation": PI * 0.25, "width": 40.0, "depth": 28.0},
		{"center": Vector2(870.0, 620.0), "rotation": PI * 0.5, "width": 18.0, "depth": 14.0},
		{"center": Vector2(-740.0, -810.0), "rotation": -PI * 0.37, "width": 56.0, "depth": 42.0},
	]

	for test_case in cases:
		var center: Vector2 = test_case["center"]
		var rotation := float(test_case["rotation"])
		var width := float(test_case["width"])
		var depth := float(test_case["depth"])
		var sampled := BuildingFoundation.height_range(seed, center, rotation, width, depth)
		_expect(is_finite(sampled.x) and is_finite(sampled.y))
		_expect(sampled.x <= sampled.y)

		var steps_x := maxi(1, ceili(width / 8.0))
		var steps_z := maxi(1, ceili(depth / 8.0))
		var expected_min := INF
		var expected_max := -INF
		var cosine := cos(rotation)
		var sine := sin(rotation)
		for z_index in range(steps_z + 1):
			var local_z := -depth * 0.5 + depth * float(z_index) / float(steps_z)
			for x_index in range(steps_x + 1):
				var local_x := -width * 0.5 + width * float(x_index) / float(steps_x)
				var sample_point := Vector2(
					center.x + cosine * local_x - sine * local_z,
					center.y + sine * local_x + cosine * local_z
				)
				var sample_height := Terrain.height(seed, sample_point.x, sample_point.y)
				expected_min = minf(expected_min, sample_height)
				expected_max = maxf(expected_max, sample_height)

		_expect(is_equal_approx(sampled.x, expected_min))
		_expect(is_equal_approx(sampled.y, expected_max))
		_expect(sampled.y + 0.7 >= expected_max)
		var platform := BuildingFoundation.box_transform(
			center,
			width,
			depth,
			rotation,
			sampled.x,
			sampled.y
		)
		var platform_bottom := platform.origin.y - platform.basis.y.length() * 0.5
		var platform_top := platform.origin.y + platform.basis.y.length() * 0.5
		_expect(is_equal_approx(platform_bottom, sampled.x))
		_expect(is_equal_approx(platform_top, sampled.y + 0.7))
		_expect(is_equal_approx(platform.basis.x.length(), width))
		_expect(is_equal_approx(platform.basis.z.length(), depth))
		for _progress in [0.0, 0.5, 1.0]:
			var unchanged_platform := BuildingFoundation.box_transform(
				center,
				width,
				depth,
				rotation,
				sampled.x,
				sampled.y
			)
			_expect(unchanged_platform.origin.is_equal_approx(platform.origin))
			_expect(unchanged_platform.basis.is_equal_approx(platform.basis))

	var flattest_range := INF
	var steepest_range := 0.0
	for x in range(-800, 801, 200):
		for z in range(-800, 801, 200):
			var sample_range := BuildingFoundation.height_range(
				seed,
				Vector2(float(x), float(z)),
				PI * 0.25,
				24.0,
				20.0
			)
			var height_span := sample_range.y - sample_range.x
			flattest_range = minf(flattest_range, height_span)
			steepest_range = maxf(steepest_range, height_span)
	_expect(flattest_range >= 0.0)
	_expect(steepest_range > flattest_range)

func _test_building_frontage_orientation() -> void:
	var road: Array[Vector2] = [Vector2(-30.0, 0.0), Vector2(30.0, 0.0)]
	_expect(is_equal_approx(BuildingOrientation.frontage_yaw_adjustment(0.0, Vector2(0.0, 10.0), road, 1.0), PI))
	_expect(is_equal_approx(BuildingOrientation.frontage_yaw_adjustment(0.0, Vector2(0.0, -10.0), road, 1.0), 0.0))
	_expect(is_equal_approx(BuildingOrientation.frontage_yaw_adjustment(0.0, Vector2(0.0, 10.0), road, -1.0), 0.0))
	var vertical_road: Array[Vector2] = [Vector2(0.0, -30.0), Vector2(0.0, 30.0)]
	_expect(is_equal_approx(BuildingOrientation.frontage_yaw_adjustment(PI * 0.5, Vector2(-10.0, 0.0), vertical_road, 1.0), PI))

func _test_building_visual_archetypes() -> void:
	var profiles := [
		{"kind": "house", "floors": 1, "density": 1},
		{"kind": "townhouse", "floors": 2, "density": 2},
		{"kind": "shop", "floors": 1, "density": 2},
		{"kind": "apartment", "floors": 6, "density": 3},
		{"kind": "midrise", "floors": 7, "density": 3},
		{"kind": "tower", "floors": 10, "density": 4},
		{"kind": "workshop", "floors": 1, "density": 2},
		{"kind": "warehouse", "floors": 2, "density": 4},
		{"kind": "civic", "floors": 3, "density": 2},
		{"kind": "campus", "floors": 4, "density": 3},
	]
	for index in range(profiles.size()):
		var profile: Dictionary = profiles[index]
		var building := {
			"id": "self-test-%s" % str(profile["kind"]),
			"profile": profile,
		}
		var visual_data := BuildingAssets.create_visual(building, 32.0, 28.0, 24.0, 0.0)
		_expect(not visual_data.is_empty())
		_expect(str(visual_data["model_key"]) in BuildingAssets._variant_choices(
			str(profile["kind"]), int(profile["floors"]), int(profile["density"])
		))
		_expect(float(visual_data["footprint_width"]) > 0.0)
		_expect(float(visual_data["footprint_depth"]) > 0.0)
		_expect(absf(float(visual_data["front_side"])) == 1.0)
		(visual_data["visual"] as Node).free()

	_expect(BuildingAssets._variant_choices("apartment", 4, 3) != BuildingAssets._variant_choices("apartment", 7, 4))
	_expect(BuildingAssets._variant_choices("warehouse", 1, 3) != BuildingAssets._variant_choices("warehouse", 2, 4))


func _expect(condition: bool) -> void:
	if not condition:
		_self_test_failed = true
		push_error("SELF-TEST CHECK FAILED")

func _test_arrival_fare_simulation() -> void:
	var store = StoreScript.new()
	store.suppress_persistence = true
	store.reset_state(false)
	store.money = 10_000.0

	var before: float = float(store.money)
	_expect(store.build_next_stop("line1"))
	_expect(bool(store.lines["line1"]["built"]))
	_expect(int(store.lines["line1"]["fleet_count"]) == 1)
	_expect(float(store.stats["lifetime_revenue"]) == 0.0)

	var after_purchase: float = float(store.money)
	_expect(after_purchase < before)

	store._advance_simulation(0.5)
	_expect(is_equal_approx(store.money, after_purchase))

	var guard := 0
	while float(store.stats["lifetime_revenue"]) <= 0.0 and guard < 1000:
		store._advance_simulation(0.1)
		guard += 1

	_expect(guard < 1000)
	_expect(float(store.stats["lifetime_revenue"]) > 0.0)
	_expect(float(store.stats["lifetime_passengers"]) > 0.0)

	var market_before := store.station_capacity("market-square")
	_expect(store.upgrade_station("market-square"))
	_expect(store.station_capacity("market-square") > market_before)
	_expect(store.station_level("old-town") == 0)

	store.free()


func _test_master_plan_fixture() -> void:
	var file := FileAccess.open("res://data/master_plan_284731.json", FileAccess.READ)
	_expect(file != null)

	var parsed = JSON.parse_string(file.get_as_text())
	_expect(typeof(parsed) == TYPE_DICTIONARY)
	_expect(int(parsed["seed"]) == Data.DEFAULT_CITY_SEED)
	_expect(parsed["districts"].size() == 15)
	_expect(parsed["roads"].size() == 105)
	_expect(parsed["graphEdges"].size() == 342)
	_expect(parsed["junctions"].size() == 92)
	_expect(parsed["parcels"].size() == 161)


func _test_city_growth_runtime() -> void:
	var store = StoreScript.new()
	store.suppress_persistence = true
	store.reset_state(false)
	store.money = 100_000.0

	_expect(store.build_next_stop("line1"))

	for _index in range(900):
		store._advance_simulation(0.1)

	var active_districts := 0
	var built_roads := 0
	var active_projects := 0

	for district in store.city["districts"]:
		if str(district.get("status", "")) == "active":
			active_districts += 1

	for road in store.city["roads"]:
		if str(road.get("status", "")) == "built":
			built_roads += 1

	for project in store.city["projects"]:
		if str(project.get("status", "")) == "active":
			active_projects += 1

	_expect(active_districts >= 2)
	_expect(built_roads >= 2)
	_expect(store.city["buildings"].size() > 0)
	_expect(active_projects <= 2)

	for building in store.city["buildings"]:
		_expect(float(building["profile"]["heightMeters"]) > 0.0)
		_expect(is_finite(float(building["rotationRadians"])))

	store.free()

func _test_native_plan_generation() -> void:
	for seed in [1, 42, Data.DEFAULT_CITY_SEED, 654321, 999999]:
		var plan := PlanGenerator.generate(seed)
		_expect(int(plan["seed"]) == seed)
		_expect(plan["districts"].size() == 15)
		_expect(plan["roads"].size() >= 60)
		_expect(plan["parcels"].size() >= 60)
		_expect(plan["nodes"].size() > 0)
		_expect(plan["graphEdges"].size() >= plan["roads"].size())
		_expect(plan["junctions"].size() > 10)
		_expect(plan["reservations"].size() >= 2)

		for district in plan["districts"]:
			_expect(district["roadIds"].size() >= 3)
			_expect(district["parcelIds"].size() >= 4)

func _test_browser_save_import() -> void:
	var web_line1 := {
		"built": true,
		"stopCount": 4,
		"fleetCount": 2,
		"demandPerStopPpm": 3.2,
		"waitingByStop": [
			[0.0, 2.0, 1.0, 0.5, 0.0],
			[0.0, 0.0, 0.0, 0.0, 0.0],
			[0.0, 0.0, 0.0, 0.0, 0.0],
			[0.0, 0.0, 0.0, 0.0, 0.0],
			[0.0, 0.0, 0.0, 0.0, 0.0],
		],
		"queuePassengers": 3.5,
		"vehicles": [],
		"nextVehicleId": 3,
		"eventSerial": 7,
		"passengerEvents": [],
	}

	var web_state := {
		"source": "self-test",
		"state": {
			"version": 12,
			"money": 4321.0,
			"elapsedSeconds": 987.0,
			"simulationSpeed": 2,
			"line1": web_line1,
			"line2": {"built": false, "stopCount": 0, "fleetCount": 0},
			"line3": {"built": false, "stopCount": 0, "fleetCount": 0},
			"line4": {"built": false, "stopCount": 0, "fleetCount": 0},
			"stations": {
				"market-square": {"level": 2},
			},
			"depot": {
				"built": true,
				"garageSlots": 8,
				"level": 1,
			},
			"stats": {
				"lifetimeRevenue": 1200.0,
				"lifetimePassengers": 100.0,
			},
			"city": {
				"seed": Data.DEFAULT_CITY_SEED,
				"timeSeconds": 33.0,
				"runtimeAccumulatorSeconds": 0.1,
				"nextProjectId": 4,
			},
		},
	}

	var converted := BrowserImporter.convert_browser_save(web_state)
	_expect(not converted.is_empty())
	_expect(int(converted["version"]) == Data.GAME_VERSION)
	_expect(is_equal_approx(float(converted["money"]), 4321.0))
	_expect(int(converted["simulation_speed"]) == 2)
	_expect(int(converted["lines"]["line1"]["stop_count"]) == 4)
	_expect(int(converted["lines"]["line1"]["fleet_count"]) == 2)
	_expect(is_equal_approx(float(converted["lines"]["line1"]["waiting_by_stop"][0][1]), 2.0))
	_expect(int(converted["stations"]["market-square"]["level"]) == 2)
	_expect(int(converted["depot"]["garage_slots"]) == 8)
	_expect(int(converted["city"]["seed"]) == Data.DEFAULT_CITY_SEED)
	_expect(is_equal_approx(float(converted["city"]["time_seconds"]), 33.0))
