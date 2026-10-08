extends SceneTree

const CityServices = preload("res://scripts/city/city_services.gd")

var failures := 0


func _initialize() -> void:
	_test_network_connectivity_and_capacity()
	_test_utility_network_set()
	_test_district_catchments()
	if failures == 0:
		print("CityServices tests: PASS")
		quit(0)
	else:
		push_error("CityServices tests: %d failure(s)" % failures)
		quit(1)


func _test_network_connectivity_and_capacity() -> void:
	var network := {
		"sources": [{"id": "plant", "nodeId": "root", "capacity": 20.0}],
		"edges": [
			{"id": "root-mid", "a": "root", "b": "mid", "capacity": 8.0},
			{"id": "mid-a", "a": "mid", "b": "a", "capacity": 10.0},
			{"id": "mid-b", "a": "mid", "b": "b", "capacity": 10.0},
			{"id": "closed", "a": "root", "b": "z", "capacity": 100.0, "active": false},
		],
		"consumers": [
			{"id": "c-a", "nodeId": "a", "demand": 6.0},
			{"id": "c-b", "nodeId": "b", "demand": 6.0},
			{"id": "c-z", "nodeId": "z", "demand": 2.0},
		],
	}
	var result: Dictionary = CityServices.evaluate_network(network)
	_expect(is_equal_approx(float(result["sourceCapacity"]), 20.0), "network source capacity")
	_expect(is_equal_approx(float(result["requested"]), 14.0), "network requested demand")
	_expect(is_equal_approx(float(result["served"]), 8.0), "network max-flow capacity")
	_expect(is_equal_approx(float(result["unserved"]), 6.0), "network unserved demand")
	_expect(int(result["connectedConsumerCount"]) == 2, "network connected consumer count")
	_expect(str(result["consumerStatusById"]["c-a"]["status"]) == "served", "first connected consumer status")
	_expect(str(result["consumerStatusById"]["c-b"]["status"]) == "capacity_limited", "bottlenecked consumer status")
	_expect(str(result["consumerStatusById"]["c-z"]["status"]) == "disconnected", "disabled-edge consumer status")
	_expect(result == CityServices.evaluate_network(network), "network results are deterministic")


func _test_utility_network_set() -> void:
	var results: Dictionary = CityServices.evaluate_utility_networks({"water": {"sources": [], "edges": [], "consumers": []}})
	_expect(results.keys() == CityServices.UTILITY_TYPES, "utility network key order")
	_expect(str(results["water"]["status"]) == "no_demand", "supplied utility network is evaluated")
	_expect(str(results["electricity"]["status"]) == "no_demand", "missing utility network is empty")
	_expect(str(results["sewage"]["status"]) == "no_demand", "all canonical utility types are returned")


func _test_district_catchments() -> void:
	var districts := [{"id": "east"}, {"id": "west"}]
	var demand_points := [
		{
			"id": "west-parcel",
			"districtId": "west",
			"x": 0.0,
			"y": 0.0,
			"demands": {"healthcare": 5.0, "education": 10.0, "fire": 2.0},
		},
		{
			"id": "east-parcel",
			"districtId": "east",
			"x": 10.0,
			"y": 0.0,
			"demands": {"healthcare": 4.0},
		},
	]
	var buildings := [
		{"id": "clinic", "service": "healthcare", "x": 1.0, "y": 0.0, "catchmentRadius": 2.0, "capacity": 3.0},
		{"id": "school", "service": "education", "x": 0.0, "y": 0.0, "catchmentRadius": 4.0, "capacity": 12.0},
	]
	var result: Dictionary = CityServices.evaluate_district_coverage(districts, demand_points, buildings)
	var west: Dictionary = result["districts"]["west"]
	var east: Dictionary = result["districts"]["east"]
	_expect(is_equal_approx(float(west["services"]["healthcare"]["demand"]), 5.0), "west healthcare demand")
	_expect(is_equal_approx(float(west["services"]["healthcare"]["withinCatchment"]), 5.0), "west healthcare catchment")
	_expect(is_equal_approx(float(west["services"]["healthcare"]["served"]), 3.0), "healthcare facility capacity")
	_expect(str(west["services"]["healthcare"]["status"]) == "capacity_limited", "healthcare capacity status")
	_expect(is_equal_approx(float(east["services"]["healthcare"]["withinCatchment"]), 0.0), "east is outside clinic catchment")
	_expect(str(east["services"]["healthcare"]["status"]) == "catchment_limited", "east healthcare catchment status")
	_expect(is_equal_approx(float(west["services"]["education"]["coverage"]), 1.0), "education service coverage")
	_expect(str(west["services"]["fire"]["status"]) == "catchment_limited", "unserved fire demand status")
	_expect(str(east["services"]["police"]["status"]) == "no_demand", "service without demand status")
	_expect(is_equal_approx(float(result["totals"]["services"]["healthcare"]["demand"]), 9.0), "aggregate healthcare demand")
	_expect(is_equal_approx(float(result["totals"]["services"]["healthcare"]["served"]), 3.0), "aggregate healthcare served")
	_expect(result == CityServices.evaluate_district_coverage(districts, demand_points, buildings), "coverage results are deterministic")

	var overlap_result: Dictionary = CityServices.evaluate_district_coverage(
		[{"id": "overlap"}],
		[
			{"id": "flexible", "districtId": "overlap", "x": 0.0, "y": 0.0, "demands": {"healthcare": 5.0}},
			{"id": "constrained", "districtId": "overlap", "x": -1.0, "y": 0.0, "demands": {"healthcare": 5.0}},
		],
		[
			{"id": "a-near", "service": "healthcare", "x": 0.0, "y": 0.0, "catchmentRadius": 1.5, "capacity": 5.0},
			{"id": "b-wide", "service": "healthcare", "x": 10.0, "y": 0.0, "catchmentRadius": 10.0, "capacity": 5.0},
		]
	)
	_expect(is_equal_approx(float(overlap_result["districts"]["overlap"]["total"]["withinCatchment"]), 10.0), "overlapping catchments count each parcel once")
	_expect(is_equal_approx(float(overlap_result["districts"]["overlap"]["total"]["served"]), 10.0), "overlapping catchments use capacity without greedy under-allocation")


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	failures += 1
	push_error("FAIL: %s" % description)
