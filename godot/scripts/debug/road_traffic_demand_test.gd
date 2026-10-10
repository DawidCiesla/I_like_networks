extends SceneTree

const RoadTrafficDemand = preload("res://scripts/simulation/road_traffic_demand.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_groups_cohorts_and_converts_units()
	_test_rejects_implicit_time_period()
	_test_ignores_zero_and_malformed_car_flows()

	if _failures == 0:
		print("ROAD TRAFFIC DEMAND TEST: PASS")
		quit(0)
		return
	push_error("ROAD TRAFFIC DEMAND TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _test_groups_cohorts_and_converts_units() -> void:
	var choice := {
		"flows": [
			{
				"od_id": "a-b-adults",
				"origin_id": "a",
				"destination_id": "b",
				"flows": {"car": 240.0, "transit": 40.0, "unserved": 20.0},
			},
			{
				"od_id": "a-b-students",
				"origin_id": "a",
				"destination_id": "b",
				"flows": {"car": 60.0, "transit": 80.0, "unserved": 10.0},
			},
			{
				"od_id": "b-a",
				"origin_id": "b",
				"destination_id": "a",
				"flows": {"car": 150.0, "transit": 10.0, "unserved": 0.0},
			},
		],
	}
	var result := RoadTrafficDemand.from_travel_choice(choice, {
		"period_hours": 24.0,
		"average_car_occupancy": 1.25,
	})
	_expect(bool(result["valid"]), "explicit period and occupancy produce a valid demand snapshot")
	var demands: Array = result["demands"]
	_expect(demands.size() == 2, "cohort rows with the same directed OD pair are aggregated")
	var first: Dictionary = demands[0]
	var second: Dictionary = demands[1]
	_expect(str(first["origin_node"]) == "a" and str(first["destination_node"]) == "b", "demand ordering is deterministic")
	_expect(int(first["source_rows"]) == 2, "aggregated OD pair reports its source cohort count")
	_expect(_approx(float(first["vehicle_trips_per_hour"]), 10.0), "300 passenger car trips per day at 1.25 occupancy convert to 10 veh/h")
	_expect(_approx(float(second["vehicle_trips_per_hour"]), 5.0), "reverse OD direction remains separate and converts independently")
	var totals: Dictionary = result["totals"]
	_expect(_approx(float(totals["passenger_car_trips"]), 450.0), "adapter reports total passenger car trips")
	_expect(_approx(float(totals["vehicle_trips_per_hour"]), 15.0), "adapter reports aggregate vehicle demand per hour")


func _test_rejects_implicit_time_period() -> void:
	var result := RoadTrafficDemand.from_travel_choice({"flows": []})
	_expect(not bool(result["valid"]), "traffic demand refuses to guess whether model trips are hourly or daily")
	_expect((result["errors"] as Array).size() > 0, "invalid unit configuration includes a diagnostic error")


func _test_ignores_zero_and_malformed_car_flows() -> void:
	var result := RoadTrafficDemand.from_travel_choice({
		"flows": [
			{"origin_id": "a", "destination_id": "b", "flows": {"car": 0.0}},
			{"origin_id": "a", "destination_id": "c", "flows": {"car": "bad"}},
			{"origin_id": "a", "destination_id": "a", "flows": {"car": 100.0}},
		],
	}, {"period_hours": 1.0})
	_expect(bool(result["valid"]), "malformed flow rows do not invalidate otherwise valid units")
	_expect((result["demands"] as Array).is_empty(), "zero, malformed, and self OD traffic are excluded")
	_expect(_approx(float((result["totals"] as Dictionary)["vehicle_trips_per_hour"]), 0.0), "excluded rows do not create phantom traffic")


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("RoadTrafficDemand: %s" % message)


func _approx(a: float, b: float, tolerance: float = 0.001) -> bool:
	return absf(a - b) <= tolerance
