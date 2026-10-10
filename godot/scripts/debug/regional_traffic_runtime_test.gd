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


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional traffic runtime: %s" % message)
