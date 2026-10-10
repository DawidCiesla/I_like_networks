extends SceneTree

const TransitPlanner = preload("res://scripts/transport/transit_planner.gd")

var _failures := 0


func _init() -> void:
	_test_bus_ride_and_wait_use_traffic_metrics()
	_test_missing_traffic_metrics_preserve_baseline()
	_test_separated_modes_ignore_bus_traffic_fields()
	if _failures > 0:
		push_error("TRANSIT PLANNER TRAFFIC TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("TRANSIT PLANNER TRAFFIC TEST: PASS")
	quit(0)


func _test_bus_ride_and_wait_use_traffic_metrics() -> void:
	var network := _network("bus")
	var line: Dictionary = network["lines"]["line-a"]
	line["traffic_delay_factor"] = 3.0
	line["traffic_effective_headway_minutes"] = 18.0
	network["lines"]["line-a"] = line
	var edge := _ride_edge(TransitPlanner.build_graph(network))
	_expect(not edge.is_empty(), "traffic-aware bus line creates a ride edge")
	_expect(is_equal_approx(float(edge.get("time_minutes", 0.0)), 18.0), "bus ride time uses the traffic delay factor")
	_expect(is_equal_approx(float(edge.get("boarding_wait_minutes", 0.0)), 9.0), "bus expected wait uses the effective congestion-aware headway")


func _test_missing_traffic_metrics_preserve_baseline() -> void:
	var network := _network("bus")
	var edge := _ride_edge(TransitPlanner.build_graph(network))
	_expect(not edge.is_empty(), "baseline bus line creates a ride edge")
	_expect(is_equal_approx(float(edge.get("time_minutes", 0.0)), 6.0), "bus ride time keeps nominal speed when no traffic metrics exist")
	_expect(float(edge.get("boarding_wait_minutes", 0.0)) > 0.0, "baseline headway calculation remains available")
	_expect(float(edge.get("boarding_wait_minutes", 0.0)) < 9.0, "traffic-free expected wait is lower than the congested fixture")


func _test_separated_modes_ignore_bus_traffic_fields() -> void:
	for mode in ["tram", "metro"]:
		var network := _network(mode)
		var line: Dictionary = network["lines"]["line-a"]
		line["traffic_delay_factor"] = 5.0
		line["traffic_effective_headway_minutes"] = 28.0
		network["lines"]["line-a"] = line
		var edge := _ride_edge(TransitPlanner.build_graph(network))
		_expect(not edge.is_empty(), "%s line creates a ride edge" % mode)
		_expect(float(edge.get("time_minutes", 0.0)) < 10.0, "%s ride time ignores mixed-traffic bus delay" % mode)
		_expect(float(edge.get("boarding_wait_minutes", 0.0)) < 14.0, "%s headway ignores the bus traffic headway override" % mode)


func _network(mode: String) -> Dictionary:
	return {
		"stops": {
			"stop-a": {"id": "stop-a", "status": "built", "x": 0.0, "y": 0.0, "level": 0},
			"stop-b": {"id": "stop-b", "status": "built", "x": 1800.0, "y": 0.0, "level": 0},
		},
		"lines": {
			"line-a": {
				"id": "line-a",
				"status": "active",
				"mode": mode,
				"fleet_count": 1,
				"stop_ids": ["stop-a", "stop-b"],
				"route_length_world": 1800.0,
				"route_segments": [{"length_world": 1800.0}],
				"crowding_ratio": 0.0,
			},
		},
	}


func _ride_edge(graph: Dictionary) -> Dictionary:
	for edge_value in graph.get("stop-a", []):
		if typeof(edge_value) != TYPE_DICTIONARY:
			continue
		var edge: Dictionary = edge_value
		if str(edge.get("mode", "")) == "ride" and str(edge.get("line_id", "")) == "line-a":
			return edge
	return {}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Transit planner traffic: %s" % message)
