extends SceneTree

const TransitModesScript = preload("res://scripts/transport/transit_modes.gd")

var failures := 0


func _initialize() -> void:
	_test_profiles_and_unlocks()
	_test_bus_road_network_validation()
	_test_surface_station_spacing()
	_test_tram_corridor_validation()
	_test_metro_route_validation()
	_test_malformed_inputs()

	if failures == 0:
		print("TransitModes: PASS (profiles, unlocks, bus/tram/metro route constraints)")
		quit(0)
	else:
		push_error("TransitModes: %d failure(s)" % failures)
		quit(1)


func _test_profiles_and_unlocks() -> void:
	_expect(TransitModesScript.mode_ids() == ["bus", "tram", "metro"], "mode list is stable")
	var bus: Dictionary = TransitModesScript.profile("bus")
	var tram: Dictionary = TransitModesScript.profile("tram")
	var metro: Dictionary = TransitModesScript.profile("metro")
	_expect(int(bus.get("vehicle_capacity", 0)) == 40, "bus profile matches the existing bus capacity")
	_expect(float(bus.get("speed_kph", 0.0)) == 18.0, "bus profile matches the existing bus speed")
	_expect(
		float(bus.get("operating_cost_multiplier", 0.0)) < float(tram.get("operating_cost_multiplier", 0.0))
		and float(tram.get("operating_cost_multiplier", 0.0)) < float(metro.get("operating_cost_multiplier", 0.0)),
		"operating cost rises with heavier modes"
	)
	_expect(
		float(bus.get("construction_cost_multiplier", 0.0)) < float(tram.get("construction_cost_multiplier", 0.0))
		and float(tram.get("construction_cost_multiplier", 0.0)) < float(metro.get("construction_cost_multiplier", 0.0)),
		"construction cost rises from buses to rail"
	)
	_expect(float(metro.get("emission_factor", 1.0)) < float(bus.get("emission_factor", 0.0)), "metro has a lower relative emission factor")
	_expect(bus.get("right_of_way") == "mixed_traffic", "bus profile exposes its mixed-traffic right of way")
	_expect(tram.get("requires_tram_corridor", false), "tram profile requires track in its road corridor")
	_expect(metro.get("grade_separated", false), "metro profile requires grade separation")
	_expect(metro.get("requires_accessible_stations", false), "metro profile requires accessible stations")
	_expect(TransitModesScript.profile("ferry").is_empty(), "unknown modes have no profile")

	var baseline := TransitModesScript.unlock_status("bus", 0, 0.0)
	_expect(bool(baseline.get("unlocked", false)), "bus is unlocked at the regional-sandbox baseline")
	var tram_short := TransitModesScript.unlock_status("tram", 25000, 15999.0)
	_expect(not bool(tram_short.get("unlocked", true)), "tram stays locked below its treasury threshold")
	_expect(tram_short.get("reason") == "unlock_cost_not_met", "tram reports the unmet cost requirement")
	_expect(bool(TransitModesScript.unlock_status("tram", 25000, 16000.0).get("unlocked", false)), "tram unlocks when both requirements are met")
	_expect(not bool(TransitModesScript.unlock_status("metro", 79999, 150000.0).get("unlocked", true)), "metro remains locked below its population threshold")
	_expect(bool(TransitModesScript.unlock_status("metro", 80000, 150000.0).get("unlocked", false)), "metro unlocks when its population and cost requirements are met")
	var tram_minimum_line := TransitModesScript.unlock_status("tram", 25000, 16000.0, 80000.0)
	_expect(not bool(tram_minimum_line.get("unlocked", true)), "licence funds alone do not claim a minimum tram line is affordable")
	_expect(is_equal_approx(float(tram_minimum_line.get("funds_remaining", 0.0)), 64000.0), "tram reports the complete remaining startup capital")
	_expect(is_equal_approx(float(tram_minimum_line.get("licence_cost", 0.0)), 16000.0), "tram keeps the licence fee separate from line startup capital")
	_expect(bool(TransitModesScript.unlock_status("tram", 25000, 80000.0, 80000.0).get("unlocked", false)), "tram is ready when the minimum startup capital is available")
	_expect(TransitModesScript.unlock_status("hovercraft", 100000, 1000000.0).get("reason") == "unknown_mode", "unknown modes have a stable unlock failure")


func _test_bus_road_network_validation() -> void:
	var valid_route := {
		"route_segments": [{"success": true, "road_ids": ["road-a"]}],
		"roads": [{"id": "road-a", "status": "built"}],
	}
	_expect(bool(TransitModesScript.validate_route("bus", valid_route).get("valid", false)), "bus route on a completed road is accepted")
	var planned_road_route := {
		"route_segments": [{"success": true, "road_ids": ["road-a"]}],
		"roads": [{"id": "road-a", "status": "planned"}],
	}
	_expect(
		TransitModesScript.validate_route("bus", planned_road_route).get("reason") == "built_road_corridor_required",
		"bus route cannot use a road that is still planned"
	)
	_expect(
		TransitModesScript.validate_route("bus", {"route_segments": []}).get("reason") == "built_road_corridor_required",
		"bus route requires a road-network path"
	)
	_expect(
		bool(TransitModesScript.validate_route("bus", {"road_corridor": true}).get("valid", false)),
		"an upstream route builder can pass its completed-road check as a fact"
	)
	_expect(
		bool(TransitModesScript.validate_route("tram", {"road_corridor": true, "tram_corridor": true}).get("valid", false)),
		"tram accepts completed road and track-corridor facts from its route builder"
	)


func _test_tram_corridor_validation() -> void:
	var tram_route := {
		"route_segments": [{"success": true, "road_ids": ["tram-road"]}],
		"roads": [{
			"id": "tram-road",
			"status": "built",
			"profile": {"tram_reservation": true},
		}],
	}
	_expect(bool(TransitModesScript.validate_route("tram", tram_route).get("valid", false)), "tram accepts a built road with reserved tracks")
	var street_only := tram_route.duplicate(true)
	street_only["roads"][0]["profile"]["tram_reservation"] = false
	street_only["roads"][0]["profile"]["lanes"] = [{"type": "vehicle"}]
	_expect(
		TransitModesScript.validate_route("tram", street_only).get("reason") == "tram_track_corridor_required",
		"tram rejects a street without a track reservation"
	)
	var not_built := tram_route.duplicate(true)
	(not_built["roads"] as Array)[0]["status"] = "planned"
	_expect(
		TransitModesScript.validate_route("tram", not_built).get("reason") == "built_road_corridor_required",
		"tram also requires its road corridor to be built"
	)


func _test_surface_station_spacing() -> void:
	var bus_valid := _surface_route("bus", 900.0)
	_expect(bool(TransitModesScript.validate_route("bus", bus_valid).get("valid", false)), "bus accepts its maximum allowed stop spacing")
	var bus_too_far := _surface_route("bus", 900.1)
	_expect(
		TransitModesScript.validate_route("bus", bus_too_far).get("reason") == "stations_too_far_apart",
		"bus rejects stops beyond its maximum profile spacing"
	)
	var bus_too_close := _surface_route("bus", 69.9)
	_expect(
		TransitModesScript.validate_route("bus", bus_too_close).get("reason") == "stations_too_close",
		"bus route facts cannot bypass its minimum stop spacing"
	)

	var tram_valid := _surface_route("tram", 1200.0)
	_expect(bool(TransitModesScript.validate_route("tram", tram_valid).get("valid", false)), "tram accepts its maximum allowed stop spacing")
	var tram_too_far := _surface_route("tram", 1200.1)
	_expect(
		TransitModesScript.validate_route("tram", tram_too_far).get("reason") == "stations_too_far_apart",
		"tram rejects stops beyond its maximum profile spacing"
	)
	var tram_too_close := _surface_route("tram", 179.9)
	_expect(
		TransitModesScript.validate_route("tram", tram_too_close).get("reason") == "stations_too_close",
		"tram route facts cannot bypass its minimum stop spacing"
	)

	var mismatched_spacing := _surface_route("bus", 400.0)
	mismatched_spacing["stations"].append({"x": 800.0, "y": 0.0})
	mismatched_spacing["station_spacings"] = [400.0]
	_expect(
		TransitModesScript.validate_route("bus", mismatched_spacing).get("reason") == "station_spacing_invalid",
		"surface route rejects spacing facts that do not cover every station pair"
	)


func _surface_route(mode: String, spacing: float) -> Dictionary:
	var route := {
		"road_corridor": true,
		"stations": [
			{"x": 0.0, "y": 0.0},
			{"x": spacing, "y": 0.0},
		],
	}
	if mode == "tram":
		route["tram_corridor"] = true
	return route


func _test_metro_route_validation() -> void:
	var valid_route := {
		"underground": true,
		"stations": [
			{"id": "central", "accessible": true, "position": Vector2(0.0, 0.0)},
			{"id": "north", "accessible": true, "position": Vector2(1000.0, 0.0)},
		],
	}
	_expect(bool(TransitModesScript.validate_route("metro", valid_route).get("valid", false)), "underground metro with accessible and well-spaced stations is accepted")
	var x_y_route := {
		"grade_separated": true,
		"stations": [
			{"accessible": true, "x": 0.0, "y": 0.0},
			{"accessible": true, "x": 1000.0, "y": 0.0},
		],
	}
	_expect(bool(TransitModesScript.validate_route("metro", x_y_route).get("valid", false)), "metro accepts accessible stations serialized with x/y fields")
	var at_grade := valid_route.duplicate(true)
	at_grade.erase("underground")
	_expect(
		TransitModesScript.validate_route("metro", at_grade).get("reason") == "grade_separated_or_underground_route_required",
		"metro route at road grade is rejected"
	)
	var inaccessible := valid_route.duplicate(true)
	(inaccessible["stations"] as Array)[1]["accessible"] = false
	_expect(
		TransitModesScript.validate_route("metro", inaccessible).get("reason") == "accessible_stations_required",
		"metro rejects stations without accessibility"
	)
	var too_close := valid_route.duplicate(true)
	(too_close["stations"] as Array)[1]["position"] = Vector2(400.0, 0.0)
	_expect(
		TransitModesScript.validate_route("metro", too_close).get("reason") == "stations_too_close",
		"metro rejects stations that are too close together"
	)
	var too_far := valid_route.duplicate(true)
	(too_far["stations"] as Array)[1]["position"] = Vector2(4000.0, 0.0)
	_expect(
		TransitModesScript.validate_route("metro", too_far).get("reason") == "stations_too_far_apart",
		"metro rejects stations beyond accessible service spacing"
	)
	var explicit_facts := {
		"grade_separated": true,
		"station_count": 2,
		"accessible_stations": true,
		"station_spacing": 1000.0,
	}
	_expect(bool(TransitModesScript.validate_route("metro", explicit_facts).get("valid", false)), "metro accepts validated route-builder facts")


func _test_malformed_inputs() -> void:
	_expect(
		not bool(TransitModesScript.validate_route("bus", {"route_segments": "bad", "roads": "bad"}).get("valid", true)),
		"malformed bus route containers are rejected without crashing"
	)
	_expect(
		not bool(TransitModesScript.validate_route("tram", {"route_segments": [null], "tram_corridor": true}).get("valid", true)),
		"malformed tram segments are rejected even when other route facts are present"
	)
	_expect(
		not bool(TransitModesScript.validate_route("metro", {
			"underground": true,
			"station_count": 2,
			"accessible_stations": true,
			"station_spacings": ["unknown"],
		}).get("valid", true)),
		"malformed metro spacing values are rejected without coercion"
	)


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	failures += 1
	push_error("TransitModes: %s" % description)
