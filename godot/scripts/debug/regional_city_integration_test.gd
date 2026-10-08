extends SceneTree

const CityRuntime = preload("res://scripts/city/city_runtime.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const CityServices = preload("res://scripts/city/city_services.gd")

var _failures := 0


func _init() -> void:
	var city := CityRuntime.create_initial_city(731945, MapDefinition.DEFAULT_MAP_ID)
	_expect(str(city.get("world_map_id", "")) == MapDefinition.DEFAULT_MAP_ID, "starter map identity is stored in city state")
	_expect(int(city.get("generator_version", 0)) == MapDefinition.GENERATOR_VERSION, "generator version is stored in city state")
	_expect((city.get("regional_settlements", []) as Array).size() == 7, "starter region contains its seven settlements")
	_expect((city.get("outside_connections", []) as Array).size() == 4, "starter region connects to four external gateways")
	_expect((city.get("demographics", {}) as Dictionary).get("residents", 0) > 80000, "population is aggregated at regional scale")
	_expect(
		(city.get("buildings", []) as Array).size() == CityRuntime.REGIONAL_CORE_BUILDING_COUNT,
		"starter region begins with only its small lived-in core"
	)
	_expect((city.get("parcels", []) as Array).size() >= (city.get("buildings", []) as Array).size(), "each generated building has a parcel")
	_expect((city.get("service_demand_points", []) as Array).size() == 7, "services use aggregate settlement demand points")
	_expect((city.get("service_buildings", []) as Array).size() == 42, "regional service capacity is attached to existing settlements")
	var service_results: Dictionary = city.get("service_results", {})
	var services: Dictionary = service_results.get("services", {})
	var service_totals: Dictionary = services.get("totals", {})
	_expect(float(service_totals.get("total", {}).get("demand", 0.0)) > 0.0, "facility catchment evaluation records service demand")
	var utilities: Dictionary = service_results.get("utilities", {})
	for utility_type in CityServices.UTILITY_TYPES:
		_expect(float(utilities.get(utility_type, {}).get("requested", 0.0)) > 0.0, "%s network records aggregate demand" % utility_type)
	var regional_road_count := 0
	for road in city.get("roads", []):
		if str(road.get("source", "")) == "regional-existing":
			regional_road_count += 1
			_expect(road.get("profile", {}).get("road_class", "") in ["local", "collector", "arterial"], "regional road has a semantic profile")
	_expect(regional_road_count >= 30, "hierarchical and local regional roads join the city road model")
	if _failures > 0:
		push_error("REGIONAL CITY INTEGRATION TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL CITY INTEGRATION TEST: PASS (%d regional roads, %d buildings)" % [
		regional_road_count,
		(city.get("buildings", []) as Array).size(),
	])
	quit(0)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional city integration: %s" % message)
