extends SceneTree

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const Terrain = preload("res://scripts/world/terrain_model.gd")
const StoreScript = preload("res://scripts/core/game_store.gd")

func _init() -> void:
	_test_shared_interchanges()
	_test_route_geometry()
	_test_terrain_determinism()
	_test_arrival_fare_simulation()
	_test_master_plan_fixture()
	_test_city_growth_runtime()
	print("GODOT PORT SELF-TEST: PASS")
	quit(0)

func _test_shared_interchanges() -> void:
	assert(Data.STATION_IDS.line1[2] == Data.STATION_IDS.line2[0])
	assert(Data.STATION_IDS.line1[3] == Data.STATION_IDS.line3[0])
	assert(Data.STATION_IDS.line2[3] == Data.STATION_IDS.line4[0])
	assert(Data.STATION_IDS.line1[4] == Data.STATION_IDS.line4[4])

func _test_route_geometry() -> void:
	for line_key in Data.LINE_KEYS:
		var max_stops := int(Data.LINE_CONFIG[line_key].max_stops)
		var route := Layout.built_route(line_key, max_stops)
		assert(route.size() >= 2)
		assert(Layout.route_length(route) > 300.0)

	for line_key in ["line3", "line4"]:
		var segments: Array = Layout.BASE_SEGMENTS[line_key]
		for segment_index in range(segments.size()):
			var points := Layout.segment_points(line_key, segment_index)
			var distance := Layout.route_length(points)
			assert(distance >= 350.0)
			assert(distance <= 1250.0)

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
		assert(is_equal_approx(first, second))

		var slope := Terrain.slope_degrees(Data.DEFAULT_CITY_SEED, point.x, point.y)
		assert(is_finite(slope))
		assert(slope >= 0.0)

		var forest := Terrain.forest_potential(Data.DEFAULT_CITY_SEED, point.x, point.y)
		assert(forest >= 0.0 and forest <= 1.0)


func _test_arrival_fare_simulation() -> void:
	var store = StoreScript.new()
	store.suppress_persistence = true
	store.reset_state(false)
	store.money = 10_000.0

	var before := store.money
	assert(store.build_next_stop("line1"))
	assert(bool(store.lines["line1"]["built"]))
	assert(int(store.lines["line1"]["fleet_count"]) == 1)
	assert(float(store.stats["lifetime_revenue"]) == 0.0)

	var after_purchase := store.money
	assert(after_purchase < before)

	store._advance_simulation(0.5)
	assert(is_equal_approx(store.money, after_purchase))

	var guard := 0
	while float(store.stats["lifetime_revenue"]) <= 0.0 and guard < 1000:
		store._advance_simulation(0.1)
		guard += 1

	assert(guard < 1000)
	assert(float(store.stats["lifetime_revenue"]) > 0.0)
	assert(float(store.stats["lifetime_passengers"]) > 0.0)

	var market_before := store.station_capacity("market-square")
	assert(store.upgrade_station("market-square"))
	assert(store.station_capacity("market-square") > market_before)
	assert(store.station_level("old-town") == 0)

	store.free()


func _test_master_plan_fixture() -> void:
	var file := FileAccess.open("res://data/master_plan_284731.json", FileAccess.READ)
	assert(file != null)

	var parsed = JSON.parse_string(file.get_as_text())
	assert(typeof(parsed) == TYPE_DICTIONARY)
	assert(int(parsed["seed"]) == Data.DEFAULT_CITY_SEED)
	assert(parsed["districts"].size() == 15)
	assert(parsed["roads"].size() == 105)
	assert(parsed["graphEdges"].size() == 342)
	assert(parsed["junctions"].size() == 92)
	assert(parsed["parcels"].size() == 161)


func _test_city_growth_runtime() -> void:
	var store = StoreScript.new()
	store.suppress_persistence = true
	store.reset_state(false)
	store.money = 100_000.0

	assert(store.build_next_stop("line1"))

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

	assert(active_districts >= 2)
	assert(built_roads >= 2)
	assert(store.city["buildings"].size() > 0)
	assert(active_projects <= 2)

	for building in store.city["buildings"]:
		assert(float(building["profile"]["heightMeters"]) > 0.0)
		assert(is_finite(float(building["rotationRadians"])))

	store.free()
