extends SceneTree

const RegionalProgressionRuntime = preload("res://scripts/city/regional_progression_runtime.gd")

class ProgressStore:
	extends Node
	var money := 50000.0
	var city: Dictionary = {}
	var transit_network: Dictionary = {"unlocked_modes": {"bus": true}}
	var stats: Dictionary = {
		"lifetime_revenue": 5000.0,
		"lifetime_operating_costs": 7000.0,
		"lifetime_passengers": 120.0,
	}
	var transport: Dictionary = {}
	var health: Dictionary = {}

	func resident_transport_metrics() -> Dictionary:
		return transport

	func resident_health_metrics() -> Dictionary:
		return health

	func transit_mode_status(mode: String) -> Dictionary:
		return {
			"minimum_startup_capital": 80000.0 if mode == "tram" else 300000.0,
			"unlock_cost": 16000.0 if mode == "tram" else 120000.0,
		}


var _failures := 0


func _init() -> void:
	_test_runtime_collects_live_metrics_and_next_goal()
	_test_population_weighted_accessibility()
	if _failures > 0:
		push_error("REGIONAL PROGRESSION RUNTIME TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL PROGRESSION RUNTIME TEST: PASS")
	quit(0)


func _test_runtime_collects_live_metrics_and_next_goal() -> void:
	var store := _store()
	var snapshot := RegionalProgressionRuntime.apply(store)
	var metrics: Dictionary = snapshot.get("metrics", {})
	_expect(float(metrics.get("current_net_per_minute", 0.0)) == 3.0, "runtime feeds Economy V1 live net into progression")
	_expect(float(metrics.get("transit_share", 0.0)) == 0.18, "runtime feeds resident mode share into progression")
	_expect(float(metrics.get("average_mobility_accessibility", 0.0)) > 0.0, "runtime exposes weighted real accessibility")
	_expect(str(snapshot.get("next_objective", {}).get("id", "")) == "passenger_service", "unfinished passenger milestone comes before infrastructure unlock")
	_expect(typeof(store.city.get("progression_v2", null)) == TYPE_DICTIONARY, "apply stores canonical progression snapshot in city state")
	store.stats["lifetime_passengers"] = 250.0
	var complete_early := RegionalProgressionRuntime.apply(store)
	_expect(str(complete_early.get("next_objective", {}).get("id", "")) == "tram", "completed early network milestones reveal strategic tram objective")
	store.free()


func _test_population_weighted_accessibility() -> void:
	var store := _store()
	var metrics := RegionalProgressionRuntime.collect_metrics(store)
	# (1000 * 0.9 + 3000 * 0.5) / 4000 = 0.6
	_expect(is_equal_approx(float(metrics.get("average_mobility_accessibility", 0.0)), 0.6), "regional accessibility is population weighted instead of averaging tiny and large settlements equally")
	store.free()


func _store() -> ProgressStore:
	var store := ProgressStore.new()
	store.city = {
		"time_seconds": 900.0,
		"economy": {
			"fare_revenue_per_minute": 10.0,
			"total_opex_per_minute": 7.0,
			"net_per_minute": 3.0,
		},
		"regional_settlements": [
			{"id": "a", "population": 1000},
			{"id": "b", "population": 3000},
		],
		"regional_accessibility": {
			"settlements": {
				"a": {"available": true, "score": 0.9},
				"b": {"available": true, "score": 0.5},
			},
		},
	}
	store.transport = {
		"resident_count": 4000,
		"reachable_transit_od_pairs": 4,
		"total_od_pairs": 8,
		"transit_share": 0.18,
	}
	store.health = {
		"healthcare_coverage": 0.96,
		"healthcare_data_available": true,
	}
	return store


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional progression runtime: %s" % message)
