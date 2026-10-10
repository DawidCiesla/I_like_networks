extends SceneTree

const TransitLineHealth = preload("res://scripts/simulation/transit_line_health.gd")

var _failures := 0


func _init() -> void:
	_test_no_service()
	_test_capacity_warning_and_overload()
	_test_congestion_limited_service()
	_test_long_headway()
	_test_healthy_service()
	if _failures > 0:
		push_error("TRANSIT LINE HEALTH TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("TRANSIT LINE HEALTH TEST: PASS")
	quit(0)


func _test_no_service() -> void:
	var result := TransitLineHealth.evaluate({
		"fleet_count": 0,
		"current_demand_ppm": 4.0,
	})
	_expect(str(result.get("status", "")) == "no_service", "line without vehicles is no_service")
	_expect(str(result.get("recommended_action", "")) == "add_vehicle", "no-service line recommends adding a vehicle")


func _test_capacity_warning_and_overload() -> void:
	var warning := TransitLineHealth.evaluate({
		"fleet_count": 2,
		"current_demand_ppm": 8.8,
		"traffic_effective_capacity_ppm": 10.0,
		"traffic_effective_headway_minutes": 7.0,
		"traffic_delay_factor": 1.0,
	})
	_expect(str(warning.get("status", "")) == "capacity_warning", "near-capacity service produces a warning")
	var overloaded := TransitLineHealth.evaluate({
		"fleet_count": 2,
		"current_demand_ppm": 12.0,
		"traffic_effective_capacity_ppm": 10.0,
		"traffic_effective_headway_minutes": 7.0,
		"traffic_delay_factor": 1.0,
	})
	_expect(str(overloaded.get("status", "")) == "overloaded", "demand above effective capacity is overloaded")
	_expect(str(overloaded.get("recommended_action", "")) == "increase_capacity", "overloaded line recommends capacity intervention")


func _test_congestion_limited_service() -> void:
	var result := TransitLineHealth.evaluate({
		"fleet_count": 3,
		"current_demand_ppm": 4.0,
		"traffic_effective_capacity_ppm": 12.0,
		"traffic_effective_headway_minutes": 9.0,
		"traffic_delay_factor": 1.9,
	})
	_expect(str(result.get("status", "")) == "congestion_limited", "severe road delay is exposed separately from overload")
	_expect(str(result.get("reason", "")) == "severe_road_congestion", "congestion-limited status identifies the road cause")
	_expect(str(result.get("recommended_action", "")) == "use_priority_or_separate_right_of_way", "severe road congestion suggests priority or separated transit")


func _test_long_headway() -> void:
	var result := TransitLineHealth.evaluate({
		"fleet_count": 1,
		"current_demand_ppm": 1.0,
		"traffic_effective_capacity_ppm": 6.0,
		"traffic_effective_headway_minutes": 18.0,
		"traffic_delay_factor": 1.0,
	})
	_expect(str(result.get("status", "")) == "under_served", "low-frequency line with demand is under-served")
	_expect(str(result.get("recommended_action", "")) == "add_vehicle", "long headway suggests another vehicle")


func _test_healthy_service() -> void:
	var result := TransitLineHealth.evaluate({
		"fleet_count": 3,
		"current_demand_ppm": 4.0,
		"traffic_effective_capacity_ppm": 12.0,
		"traffic_effective_headway_minutes": 7.0,
		"traffic_delay_factor": 1.08,
	})
	_expect(str(result.get("status", "")) == "healthy", "balanced line remains healthy")
	_expect(int(result.get("severity", -1)) == 0, "healthy line has zero severity")


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Transit line health: %s" % message)
