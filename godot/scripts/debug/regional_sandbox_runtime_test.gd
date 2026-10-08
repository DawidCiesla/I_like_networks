extends SceneTree

const CityRuntime = preload("res://scripts/city/city_runtime.gd")
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
	_test_growth_is_deterministic_without_transit()
	_test_transit_changes_growth_priority_without_becoming_required()
	_test_mixed_use_growth_splits_population_and_jobs()
	_test_inaccessible_sites_do_not_grow()
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
	_expect(local_road_count > built_local_road_count, "some regional local streets remain growth capacity")

	var built_parcels := 0
	var vacant_parcels := 0
	for parcel in city.get("parcels", []):
		_expect(parcel.has("source") and parcel.has("status"), "regional parcels record source and status")
		if str(parcel.get("status", "")) == "built":
			built_parcels += 1
		elif str(parcel.get("status", "")) == "vacant":
			vacant_parcels += 1
	_expect(built_parcels > 0, "the regional core starts lived in")
	_expect(vacant_parcels > 0, "the region keeps vacant building capacity")
	_expect(city.get("buildings", []).size() < city.get("parcels", []).size(), "not every parcel starts built")
	for building in city.get("buildings", []):
		_expect(building.has("source") and building.has("status"), "initial buildings record source and status")
	for block in city.get("blocks", []):
		_expect(block.has("source") and block.has("status"), "regional blocks record source and status")


func _test_growth_is_deterministic_without_transit() -> void:
	var initial_city := CityRuntime.create_initial_city(731945, MapDefinition.DEFAULT_MAP_ID)
	_enable_core_local_roads(initial_city)
	var one_chunk := _make_store(initial_city)
	var two_chunks := _make_store(initial_city)
	var initial_built := _built_parcel_ids(one_chunk.city)
	var initial_demographics: Dictionary = one_chunk.city.get("demographics", {}).duplicate(true)
	var initial_settlement_totals := _settlement_totals(one_chunk.city)
	var interval := CityRuntime.REGIONAL_GROWTH_INTERVAL_SECONDS
	CityRuntime.advance(one_chunk, interval * 2.0)
	CityRuntime.advance(two_chunks, interval)
	CityRuntime.advance(two_chunks, interval)
	_expect(one_chunk.transit_network.is_empty() and two_chunks.transit_network.is_empty(), "growth test has no transit service")
	_expect(int(one_chunk.city.get("regional_auto_growth_count", 0)) > 0, "road-connected sites grow without transit")
	_expect(_built_parcel_ids(one_chunk.city) != initial_built, "growth occupies a previously vacant parcel")
	_expect(_built_parcel_ids(one_chunk.city) == _built_parcel_ids(two_chunks.city), "growth order is independent of frame delta chunks")
	_expect(one_chunk.city.get("demographics", {}) == two_chunks.city.get("demographics", {}), "aggregate demographics are independent of frame delta chunks")
	_expect(_settlement_totals(one_chunk.city) == _settlement_totals(two_chunks.city), "settlement totals are independent of frame delta chunks")
	_expect(
		int(one_chunk.city.get("demographics", {}).get("residents", 0)) > int(initial_demographics.get("residents", 0)),
		"residential growth increases aggregate residents"
	)
	_expect(
		int(one_chunk.city.get("demographics", {}).get("jobs", 0)) > int(initial_demographics.get("jobs", 0)),
		"commercial growth increases aggregate jobs"
	)
	_expect(
		int(one_chunk.city.get("demographics", {}).get("students", 0)) == int(round(float(one_chunk.city["demographics"]["residents"]) * 0.16)),
		"student aggregate follows regional residents"
	)
	var center_id := str(one_chunk.city["regional_settlements"][0].get("id", ""))
	var grown_center: Dictionary = _settlement_totals(one_chunk.city).get(center_id, {})
	var initial_center: Dictionary = initial_settlement_totals.get(center_id, {})
	_expect(int(grown_center.get("population", 0)) > int(initial_center.get("population", 0)), "growth updates the correct settlement population")
	_expect(int(grown_center.get("jobs", 0)) > int(initial_center.get("jobs", 0)), "growth updates the correct settlement jobs")
	_expect(int(one_chunk.city.get("regional_auto_growth_count", 0)) <= CityRuntime.MAX_REGIONAL_AUTONOMOUS_BUILDINGS, "autonomous growth stays capped")
	for building in one_chunk.city.get("buildings", []):
		if str(building.get("source", "")) == "city":
			_expect(str(building.get("status", "")) == "built", "grown building uses an explicit completed status")
	one_chunk.free()
	two_chunks.free()


func _test_transit_changes_growth_priority_without_becoming_required() -> void:
	var city := CityRuntime.create_initial_city(731945, MapDefinition.DEFAULT_MAP_ID)
	var template: Dictionary = {}
	for parcel in city.get("parcels", []):
		if str(parcel.get("status", "")) == "vacant" and CityRuntime._regional_parcel_has_strategic_access(city, parcel):
			template = parcel
			break
	_expect(not template.is_empty(), "priority test finds a road-connected growth site")
	if template.is_empty():
		return
	for parcel in city.get("parcels", []):
		if str(parcel.get("status", "")) == "vacant":
			parcel["growthOrder"] = 1000
			parcel["developmentOrder"] = 1000.0
	var earlier_without_transit := template.duplicate(true)
	earlier_without_transit["id"] = "priority-earlier-without-transit"
	earlier_without_transit["growthOrder"] = 10
	earlier_without_transit["developmentOrder"] = 10.0
	earlier_without_transit["x"] = 1000.0
	earlier_without_transit["y"] = 0.0
	var later_with_transit := template.duplicate(true)
	later_with_transit["id"] = "priority-later-with-transit"
	later_with_transit["growthOrder"] = 15
	later_with_transit["developmentOrder"] = 15.0
	later_with_transit["x"] = 0.0
	later_with_transit["y"] = 0.0
	city["parcels"].append(earlier_without_transit)
	city["parcels"].append(later_with_transit)
	var no_transit_store := _make_store(city)
	var transit_store := _make_store(city)
	transit_store.transit_network = {
		"stops": {
			"growth-stop": {"status": "built", "served_line_ids": ["test-line"], "x": 0.0, "y": 0.0},
		},
	}
	var no_transit_choice: Dictionary = CityRuntime._next_regional_growth_candidate(no_transit_store)
	var transit_choice: Dictionary = CityRuntime._next_regional_growth_candidate(transit_store)
	_expect(str(no_transit_choice.get("id", "")) == "priority-earlier-without-transit", "stable base priority applies without transit")
	_expect(str(transit_choice.get("id", "")) == "priority-later-with-transit", "stop accessibility measurably raises a site's priority")
	no_transit_store.free()
	transit_store.free()


func _test_mixed_use_growth_splits_population_and_jobs() -> void:
	var contribution := CityRuntime._regional_growth_contribution({"zone": "mixed"}, {"density": 2})
	_expect(int(contribution.get("residents", 0)) == CityRuntime.REGIONAL_MIXED_RESIDENTS_PER_DENSITY * 2, "mixed use adds its documented resident share")
	_expect(int(contribution.get("jobs", 0)) == CityRuntime.REGIONAL_MIXED_JOBS_PER_DENSITY * 2, "mixed use adds its documented job share")
	var residential := CityRuntime._regional_growth_contribution({"zone": "residential"}, {"density": 1, "kind": "house"})
	var commercial := CityRuntime._regional_growth_contribution({"zone": "commercial"}, {"density": 1, "kind": "shop"})
	_expect(int(residential.get("residents", 0)) > 0 and int(residential.get("jobs", 0)) == 0, "residential profiles add inhabitants")
	_expect(int(commercial.get("jobs", 0)) > 0 and int(commercial.get("residents", 0)) == 0, "commercial profiles add jobs")


func _test_inaccessible_sites_do_not_grow() -> void:
	var city := CityRuntime.create_initial_city(731945, MapDefinition.DEFAULT_MAP_ID)
	for road in city.get("roads", []):
		if str(road.get("regionalRole", "")) in ["spine", "loop", "external_branch", "city_connector"]:
			road["status"] = "planned"
			road["constructionProgress"] = 0.0
	var store := _make_store(city)
	var initial_built := _built_parcel_ids(store.city)
	CityRuntime.advance(store, CityRuntime.REGIONAL_GROWTH_INTERVAL_SECONDS * 3.0)
	_expect(_built_parcel_ids(store.city) == initial_built, "a site without completed strategic road access stays vacant")
	_expect(int(store.city.get("regional_auto_growth_count", 0)) == 0, "inaccessible sites do not count as growth")
	store.free()


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
	store.transit_network = {}
	return store


func _built_parcel_ids(city: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for parcel in city.get("parcels", []):
		if str(parcel.get("status", "")) == "built":
			result.append(str(parcel.get("id", "")))
	result.sort()
	return result


func _enable_core_local_roads(city: Dictionary) -> void:
	var core_id := str(city.get("regional_settlements", [])[0].get("id", ""))
	for road in city.get("roads", []):
		if str(road.get("regionalRole", "")) == "local_street" and str(road.get("settlementId", "")) == core_id:
			road["status"] = "built"
			road["constructionProgress"] = 1.0


func _settlement_totals(city: Dictionary) -> Dictionary:
	var totals: Dictionary = {}
	for settlement in city.get("regional_settlements", []):
		totals[str(settlement.get("id", ""))] = {
			"population": int(settlement.get("population", 0)),
			"jobs": int(settlement.get("jobs", 0)),
		}
	return totals


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional sandbox runtime: %s" % message)
