extends SceneTree

const TrafficDemand = preload("res://scripts/render/traffic_demand.gd")

var _failures := 0


func _initialize() -> void:
	var baseline := {
		"resident_count": 1000,
		"car_share": 0.5,
		"average_commute_minutes": 30.0,
	}
	var baseline_target := TrafficDemand.visible_vehicle_target(baseline, 24)
	var lower_car_share := baseline.duplicate(true)
	lower_car_share["car_share"] = 0.1
	var lower_target := TrafficDemand.visible_vehicle_target(lower_car_share, 24)
	var no_car_share := baseline.duplicate(true)
	no_car_share["car_share"] = 0.0
	var larger_city := baseline.duplicate(true)
	larger_city["resident_count"] = 2000
	var longer_commute := baseline.duplicate(true)
	longer_commute["average_commute_minutes"] = 60.0

	_expect(baseline_target > 0, "resident car demand produces visible traffic")
	_expect(lower_target < baseline_target, "higher public-transport mode share reduces visible traffic")
	_expect(TrafficDemand.visible_vehicle_target(no_car_share, 24) == 0, "zero car mode share has no car traffic proxies")
	_expect(
		TrafficDemand.visible_vehicle_target(larger_city, 24) >= baseline_target,
		"a larger resident population does not reduce car traffic density"
	)
	_expect(
		TrafficDemand.visible_vehicle_target(longer_commute, 24) >= baseline_target,
		"longer car journeys keep more cars in motion"
	)
	_expect(TrafficDemand.visible_vehicle_target(larger_city, 12) <= 12, "traffic proxy count respects the renderer budget")
	if _failures == 0:
		print("TrafficDemand: PASS (modal split, demand scaling and renderer cap)")
		quit(0)
	else:
		push_error("TrafficDemand: FAIL (%d checks)" % _failures)
		quit(1)


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("TrafficDemand: %s" % description)
