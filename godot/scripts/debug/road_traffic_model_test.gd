extends SceneTree

const RoadTrafficModel = preload("res://scripts/simulation/road_traffic_model.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var city := _fixture_city()
	_test_free_flow_profiles(city)
	_test_low_demand_uses_fast_short_corridor(city)
	_test_congestion_redistributes_flow(city)
	_test_unreachable_demand_is_reported(city)

	if _failures == 0:
		print("ROAD TRAFFIC MODEL TEST: PASS")
		quit(0)
		return
	push_error("ROAD TRAFFIC MODEL TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _test_free_flow_profiles(city: Dictionary) -> void:
	var metrics := RoadTrafficModel.free_flow_edge_metrics(city)
	_expect(metrics.has("edge-local-a"), "free-flow metrics include built local edge")
	_expect(metrics.has("edge-arterial-a"), "free-flow metrics include built arterial edge")
	if not metrics.has("edge-local-a") or not metrics.has("edge-arterial-a"):
		return
	var local: Dictionary = metrics["edge-local-a"]
	var arterial: Dictionary = metrics["edge-arterial-a"]
	_expect(_approx(float(local["speed_kph"]), 40.0), "explicit road profile speed overrides class default")
	_expect(int(local["vehicle_lanes"]) == 1, "vehicle lane count comes from the road profile")
	_expect(_approx(float(local["capacity_vph"]), 700.0), "local one-lane capacity is deterministic")
	_expect(int(arterial["vehicle_lanes"]) == 4, "arterial base profile exposes four vehicle lanes")
	_expect(float(arterial["capacity_vph"]) > float(local["capacity_vph"]), "arterial corridor has more capacity than local shortcut")


func _test_low_demand_uses_fast_short_corridor(city: Dictionary) -> void:
	var result := RoadTrafficModel.evaluate(city, [
		{
			"id": "low-demand",
			"origin_node": "a",
			"destination_node": "d",
			"vehicle_trips_per_hour": 200.0,
		},
	])
	var roads: Dictionary = result["road_metrics"]
	_expect(float((roads["local-shortcut"] as Dictionary)["flow_vph"]) > 190.0, "low demand stays on the faster local shortcut")
	_expect(float((roads["arterial-bypass"] as Dictionary)["flow_vph"]) < 1.0, "low demand does not use the slower bypass")
	var od: Dictionary = (result["od_results"] as Array)[0]
	_expect(bool(od["assigned"]), "low-demand OD pair is assigned")
	_expect((od["road_ids"] as Array).has("local-shortcut"), "reported low-demand route uses the shortcut")


func _test_congestion_redistributes_flow(city: Dictionary) -> void:
	var result := RoadTrafficModel.evaluate(city, [
		{
			"id": "peak-demand",
			"origin_node": "a",
			"destination_node": "d",
			"vehicle_trips_per_hour": 1600.0,
		},
	], {"iterations": 4})
	var roads: Dictionary = result["road_metrics"]
	var local: Dictionary = roads["local-shortcut"]
	var arterial: Dictionary = roads["arterial-bypass"]
	_expect(float(local["flow_vph"]) > 0.0, "congested shortcut retains some assigned traffic")
	_expect(float(arterial["flow_vph"]) > 0.0, "congestion moves part of peak demand to the higher-capacity bypass")
	_expect(float(local["vc_ratio"]) > 1.0, "shortcut reports demand above capacity")
	_expect(float(local["travel_time_minutes"]) > float(local["free_flow_minutes"]), "BPR delay raises congested travel time")
	_expect(str(local["congestion_level"]) == "severe", "V/C above one is classified as severe")
	var totals: Dictionary = result["totals"]
	_expect(_approx(float(totals["assigned_vehicle_demand_vph"]), 1600.0), "peak OD demand remains fully assigned")
	_expect(_approx(float(totals["unassigned_vehicle_demand_vph"]), 0.0), "connected peak OD has no unassigned demand")


func _test_unreachable_demand_is_reported(city: Dictionary) -> void:
	var result := RoadTrafficModel.evaluate(city, [
		{
			"id": "unreachable",
			"origin_node": "a",
			"destination_node": "isolated",
			"vehicle_trips_per_hour": 75.0,
		},
	])
	var totals: Dictionary = result["totals"]
	_expect(_approx(float(totals["vehicle_demand_vph"]), 75.0), "unreachable demand is included in total demand")
	_expect(_approx(float(totals["assigned_vehicle_demand_vph"]), 0.0), "unreachable demand is not falsely assigned")
	_expect(_approx(float(totals["unassigned_vehicle_demand_vph"]), 75.0), "unreachable demand is exposed to gameplay diagnostics")
	var od: Dictionary = (result["od_results"] as Array)[0]
	_expect(not bool(od["assigned"]), "unreachable OD result is marked unassigned")


func _fixture_city() -> Dictionary:
	var local_profile := {
		"road_class": "local",
		"direction": "both",
		"speed_kph": 40.0,
		"lanes": [
			{"type": "vehicle", "direction": "both", "width_m": 3.2},
		],
		"sidewalk": {"left": true, "right": true},
		"parking": {"left": false, "right": false},
		"bus_lane": {"left": false, "right": false},
		"bike_lane": {"left": false, "right": false},
		"tram_reservation": false,
	}
	return {
		"nodes": [
			{"id": "a", "x": 0.0, "y": 0.0},
			{"id": "b", "x": 400.0, "y": 0.0},
			{"id": "c", "x": 0.0, "y": 900.0},
			{"id": "d", "x": 800.0, "y": 0.0},
			{"id": "isolated", "x": 2000.0, "y": 2000.0},
		],
		"roads": [
			{
				"id": "local-shortcut",
				"class": "local",
				"status": "built",
				"profile": local_profile,
			},
			{
				"id": "arterial-bypass",
				"class": "arterial",
				"status": "built",
			},
		],
		"graph_edges": [
			{"id": "edge-local-a", "roadId": "local-shortcut", "class": "local", "a": "a", "b": "b"},
			{"id": "edge-local-b", "roadId": "local-shortcut", "class": "local", "a": "b", "b": "d"},
			{"id": "edge-arterial-a", "roadId": "arterial-bypass", "class": "arterial", "a": "a", "b": "c"},
			{"id": "edge-arterial-b", "roadId": "arterial-bypass", "class": "arterial", "a": "c", "b": "d"},
		],
	}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("RoadTrafficModel: %s" % message)


func _approx(a: float, b: float, tolerance: float = 0.01) -> bool:
	return absf(a - b) <= tolerance
