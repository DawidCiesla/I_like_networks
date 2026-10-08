extends SceneTree

const TransitPlannerScript = preload("res://scripts/transport/transit_planner.gd")

var failures := 0


func _initialize() -> void:
	_test_mode_speed_and_wait_choose_the_fastest_service()
	_test_fleet_and_crowding_change_generalized_time()
	_test_transfers_keep_mode_and_charge_each_boarding_once()
	_test_transfer_walk_time_uses_resident_speed()
	_test_lines_without_vehicles_are_not_routable()

	if failures == 0:
		print("TransitPlanner: PASS (mode-aware routing, headway, crowding, transfers, fleet)")
		quit(0)
	else:
		push_error("TransitPlanner: %d failure(s)" % failures)
		quit(1)


func _test_mode_speed_and_wait_choose_the_fastest_service() -> void:
	var network := _parallel_bus_metro_network()
	var combined: Dictionary = TransitPlannerScript.find_journey(network, "origin", "destination")
	var bus_only_network := network.duplicate(true)
	bus_only_network["lines"] = {"bus": network["lines"]["bus"]}
	var bus_only: Dictionary = TransitPlannerScript.find_journey(bus_only_network, "origin", "destination")

	_expect(bool(combined.get("success", false)), "an active bus and metro connection produces a journey")
	_expect(bool(bus_only.get("success", false)), "the bus alternative remains independently routable")
	if not bool(combined.get("success", false)) or not bool(bus_only.get("success", false)):
		return
	var combined_legs: Array = combined.get("legs", [])
	_expect(combined_legs.size() == 1, "consecutive metro segments merge into one passenger-facing ride leg")
	if combined_legs.size() == 1:
		var selected_leg: Dictionary = combined_legs[0]
		_expect(str(selected_leg.get("line_id", "")) == "metro", "routing selects the faster metro despite its longer path")
		_expect(is_equal_approx(float(selected_leg.get("cost", 0.0)), 2400.0), "merged legs preserve geometric distance for existing callers")
	_expect(
		float(combined.get("generalized_time_minutes", INF))
			< float(bus_only.get("generalized_time_minutes", 0.0)),
		"the selected metro journey has a lower generalized time than the shorter bus route"
	)
	_expect(
		float(combined.get("generalized_time_minutes", INF)) < 10.0,
		"a multi-stop metro ride charges its boarding wait once for the whole line journey"
	)

	var lines: Dictionary = network["lines"]
	var metro: Dictionary = lines["metro"]
	metro["crowding_ratio"] = 1.0
	lines["metro"] = metro
	network["lines"] = lines
	var capacity_reroute: Dictionary = TransitPlannerScript.find_journey(network, "origin", "destination")
	var capacity_legs: Array = capacity_reroute.get("legs", [])
	_expect(
		capacity_legs.size() == 1 and str((capacity_legs[0] as Dictionary).get("line_id", "")) == "bus",
		"a full metro shifts the passenger onto the less crowded bus alternative"
	)


func _test_fleet_and_crowding_change_generalized_time() -> void:
	var network := _parallel_bus_metro_network()
	network["lines"] = {"bus": network["lines"]["bus"]}
	var baseline: Dictionary = TransitPlannerScript.find_journey(network, "origin", "destination")
	var lines: Dictionary = network["lines"]
	var bus: Dictionary = lines["bus"]
	bus["fleet_count"] = 2
	lines["bus"] = bus
	network["lines"] = lines
	var larger_fleet: Dictionary = TransitPlannerScript.find_journey(network, "origin", "destination")
	_expect(
		float(larger_fleet.get("generalized_time_minutes", INF))
			< float(baseline.get("generalized_time_minutes", 0.0)),
		"additional vehicles reduce the expected wait in route evaluation"
	)

	bus["crowding_ratio"] = 1.0
	lines["bus"] = bus
	network["lines"] = lines
	var crowded: Dictionary = TransitPlannerScript.find_journey(network, "origin", "destination")
	_expect(
		float(crowded.get("generalized_time_minutes", 0.0))
			> float(larger_fleet.get("generalized_time_minutes", 0.0)),
		"capacity pressure raises generalized travel time"
	)
	_expect(
		is_equal_approx(
			float(crowded.get("generalized_time_minutes", 0.0))
				- float(larger_fleet.get("generalized_time_minutes", 0.0)),
			42.0
		),
		"full crowding applies the same 42-minute penalty used by resident mode choice"
	)


func _test_transfers_keep_mode_and_charge_each_boarding_once() -> void:
	var network := {
		"stops": {
			"origin": _stop(Vector2(0.0, 0.0), ["bus"]),
			"bus_end": _stop(Vector2(1000.0, 0.0), ["bus"]),
			"tram_start": _stop(Vector2(1060.0, 0.0), ["tram"]),
			"destination": _stop(Vector2(2060.0, 0.0), ["tram"]),
		},
		"lines": {
			"bus": _line("bus", ["origin", "bus_end"], [1000.0]),
			"tram": _line("tram", ["tram_start", "destination"], [1000.0]),
		},
	}
	var journey: Dictionary = TransitPlannerScript.find_journey(network, "origin", "destination")
	_expect(bool(journey.get("success", false)), "a short walk connects two active transit modes")
	if not bool(journey.get("success", false)):
		return
	var legs: Array = journey.get("legs", [])
	_expect(int(journey.get("transfers", 0)) == 1, "changing from bus to tram counts one transfer")
	_expect(legs.size() == 3, "the journey retains bus, walk, and tram legs")
	if legs.size() == 3:
		_expect(str((legs[0] as Dictionary).get("line_id", "")) == "bus", "the first ride keeps its bus line identity")
		_expect(str((legs[1] as Dictionary).get("mode", "")) == "walk", "nearby stops create a transfer walk leg")
		_expect(str((legs[2] as Dictionary).get("line_id", "")) == "tram", "the second ride keeps its tram line identity")
		_expect(float((legs[0] as Dictionary).get("time_minutes", 0.0)) > 4.0, "the bus ride includes its boarding wait")
		_expect(float((legs[2] as Dictionary).get("time_minutes", 0.0)) > 4.0, "the tram ride includes a new wait after the walk transfer")


func _test_lines_without_vehicles_are_not_routable() -> void:
	var network := _parallel_bus_metro_network()
	var lines: Dictionary = network["lines"]
	var bus: Dictionary = lines["bus"]
	bus["fleet_count"] = 0
	lines["bus"] = bus
	var metro: Dictionary = lines["metro"]
	metro["fleet_count"] = 0
	lines["metro"] = metro
	network["lines"] = lines
	var journey: Dictionary = TransitPlannerScript.find_journey(network, "origin", "destination")
	_expect(not bool(journey.get("success", true)), "active line records without a fleet do not promise passenger service")


func _test_transfer_walk_time_uses_resident_speed() -> void:
	var network := {
		"stops": {
			"origin": _stop(Vector2(0.0, 0.0), ["bus"]),
			"bus_end": _stop(Vector2(1000.0, 0.0), ["bus"]),
			"tram_start": _stop(Vector2(1060.0, 0.0), ["tram"]),
			"destination": _stop(Vector2(2060.0, 0.0), ["tram"]),
		},
		"lines": {
			"bus": _line("bus", ["origin", "bus_end"], [1000.0]),
			"tram": _line("tram", ["tram_start", "destination"], [1000.0]),
		},
	}
	var adult: Dictionary = TransitPlannerScript.find_journey(network, "origin", "destination", 200.0, 72.0)
	var senior: Dictionary = TransitPlannerScript.find_journey(network, "origin", "destination", 200.0, 48.0)
	var adult_legs: Array = adult.get("legs", [])
	var senior_legs: Array = senior.get("legs", [])
	_expect(
		float(senior.get("generalized_time_minutes", 0.0)) > float(adult.get("generalized_time_minutes", INF)),
		"slower senior walking speed raises the selected journey time"
	)
	if adult_legs.size() == 3 and senior_legs.size() == 3:
		_expect(
			float((senior_legs[1] as Dictionary).get("time_minutes", 0.0))
			> float((adult_legs[1] as Dictionary).get("time_minutes", INF)),
			"transfer walk duration is calculated for the resident age profile"
		)


func _parallel_bus_metro_network() -> Dictionary:
	var origin := Vector2.ZERO
	var middle := Vector2(1200.0, 0.0)
	var destination := Vector2(2400.0, 0.0)
	return {
		"stops": {
			"origin": _stop(origin, ["bus", "metro"]),
			"middle": _stop(middle, ["metro"]),
			"destination": _stop(destination, ["bus", "metro"]),
		},
		"lines": {
			"bus": _line("bus", ["origin", "destination"], [2000.0]),
			"metro": _line("metro", ["origin", "middle", "destination"], [1200.0, 1200.0]),
		},
	}


func _stop(point: Vector2, served_line_ids: Array) -> Dictionary:
	return {
		"status": "built",
		"x": point.x,
		"y": point.y,
		"served_line_ids": served_line_ids,
	}


func _line(mode: String, stop_ids: Array, segment_lengths: Array) -> Dictionary:
	var segments: Array[Dictionary] = []
	var total_length := 0.0
	for length_value in segment_lengths:
		var length := float(length_value)
		segments.append({"length_world": length})
		total_length += length
	return {
		"status": "active",
		"mode": mode,
		"stop_ids": stop_ids,
		"route_segments": segments,
		"route_length_world": total_length,
		"fleet_count": 1,
		"crowding_ratio": 0.0,
	}


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	failures += 1
	push_error("TransitPlanner: %s" % description)
