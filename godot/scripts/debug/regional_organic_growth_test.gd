extends SceneTree

const CityRuntime = preload("res://scripts/city/city_runtime.gd")
const RegionalGrowth = preload("res://scripts/city/regional_growth_system.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")

class GrowthStore:
	extends Node
	var city_seed := 731945
	var city: Dictionary = {}
	var transit_network: Dictionary = {}

var _failures := 0


func _init() -> void:
	_test_starter_hierarchy()
	_test_unserved_region_stays_slow()
	_test_transit_drives_physical_expansion()
	_test_growth_is_deterministic()
	if _failures > 0:
		push_error("REGIONAL ORGANIC GROWTH TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL ORGANIC GROWTH TEST: PASS")
	quit(0)


func _test_starter_hierarchy() -> void:
	var store := _make_store()
	var settlements: Array = store.city.get("regional_settlements", [])
	_expect(settlements.size() >= 5, "starter region contains one town and several surrounding villages")
	var town_count := 0
	var village_count := 0
	for settlement_value in settlements:
		var settlement: Dictionary = settlement_value
		var population := int(settlement.get("population", 0))
		var role := str(settlement.get("starter_role", ""))
		if role == "town":
			town_count += 1
			_expect(population >= 3000 and population <= 5000, "the single starter town stays in the intended 3-5k range")
			_expect(str(settlement.get("tier", "")) == "market", "starter town uses the market-town morphology tier")
		elif role == "village":
			village_count += 1
			_expect(population <= 1500, "every surrounding starter settlement is a village below 1.5k")
			_expect(str(settlement.get("tier", "")) == "village", "satellites use village morphology rather than town morphology")
		else:
			_expect(false, "every starter settlement has an explicit town/village role")
	_expect(town_count == 1, "starter region has exactly one town")
	_expect(village_count == settlements.size() - 1, "all remaining starter settlements are villages")
	store.free()


func _test_unserved_region_stays_slow() -> void:
	var store := _make_store()
	var roads_before: int = (store.city.get("roads", []) as Array).size()
	var parcels_before: int = (store.city.get("parcels", []) as Array).size()
	var population_before: int = _total_population(store.city)
	RegionalGrowth.advance(store, RegionalGrowth.TICK_SECONDS)
	_expect((store.city.get("roads", []) as Array).size() == roads_before, "an unserved region does not immediately sprawl")
	_expect((store.city.get("parcels", []) as Array).size() == parcels_before, "an unserved region keeps its initial footprint after one tick")
	_expect(_total_population(store.city) == population_before, "baseline growth is deliberately slow without transit")
	store.free()


func _test_transit_drives_physical_expansion() -> void:
	var store := _make_store()
	_add_served_stop_to_hub(store)
	var hub_id := str(store.city.get("regional_settlements", [])[0].get("id", ""))
	var roads_before: int = (store.city.get("roads", []) as Array).size()
	var parcels_before: int = (store.city.get("parcels", []) as Array).size()
	var population_before: int = _settlement_population(store.city, hub_id)
	RegionalGrowth.advance(store, RegionalGrowth.TICK_SECONDS * 2.0)
	_expect((store.city.get("roads", []) as Array).size() > roads_before, "served hub creates a new edge street when historical reserve is tight")
	_expect((store.city.get("parcels", []) as Array).size() > parcels_before, "physical expansion creates new developable lots")
	var organic_roads := 0
	for road in store.city.get("roads", []):
		if str(road.get("source", "")) == "organic-growth":
			organic_roads += 1
	_expect(organic_roads > 0, "new growth street is explicitly tracked as organic growth")
	RegionalGrowth.advance(store, RegionalGrowth.TICK_SECONDS * 4.0)
	_expect(_settlement_population(store.city, hub_id) > population_before, "served settlement gains real population after expansion")
	var organic_buildings := 0
	for building in store.city.get("buildings", []):
		if str(building.get("source", "")) == "organic-growth":
			organic_buildings += 1
	_expect(organic_buildings > 0, "new population is represented by physical buildings")
	var hub := _settlement(store.city, hub_id)
	_expect(float(hub.get("built_up_radius_m", 0.0)) > 0.0, "settlement keeps a physical built-up radius")
	_expect(str(hub.get("urbanStage", "")) != "", "settlement exposes its evolving urban stage")
	store.free()


func _test_growth_is_deterministic() -> void:
	var first := _make_store()
	var second := _make_store()
	_add_served_stop_to_hub(first)
	_add_served_stop_to_hub(second)
	RegionalGrowth.advance(first, RegionalGrowth.TICK_SECONDS * 6.0)
	RegionalGrowth.advance(second, RegionalGrowth.TICK_SECONDS * 6.0)
	_expect(_organic_road_ids(first.city) == _organic_road_ids(second.city), "same seed and service produce the same expansion streets")
	_expect(_organic_parcel_ids(first.city) == _organic_parcel_ids(second.city), "same seed and service produce the same expansion parcels")
	_expect(first.city.get("demographics", {}) == second.city.get("demographics", {}), "organic demographics are deterministic")
	first.free()
	second.free()


func _make_store() -> GrowthStore:
	var store := GrowthStore.new()
	store.city_seed = 731945
	store.city = CityRuntime.create_initial_city(store.city_seed, MapDefinition.DEFAULT_MAP_ID)
	store.transit_network = {"stops": {}, "lines": {}}
	return store


func _add_served_stop_to_hub(store: GrowthStore) -> void:
	var hub: Dictionary = store.city.get("regional_settlements", [])[0]
	var position: Vector2 = hub.get("position", Vector2.ZERO)
	store.transit_network = {
		"stops": {
			"regional-growth-stop": {
				"id": "regional-growth-stop",
				"status": "built",
				"served_line_ids": ["regional-growth-line"],
				"x": position.x,
				"y": position.y,
			},
		},
		"lines": {
			"regional-growth-line": {
				"id": "regional-growth-line",
				"status": "active",
				"stop_ids": ["regional-growth-stop"],
			},
		},
	}


func _organic_road_ids(city: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for road in city.get("roads", []):
		if str(road.get("source", "")) == "organic-growth":
			result.append(str(road.get("id", "")))
	result.sort()
	return result


func _organic_parcel_ids(city: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for parcel in city.get("parcels", []):
		if str(parcel.get("source", "")) in ["organic-capacity", "organic-growth"]:
			result.append(str(parcel.get("id", "")))
	result.sort()
	return result


func _total_population(city: Dictionary) -> int:
	var total := 0
	for settlement in city.get("regional_settlements", []):
		total += int(settlement.get("population", 0))
	return total


func _settlement_population(city: Dictionary, settlement_id: String) -> int:
	return int(_settlement(city, settlement_id).get("population", 0))


func _settlement(city: Dictionary, settlement_id: String) -> Dictionary:
	for settlement in city.get("regional_settlements", []):
		if str(settlement.get("id", "")) == settlement_id:
			return settlement
	return {}


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional organic growth: %s" % description)
