extends SceneTree

const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const RegionalTransitTrafficRuntime = preload("res://scripts/simulation/regional_transit_traffic_runtime.gd")

class TransitStore:
	extends Node
	var city: Dictionary = {}
	var transit_network: Dictionary = {}


var _failures := 0


func _init() -> void:
	_test_bus_segment_slowdown_preserves_progress()
	_test_bus_duration_reacts_to_changed_congestion_without_compounding()
	_test_bus_operations_kpis_reflect_congestion()
	_test_reserved_modes_are_not_slowed()
	_test_reserved_modes_expose_operations_health_without_road_penalty()
	_test_legacy_city_is_untouched()
	if _failures > 0:
		push_error("REGIONAL TRANSIT TRAFFIC RUNTIME TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL TRANSIT TRAFFIC RUNTIME TEST: PASS")
	quit(0)


func _test_bus_segment_slowdown_preserves_progress() -> void:
	var store := _store("bus", 3.0)
	var vehicle := _vehicle(store)
	vehicle["phase_duration_minutes"] = 6.0
	vehicle["phase_minutes_remaining"] = 3.0
	_set_vehicle(store, vehicle)
	var changed := RegionalTransitTrafficRuntime.apply(store)
	vehicle = _vehicle(store)
	_expect(changed, "bus congestion updates the active travel phase")
	_expect(is_equal_approx(float(vehicle.get("phase_duration_minutes", 0.0)), 18.0), "3x road congestion triples the active bus segment duration")
	_expect(is_equal_approx(float(vehicle.get("phase_minutes_remaining", 0.0)), 9.0), "bus retains 50 percent segment progress after congestion adjustment")
	_expect(is_equal_approx(float(vehicle.get("traffic_congestion_factor", 0.0)), 3.0), "vehicle records the applied congestion factor")
	var line := _line(store)
	_expect(is_equal_approx(float(line.get("traffic_delay_factor", 0.0)), 3.0), "line exposes a traffic delay factor for later HUD use")
	_expect(int(line.get("traffic_affected_segment_count", 0)) == 1, "line reports its affected road segment")
	store.free()


func _test_bus_duration_reacts_to_changed_congestion_without_compounding() -> void:
	var store := _store("bus", 3.0)
	var vehicle := _vehicle(store)
	vehicle["phase_duration_minutes"] = 6.0
	vehicle["phase_minutes_remaining"] = 3.0
	_set_vehicle(store, vehicle)
	RegionalTransitTrafficRuntime.apply(store)
	var first := _vehicle(store)
	_expect(is_equal_approx(float(first.get("phase_duration_minutes", 0.0)), 18.0), "initial congestion adjustment is applied")

	var road: Dictionary = store.city["roads"][0]
	road["traffic"]["travel_time_minutes"] = 4.0
	store.city["roads"][0] = road
	RegionalTransitTrafficRuntime.apply(store)
	var second := _vehicle(store)
	_expect(is_equal_approx(float(second.get("phase_duration_minutes", 0.0)), 12.0), "lower congestion updates the target duration from physical nominal time")
	_expect(is_equal_approx(float(second.get("phase_minutes_remaining", 0.0)), 6.0), "lower congestion preserves already completed progress")

	var unchanged := RegionalTransitTrafficRuntime.apply(store)
	var third := _vehicle(store)
	_expect(not unchanged, "reapplying unchanged road traffic does not mutate bus state")
	_expect(is_equal_approx(float(third.get("phase_duration_minutes", 0.0)), 12.0), "bus slowdown does not compound on repeated runtime passes")
	store.free()


func _test_bus_operations_kpis_reflect_congestion() -> void:
	var free_store := _store("bus", 1.0)
	var congested_store := _store("bus", 3.0)
	RegionalTransitTrafficRuntime.apply(free_store)
	RegionalTransitTrafficRuntime.apply(congested_store)
	var free_line := _line(free_store)
	var congested_line := _line(congested_store)
	var free_cycle := float(free_line.get("traffic_effective_cycle_minutes", 0.0))
	var congested_cycle := float(congested_line.get("traffic_effective_cycle_minutes", 0.0))
	var free_headway := float(free_line.get("traffic_effective_headway_minutes", 0.0))
	var congested_headway := float(congested_line.get("traffic_effective_headway_minutes", 0.0))
	var free_capacity := float(free_line.get("traffic_effective_capacity_ppm", 0.0))
	var congested_capacity := float(congested_line.get("traffic_effective_capacity_ppm", 0.0))
	_expect(free_cycle > 0.0, "bus runtime exposes an effective cycle time")
	_expect(congested_cycle > free_cycle, "road congestion lengthens the effective bus cycle")
	_expect(congested_headway > free_headway, "same fleet produces a worse headway in congestion")
	_expect(congested_capacity < free_capacity, "congestion reduces effective passenger throughput per minute")
	free_store.free()
	congested_store.free()


func _test_reserved_modes_are_not_slowed() -> void:
	for mode in ["tram", "metro"]:
		var store := _store(mode, 4.0)
		var before := _vehicle(store)
		var changed := RegionalTransitTrafficRuntime.apply(store)
		var after := _vehicle(store)
		_expect(not changed, "%s does not inherit mixed-traffic bus delay" % mode)
		_expect(is_equal_approx(float(after.get("phase_duration_minutes", 0.0)), float(before.get("phase_duration_minutes", 0.0))), "%s keeps its independent right-of-way travel time" % mode)
		_expect(not after.has("traffic_congestion_factor"), "%s vehicle carries no mixed-traffic congestion tag" % mode)
		store.free()


func _test_reserved_modes_expose_operations_health_without_road_penalty() -> void:
	for mode in ["tram", "metro"]:
		var free_store := _store(mode, 1.0)
		var congested_store := _store(mode, 4.0)
		for store in [free_store, congested_store]:
			var line: Dictionary = _line(store)
			line["current_demand_ppm"] = 2.0
			line["target_headway_minutes"] = 5.0
			store.transit_network["lines"]["line-a"] = line
			RegionalTransitTrafficRuntime.apply(store)
		var free_line := _line(free_store)
		var congested_line := _line(congested_store)
		var free_health: Dictionary = free_line.get("operations_health", {})
		var congested_health: Dictionary = congested_line.get("operations_health", {})
		_expect(is_equal_approx(float(free_line.get("traffic_delay_factor", 0.0)), 1.0), "%s operations telemetry is explicitly road-delay independent" % mode)
		_expect(is_equal_approx(float(congested_line.get("traffic_delay_factor", 0.0)), 1.0), "%s stays delay factor 1.0 even beside a 4x congested road" % mode)
		_expect(int(congested_line.get("traffic_affected_segment_count", -1)) == 0, "%s reports zero road-affected segments" % mode)
		_expect(float(free_line.get("traffic_effective_cycle_minutes", 0.0)) > 0.0, "%s exposes a native effective cycle" % mode)
		_expect(is_equal_approx(float(free_line.get("traffic_effective_cycle_minutes", 0.0)), float(congested_line.get("traffic_effective_cycle_minutes", -1.0))), "%s cycle is unchanged by road congestion" % mode)
		_expect(is_equal_approx(float(free_line.get("traffic_effective_headway_minutes", 0.0)), float(congested_line.get("traffic_effective_headway_minutes", -1.0))), "%s headway is unchanged by road congestion" % mode)
		_expect(float(free_line.get("traffic_effective_capacity_ppm", 0.0)) > 0.0, "%s exposes native passenger throughput" % mode)
		_expect(not free_health.is_empty(), "%s now exposes operations health" % mode)
		_expect(bool(free_health.get("target_headway_active", false)), "%s operations health consumes the explicit service target" % mode)
		_expect(str(free_health.get("status", "")).length() > 0, "%s operations health has a gameplay status" % mode)
		_expect(str(free_health.get("status", "")) == str(congested_health.get("status", "different")), "%s health classification is not changed by adjacent road congestion" % mode)
		free_store.free()
		congested_store.free()


func _test_legacy_city_is_untouched() -> void:
	var store := _store("bus", 4.0)
	store.city["world_map_id"] = MapDefinition.LEGACY_CITY_MAP_ID
	var before := _vehicle(store)
	_expect(not RegionalTransitTrafficRuntime.apply(store), "legacy Bus Era skips regional transit traffic runtime")
	var after := _vehicle(store)
	_expect(is_equal_approx(float(after.get("phase_duration_minutes", 0.0)), float(before.get("phase_duration_minutes", 0.0))), "legacy bus timing remains unchanged")
	store.free()


func _store(mode: String, congestion_factor: float) -> TransitStore:
	var store := TransitStore.new()
	store.city = {
		"world_map_id": MapDefinition.DEFAULT_MAP_ID,
		"roads": [{
			"id": "road-a",
			"status": "built",
			"traffic": {
				"free_flow_minutes": 2.0,
				"travel_time_minutes": 2.0 * congestion_factor,
				"delay_minutes": 2.0 * maxf(0.0, congestion_factor - 1.0),
			},
		}],
	}
	store.transit_network = {
		"stops": {
			"stop-a": {"id": "stop-a", "level": 0, "status": "built"},
			"stop-b": {"id": "stop-b", "level": 0, "status": "built"},
		},
		"lines": {
			"line-a": {
				"id": "line-a",
				"source": "custom",
				"status": "active",
				"mode": mode,
				"stop_ids": ["stop-a", "stop-b"],
				"fleet_count": 1,
				"route_segments": [{
					"length_world": 1800.0,
					"road_ids": ["road-a"],
				}],
				"vehicles": [{
					"id": 1,
					"phase": "travel",
					"current_stop_index": 0,
					"next_stop_index": 1,
					"phase_duration_minutes": 6.0,
					"phase_minutes_remaining": 6.0,
				}],
			},
		},
	}
	return store


func _line(store: TransitStore) -> Dictionary:
	return store.transit_network.get("lines", {}).get("line-a", {})


func _vehicle(store: TransitStore) -> Dictionary:
	var vehicles: Array = _line(store).get("vehicles", [])
	return vehicles[0].duplicate(true) if not vehicles.is_empty() else {}


func _set_vehicle(store: TransitStore, vehicle: Dictionary) -> void:
	var network := store.transit_network
	var lines: Dictionary = network.get("lines", {})
	var line: Dictionary = lines.get("line-a", {})
	line["vehicles"] = [vehicle]
	lines["line-a"] = line
	network["lines"] = lines
	store.transit_network = network


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional transit traffic runtime: %s" % message)
