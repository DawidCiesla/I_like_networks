extends SceneTree

const RegionalProgressionRuntime = preload("res://scripts/city/regional_progression_runtime.gd")

class ProgressStore:
	extends Node
	var money := 50000.0
	var city: Dictionary = {}
	var transit_network: Dictionary = {"unlocked_modes": {"bus": true}, "lines": {}}
	var stats: Dictionary = {
		"lifetime_revenue": 5000.0,
		"lifetime_operating_costs": 7000.0,
		"lifetime_passengers": 120.0,
	}
	var transport: Dictionary = {}
	var depot: Dictionary = {"built": true, "garage_slots": 4}

	func resident_transport_metrics() -> Dictionary:
		return transport

	func transit_mode_status(mode: String) -> Dictionary:
		return {
			"minimum_startup_capital": 80000.0 if mode == "tram" else 300000.0,
			"unlock_cost": 16000.0 if mode == "tram" else 150000.0,
		}

	func has_depot() -> bool:
		return bool(depot.get("built", false))


var _failures := 0


func _init() -> void:
	_test_runtime_collects_canonical_v2_metrics()
	_test_population_weighted_accessibility()
	_test_congestion_history_is_sticky()
	_test_completed_bypass_is_detected()
	if _failures > 0:
		push_error("REGIONAL PROGRESSION RUNTIME TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL PROGRESSION RUNTIME TEST: PASS")
	quit(0)


func _test_runtime_collects_canonical_v2_metrics() -> void:
	var store := _store()
	var snapshot := RegionalProgressionRuntime.apply(store)
	var metrics: Dictionary = snapshot.get("metrics", {})
	_expect(float(metrics.get("current_net_per_minute", 0.0)) == 3.0, "runtime feeds Economy V1 live net into progression")
	_expect(float(metrics.get("transit_share", 0.0)) == 0.18, "runtime feeds resident mode share into progression")
	_expect(int(metrics.get("player_built_road_count", 0)) == 1, "runtime counts only completed player roads")
	_expect(bool(metrics.get("depot_built", false)), "runtime reads actual depot state")
	_expect(int(metrics.get("custom_active_line_count", 0)) == 1, "runtime counts active custom lines")
	_expect(int(metrics.get("active_custom_fleet", 0)) == 2, "runtime counts vehicles actually assigned to custom service")
	_expect(bool(metrics.get("high_demand_corridor_served", false)), "runtime derives high-demand service from live line demand")
	_expect(int(metrics.get("served_settlement_count", 0)) == 1, "runtime derives served settlements from accessibility transit share")
	_expect(str(snapshot.get("next_objective", {}).get("id", "")) == "serve_three_settlements", "the runtime snapshot feeds the natural V2 milestone chain")
	_expect(typeof(store.city.get("progression_v2", null)) == TYPE_DICTIONARY, "apply stores canonical progression state in city")
	store.free()


func _test_population_weighted_accessibility() -> void:
	var store := _store()
	var metrics := RegionalProgressionRuntime.collect_metrics(store)
	# (1000 * 0.9 + 3000 * 0.5) / 4000 = 0.6
	_expect(is_equal_approx(float(metrics.get("average_mobility_accessibility", 0.0)), 0.6), "regional accessibility is population weighted")
	_expect(bool(metrics.get("mobility_accessibility_available", false)), "a real accessibility snapshot is marked available")
	store.free()


func _test_congestion_history_is_sticky() -> void:
	var store := _store()
	store.city["road_traffic"] = {"summary": {"max_vc_ratio": 1.0, "congested_edge_count": 2}}
	var congested := RegionalProgressionRuntime.apply(store)
	_expect(bool(congested["history"].get("had_congestion", false)), "crossing the congestion threshold records that congestion was encountered")
	_expect(not bool(congested["history"].get("resolved_first_congestion", false)), "the congestion milestone is not resolved while the corridor remains congested")

	store.city["road_traffic"] = {"summary": {"max_vc_ratio": 0.70, "congested_edge_count": 0}}
	var resolved := RegionalProgressionRuntime.apply(store)
	_expect(bool(resolved["history"].get("resolved_first_congestion", false)), "dropping below the recovery threshold resolves the first congestion problem")

	store.city["road_traffic"] = {"summary": {"max_vc_ratio": 1.25, "congested_edge_count": 3}}
	var later := RegionalProgressionRuntime.apply(store)
	_expect(bool(later["history"].get("resolved_first_congestion", false)), "later congestion cannot revoke the resolved milestone")
	_expect(bool(later["history"].get("had_severe_congestion", false)), "severe congestion is recorded as a sticky history fact")
	store.free()


func _test_completed_bypass_is_detected() -> void:
	var store := _store()
	store.city["roads"].append({
		"id": "relief-1",
		"source": "player",
		"status": "built",
		"regionalRole": "player_relief_corridor",
		"proposalId": "proposal-1",
	})
	var metrics := RegionalProgressionRuntime.collect_metrics(store)
	_expect(bool(metrics.get("first_bypass_built", false)), "a completed player relief corridor satisfies the bypass metric")
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
		"roads": [
			{"id": "player-road", "source": "player", "status": "built"},
			{"id": "historic-road", "source": "regional-existing", "status": "built"},
		],
		"regional_settlements": [
			{"id": "a", "population": 1000},
			{"id": "b", "population": 3000},
		],
		"regional_accessibility": {
			"settlements": {
				"a": {"available": true, "score": 0.9, "transit_share": 0.12},
				"b": {"available": true, "score": 0.5, "transit_share": 0.0},
			},
		},
	}
	store.transit_network = {
		"unlocked_modes": {"bus": true},
		"lines": {
			"line-a": {
				"id": "line-a",
				"source": "custom",
				"status": "active",
				"mode": "bus",
				"fleet_count": 2,
				"last_delivered_ppm": 7.0,
			},
		},
	}
	store.transport = {
		"resident_count": 4000,
		"reachable_transit_od_pairs": 4,
		"total_od_pairs": 8,
		"transit_share": 0.18,
	}
	return store


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional progression runtime: %s" % message)
