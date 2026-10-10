extends SceneTree

const CityRuntime = preload("res://scripts/city/city_runtime.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const RegionalTrafficRuntime = preload("res://scripts/simulation/regional_traffic_runtime.gd")

class TrafficStore:
	extends Node
	var city: Dictionary = {}
	var metrics: Dictionary = {}

	func resident_transport_metrics() -> Dictionary:
		return metrics.duplicate(true)


var _failures := 0


func _init() -> void:
	_test_snapshot_and_road_metrics()
	_test_operational_speed_feedback()
	_test_tick_cadence()
	_test_legacy_city_is_untouched()
	if _failures > 0:
		push_error("REGIONAL TRAFFIC RUNTIME TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL TRAFFIC RUNTIME TEST: PASS")
	quit(0)


func _test_snapshot_and_road_metrics() -> void:
	var store := _regional_store(2600.0)
	var changed := RegionalTrafficRuntime.refresh(store)
	_expect(changed, "first refresh creates a changed traffic snapshot")
	var snapshot: Dictionary = store.city.get("road_traffic", {})
	var demand: Dictionary = snapshot.get("demand", {})
	var summary: Dictionary = snapshot.get("summary", {})
	_expect(int(snapshot.get("revision", 0)) == 1, "first refresh increments traffic revision")
	_expect(float(demand.get("vehicle_trips_per_hour", 0.0)) > 0.0, "resident car trips become vehicle demand")
	_expect(int(demand.get("unresolved_od_pairs", -1)) == 0, "settlement OD endpoints resolve to graph nodes")
	_expect(float(summary.get("assigned_vehicle_demand_vph", 0.0)) > 0.0, "vehicle demand is assigned to the road network")
	_expect(float(summary.get("vehicle_km_per_hour", 0.0)) > 0.0, "snapshot exposes vehicle-km per hour")
	_expect(not (snapshot.get("road_metrics", {}) as Dictionary).is_empty(), "snapshot keeps per-road traffic metrics")
	var roads_with_traffic := 0
	for road_value in store.city.get("roads", []):
		var road: Dictionary = road_value
		if road.has("traffic"):
			roads_with_traffic += 1
	_expect(roads_with_traffic > 0, "traffic metrics are attached to built roads for gameplay inspectors")

	var unchanged := RegionalTrafficRuntime.refresh(store)
	_expect(not unchanged, "identical traffic inputs keep the snapshot revision stable")
	_expect(int(store.city.get("road_traffic", {}).get("revision", 0)) == 1, "stable refresh does not inflate revision")

	store.metrics = _resident_metrics(store.city, 5200.0)
	var demand_changed := RegionalTrafficRuntime.refresh(store)
	_expect(demand_changed, "changed resident demand invalidates the traffic snapshot")
	_expect(int(store.city.get("road_traffic", {}).get("revision", 0)) == 2, "changed traffic increments revision")
	store.free()


func _test_operational_speed_feedback() -> void:
	var store := _regional_store(12000.0)
	RegionalTrafficRuntime.refresh(store)
	var congested_road: Dictionary = {}
	for road_value in store.city.get("roads", []):
		var road: Dictionary = road_value
		var traffic_value: Variant = road.get("traffic", {})
		if typeof(traffic_value) != TYPE_DICTIONARY:
			continue
		var traffic: Dictionary = traffic_value
		if float(traffic.get("delay_minutes", 0.0)) <= 0.0001:
			continue
		congested_road = road
		break
	_expect(not congested_road.is_empty(), "high road demand creates at least one delayed road")
	if congested_road.is_empty():
		store.free()
		return

	var traffic: Dictionary = congested_road.get("traffic", {})
	var free_speed := float(congested_road.get("traffic_free_flow_speed_kph", 0.0))
	var operational_speed := float(traffic.get("operational_speed_kph", 0.0))
	var profile_speed := float(congested_road.get("profile", {}).get("speed_kph", 0.0))
	_expect(free_speed > 0.0, "traffic runtime preserves the physical free-flow road speed")
	_expect(operational_speed >= RegionalTrafficRuntime.MIN_OPERATIONAL_SPEED_KPH, "operational speed respects the minimum traffic speed")
	_expect(operational_speed < free_speed, "congestion lowers the operational road speed")
	_expect(is_equal_approx(profile_speed, operational_speed), "resident routing sees the current operational speed through the road profile")

	var road_id := str(congested_road.get("id", ""))
	RegionalTrafficRuntime._restore_free_flow_speeds(store.city)
	var restored := _road(store.city, road_id)
	_expect(is_equal_approx(float(restored.get("profile", {}).get("speed_kph", 0.0)), free_speed), "assignment restores free-flow speed before computing BPR delay")

	# Reapply the same demand. The solver must start from the preserved design
	# speed and converge back to the same operating state rather than compounding
	# the previous tick's slowdown.
	RegionalTrafficRuntime.refresh(store)
	var repeated := _road(store.city, road_id)
	var repeated_traffic: Dictionary = repeated.get("traffic", {})
	_expect(is_equal_approx(float(repeated.get("traffic_free_flow_speed_kph", 0.0)), free_speed), "free-flow speed stays stable across traffic ticks")
	_expect(is_equal_approx(float(repeated_traffic.get("operational_speed_kph", 0.0)), operational_speed), "identical demand does not compound congestion speed loss")
	store.free()


func _test_tick_cadence() -> void:
	var store := _regional_store(1800.0)
	RegionalTrafficRuntime.ensure(store.city)
	var early := RegionalTrafficRuntime.advance(store, RegionalTrafficRuntime.TICK_SECONDS - 1.0)
	_expect(not early, "traffic runtime does not refresh before its cadence")
	_expect(int(store.city.get("road_traffic", {}).get("revision", 0)) == 0, "pre-tick state remains uncomputed")
	var ticked := RegionalTrafficRuntime.advance(store, 1.0)
	_expect(ticked, "traffic runtime refreshes exactly at its cadence")
	_expect(int(store.city.get("road_traffic", {}).get("revision", 0)) == 1, "traffic cadence creates the first revision")
	store.free()


func _test_legacy_city_is_untouched() -> void:
	var store := TrafficStore.new()
	store.city = CityRuntime.create_initial_city(731945, MapDefinition.LEGACY_CITY_MAP_ID)
	store.metrics = {}
	RegionalTrafficRuntime.ensure(store.city)
	_expect(not store.city.has("road_traffic"), "legacy Bus Era city does not receive regional traffic state")
	_expect(not RegionalTrafficRuntime.advance(store, 120.0), "legacy Bus Era traffic runtime remains inactive")
	store.free()


func _regional_store(car_trips_per_hour: float) -> TrafficStore:
	var store := TrafficStore.new()
	store.city = CityRuntime.create_initial_city(731945, MapDefinition.DEFAULT_MAP_ID)
	store.metrics = _resident_metrics(store.city, car_trips_per_hour)
	return store


func _resident_metrics(city: Dictionary, car_trips_per_hour: float) -> Dictionary:
	var settlements: Array = city.get("regional_settlements", [])
	if settlements.size() < 2:
		return {"od_diagnostics": []}
	var origin: Dictionary = settlements[0]
	var destination: Dictionary = settlements[1]
	return {
		"od_diagnostics": [{
			"od_id": "traffic-runtime-test",
			"origin_id": str(origin.get("id", "")),
			"destination_id": str(destination.get("id", "")),
			"car_trips_per_hour": car_trips_per_hour,
		}],
	}


func _road(city: Dictionary, road_id: String) -> Dictionary:
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("id", "")) == road_id:
			return road
	return {}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional traffic runtime: %s" % message)
