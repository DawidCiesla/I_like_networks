extends SceneTree

const CityRuntime = preload("res://scripts/city/city_runtime.gd")
const RegionalGrowth = preload("res://scripts/city/regional_growth_system.gd")
const PlanGenerator = preload("res://scripts/city/city_plan_generator.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")

class SandboxStore:
	extends Node
	var city_seed := 731945
	var city: Dictionary = {}
	var world_map: Dictionary = {}
	var lines: Dictionary = {}
	var depot: Dictionary = {}
	var transit_network: Dictionary = {}
	var suppress_persistence := true

var _failures := 0


func _init() -> void:
	_test_starter_region_is_isolated_and_has_growth_capacity()
	_test_runtime_uses_only_organic_growth()
	_test_mixed_use_growth_splits_population_and_jobs()
	_test_legacy_city_uses_unchanged_plan()
	if _failures > 0:
		push_error("REGIONAL SANDBOX RUNTIME TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL SANDBOX RUNTIME TEST: PASS")
	quit(0)


func _test_starter_region_is_isolated_and_has_growth_capacity() -> void:
	var city := CityRuntime.create_initial_city(731945, MapDefinition.DEFAULT_MAP_ID)
	_expect(str(city.get("world_map_id", "")) == MapDefinition.DEFAULT_MAP_ID, "starter region is recorded")
	var legacy_district_ids := [
		"oldTown", "market", "park", "university", "central", "riverside", "museum",
		"harbor", "northQuarter", "hillcrest", "northgate", "meadowEnd", "docklands",
		"eastgate", "stadium",
	]
	for district in city.get("districts", []):
		_expect(str(district.get("id", "")) not in legacy_district_ids, "Bus Era fixed districts are absent")
		_expect(district.has("source") and district.has("status"), "regional districts record source and status")
	for settlement in city.get("regional_settlements", []):
		_expect(settlement.has("source") and settlement.has("status"), "regional settlements record source and status")
	for connection in city.get("outside_connections", []):
		_expect(connection.has("source") and connection.has("status"), "regional gateways record source and status")

	var local_road_count := 0
	var built_local_road_count := 0
	for road in city.get("roads", []):
		var source := str(road.get("source", ""))
		var road_id := str(road.get("id", ""))
		_expect(source not in ["existing-arterial", "transport-corridor", "depot-access"], "Bus Era corridors are absent")
		_expect(not road_id.begins_with("arterial-") and not road_id.begins_with("depot-access-"), "legacy road IDs are absent")
		_expect(road.has("source") and road.has("status"), "regional roads record source and status")
		if str(road.get("regionalRole", "")) == "local_street":
			local_road_count += 1
			if str(road.get("status", "")) == "built":
				built_local_road_count += 1
	_expect(local_road_count == built_local_road_count, "historic local streets already exist when the game starts")

	var built_parcels := 0
	var vacant_parcels := 0
	for parcel in city.get("parcels", []):
		_expect(parcel.has("source") and parcel.has("status"), "regional parcels record source and status")
		if str(parcel.get("status", "")) == "built":
			built_parcels += 1
		elif str(parcel.get("status", "")) == "vacant":
			vacant_parcels += 1
	_expect(built_parcels > 0, "the regional settlements start lived in")
	_expect(vacant_parcels > 0, "the region keeps vacant building capacity")
	_expect(city.get("buildings", []).size() < city.get("parcels", []).size(), "not every parcel starts built")
	_expect(city.has("organic_growth"), "regional starter initializes the organic growth controller")
	_expect(city.has("highway_planning"), "regional starter initializes highway planning")


func _test_runtime_uses_only_organic_growth() -> void:
	var city := CityRuntime.create_initial_city(731945, MapDefinition.DEFAULT_MAP_ID)
	var store := _make_store(city)
	_add_served_stop_to_hub(store)
	var organic_before: Dictionary = store.city.get("organic_growth", {}).duplicate(true)
	var tick_before := int(organic_before.get("tick", 0))
	var legacy_count_before := int(store.city.get("regional_auto_growth_count", 0))
	var legacy_accumulator_before := float(store.city.get("regional_growth_accumulator_seconds", 0.0))
	var roads_before := _organic_road_ids(store.city)

	CityRuntime.advance(store, CityRuntime.REGIONAL_ORGANIC_GROWTH_INTERVAL_SECONDS * 2.0)

	var organic_after: Dictionary = store.city.get("organic_growth", {})
	_expect(
		int(organic_after.get("tick", 0)) == tick_before + 2,
		"CityRuntime advances the organic regional controller exactly once per organic tick"
	)
	_expect(
		int(store.city.get("regional_auto_growth_count", 0)) == legacy_count_before,
		"legacy autonomous regional growth count stays frozen"
	)
	_expect(
		is_equal_approx(float(store.city.get("regional_growth_accumulator_seconds", 0.0)), legacy_accumulator_before),
		"legacy regional growth accumulator stays frozen"
	)
	_expect(_organic_road_ids(store.city) != roads_before, "served runtime growth creates physical organic infrastructure")
	for building_value in store.city.get("buildings", []):
		var building: Dictionary = building_value
		_expect(
			not (str(building.get("source", "")) == "city" and building.has("growthTick")),
			"legacy auto-growth does not create a second competing growth building"
		)
	store.free()


func _test_mixed_use_growth_splits_population_and_jobs() -> void:
	var contribution := RegionalGrowth._profile_contribution("mixed", {"kind": "apartment", "floors": 2, "density": 2})
	_expect(int(contribution.get("residents", 0)) == 36, "mixed organic growth adds its resident share")
	_expect(int(contribution.get("jobs", 0)) == 16, "mixed organic growth adds its job share")
	var residential := RegionalGrowth._profile_contribution("residential", {"kind": "house", "floors": 1, "density": 1})
	var commercial := RegionalGrowth._profile_contribution("commercial", {"kind": "shop", "floors": 1, "density": 1})
	_expect(int(residential.get("residents", 0)) > 0 and int(residential.get("jobs", 0)) == 0, "residential profiles add inhabitants")
	_expect(int(commercial.get("jobs", 0)) > 0 and int(commercial.get("residents", 0)) == 0, "commercial profiles add jobs")


func _test_legacy_city_uses_unchanged_plan() -> void:
	var seed := 731945
	var expected := PlanGenerator.generate(seed)
	var legacy := CityRuntime.create_initial_city(seed, MapDefinition.LEGACY_CITY_MAP_ID)
	_expect(legacy.get("roads", []) == expected.get("roads", []), "legacy road plan remains unchanged")
	_expect(legacy.get("districts", []) == expected.get("districts", []), "legacy district plan remains unchanged")
	_expect(legacy.get("blocks", []) == expected.get("blocks", []), "legacy block plan remains unchanged")
	_expect(legacy.get("parcels", []) == expected.get("parcels", []), "legacy parcel plan remains unchanged")
	_expect(legacy.get("buildings", []).is_empty(), "legacy buildings are still created through the old runtime flow")


func _make_store(city: Dictionary) -> SandboxStore:
	var store := SandboxStore.new()
	store.suppress_persistence = true
	store.city_seed = int(city.get("seed", 731945))
	store.world_map = MapDefinition.create(MapDefinition.DEFAULT_MAP_ID, store.city_seed)
	store.city = city.duplicate(true)
	store.lines = {
		"line1": {"built": false, "stop_count": 1, "fleet_count": 0, "last_delivered_ppm": 0.0},
		"line2": {"built": false, "stop_count": 0, "fleet_count": 0, "last_delivered_ppm": 0.0},
		"line3": {"built": false, "stop_count": 0, "fleet_count": 0, "last_delivered_ppm": 0.0},
		"line4": {"built": false, "stop_count": 0, "fleet_count": 0, "last_delivered_ppm": 0.0},
	}
	store.depot = {"built": false}
	store.transit_network = {"stops": {}, "lines": {}}
	return store


func _add_served_stop_to_hub(store: SandboxStore) -> void:
	var hub: Dictionary = store.city.get("regional_settlements", [])[0]
	var position: Vector2 = hub.get("position", Vector2.ZERO)
	store.transit_network = {
		"stops": {
			"runtime-growth-stop": {
				"id": "runtime-growth-stop",
				"status": "built",
				"served_line_ids": ["runtime-growth-line"],
				"x": position.x,
				"y": position.y,
			},
		},
		"lines": {
			"runtime-growth-line": {
				"id": "runtime-growth-line",
				"status": "active",
				"stop_ids": ["runtime-growth-stop"],
			},
		},
	}


func _organic_road_ids(city: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("source", "")) == "organic-growth":
			result.append(str(road.get("id", "")))
	result.sort()
	return result


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional sandbox runtime: %s" % message)
