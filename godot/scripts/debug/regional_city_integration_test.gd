extends SceneTree

const CityRuntime = preload("res://scripts/city/city_runtime.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const CityServices = preload("res://scripts/city/city_services.gd")

var _failures := 0


func _init() -> void:
	var city := CityRuntime.create_initial_city(731945, MapDefinition.DEFAULT_MAP_ID)
	var map_bounds := MapDefinition.bounds_for(MapDefinition.DEFAULT_MAP_ID)
	_expect(str(city.get("world_map_id", "")) == MapDefinition.DEFAULT_MAP_ID, "starter map identity is stored in city state")
	_expect(int(city.get("generator_version", 0)) == MapDefinition.GENERATOR_VERSION, "generator version is stored in city state")
	_expect(is_equal_approx(map_bounds.size.x, 24000.0) and is_equal_approx(map_bounds.size.y, 24000.0), "starter region uses the 24 km x 24 km world scale")
	_expect((city.get("regional_settlements", []) as Array).size() == 7, "starter region contains its seven settlements")
	_expect((city.get("outside_connections", []) as Array).size() == 4, "starter region connects to four external gateways")

	var total_population := int((city.get("demographics", {}) as Dictionary).get("residents", 0))
	_expect(total_population >= 12000 and total_population <= 22000, "starter population is plausible for seven small settlements")
	var largest_population := 0
	var largest_radius := 0.0
	for settlement in city.get("regional_settlements", []):
		var population := int(settlement.get("population", 0))
		largest_population = maxi(largest_population, population)
		largest_radius = maxf(largest_radius, float(settlement.get("built_up_radius_m", 0.0)))
		_expect(population <= 5000, "no starter settlement exceeds 5000 residents")
	_expect(largest_population >= 4200, "the regional hub is still meaningfully larger than surrounding settlements")
	_expect(largest_radius >= 900.0, "the largest settlement occupies a realistic kilometre-scale footprint")

	var building_count := (city.get("buildings", []) as Array).size()
	var parcel_count := (city.get("parcels", []) as Array).size()
	_expect(building_count >= 300, "existing settlements materialize as hundreds of representative buildings")
	_expect(parcel_count > building_count, "starter settlements retain vacant development capacity")
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
	var built_regional_road_count := 0
	for road in city.get("roads", []):
		if str(road.get("source", "")) == "regional-existing":
			regional_road_count += 1
			if str(road.get("status", "")) == "built":
				built_regional_road_count += 1
			_expect(road.get("profile", {}).get("road_class", "") in ["local", "collector", "arterial"], "regional road has a semantic profile")
	_expect(regional_road_count >= 60, "larger settlements create a substantial local and regional road network")
	_expect(built_regional_road_count == regional_road_count, "historic starter roads exist before the player arrives")
	if _failures > 0:
		push_error("REGIONAL CITY INTEGRATION TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL CITY INTEGRATION TEST: PASS (%d regional roads, %d buildings)" % [
		regional_road_count,
		building_count,
	])
	quit(0)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional city integration: %s" % message)
