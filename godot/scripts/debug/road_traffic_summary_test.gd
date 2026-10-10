extends SceneTree

const RoadTrafficSummary = preload("res://scripts/simulation/road_traffic_summary.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var summary := RoadTrafficSummary.summarize({
		"totals": {
			"vehicle_demand_vph": 1000.0,
			"assigned_vehicle_demand_vph": 900.0,
			"unassigned_vehicle_demand_vph": 100.0,
		},
		"edge_metrics": {
			"a": {
				"flow_vph": 600.0,
				"length_km": 2.0,
				"free_flow_minutes": 2.0,
				"travel_time_minutes": 3.0,
				"vc_ratio": 1.1,
			},
			"b": {
				"flow_vph": 300.0,
				"length_km": 1.0,
				"free_flow_minutes": 1.0,
				"travel_time_minutes": 1.2,
				"vc_ratio": 0.7,
			},
		},
	})
	_expect(_approx(float(summary["vehicle_km_per_hour"]), 1500.0), "vehicle-km per hour sums flow times edge length")
	_expect(_approx(float(summary["vehicle_hours_per_hour"]), 36.0), "vehicle-hours per hour use congested travel time")
	_expect(_approx(float(summary["free_flow_vehicle_hours_per_hour"]), 25.0), "free-flow vehicle-hours preserve the counterfactual baseline")
	_expect(_approx(float(summary["delay_vehicle_hours_per_hour"]), 11.0), "network delay is exposed as excess vehicle-hours")
	_expect(_approx(float(summary["max_vc_ratio"]), 1.1), "summary exposes the worst V/C ratio")
	_expect(int(summary["congested_edge_count"]) == 1, "V/C >= 0.85 counts as congested")
	_expect(int(summary["severe_edge_count"]) == 1, "V/C >= 1.0 counts as severe")
	_expect(_approx(float(summary["unassigned_vehicle_demand_vph"]), 100.0), "assignment failure remains visible in network KPIs")

	if _failures == 0:
		print("ROAD TRAFFIC SUMMARY TEST: PASS")
		quit(0)
		return
	push_error("ROAD TRAFFIC SUMMARY TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("RoadTrafficSummary: %s" % message)


func _approx(a: float, b: float, tolerance: float = 0.001) -> bool:
	return absf(a - b) <= tolerance
