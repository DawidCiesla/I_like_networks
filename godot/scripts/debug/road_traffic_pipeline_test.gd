extends SceneTree

const ResidentTravelChoice = preload("res://scripts/simulation/resident_travel_choice.gd")
const RoadTrafficDemand = preload("res://scripts/simulation/road_traffic_demand.gd")
const RoadTrafficModel = preload("res://scripts/simulation/road_traffic_model.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var city := _fixture_city()
	var car_favored := _evaluate_scenario(city, 10.0, 55.0)
	var transit_favored := _evaluate_scenario(city, 30.0, 6.0)

	_expect(float(car_favored["car_share"]) > float(transit_favored["car_share"]), "more attractive transit lowers resident car mode share")
	_expect(float(car_favored["vehicle_vph"]) > float(transit_favored["vehicle_vph"]), "lower car mode share converts to lower vehicle demand")
	_expect(float(car_favored["road_flow_vph"]) > float(transit_favored["road_flow_vph"]), "lower resident vehicle demand reaches the assigned road flow")
	_expect(float(car_favored["road_flow_vph"]) > 0.0, "car-favored scenario creates road traffic")
	_expect(float(transit_favored["road_flow_vph"]) >= 0.0, "transit-favored scenario remains numerically valid")

	if _failures == 0:
		print("ROAD TRAFFIC PIPELINE TEST: PASS")
		quit(0)
		return
	push_error("ROAD TRAFFIC PIPELINE TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _evaluate_scenario(city: Dictionary, car_minutes: float, transit_minutes: float) -> Dictionary:
	var choice := ResidentTravelChoice.evaluate({
		"od_cohorts": [
			{
				"od_id": "a-b-adults",
				"origin_id": "a",
				"destination_id": "b",
				"cohort_id": "adults",
				"population": 1000.0,
				"trip_count": 1000.0,
				"income": 100.0,
				"fare_sensitivity": 1.0,
				"car_eligible": true,
				"car_availability": 1.0,
				"car": {"reachable": true, "minutes": car_minutes, "cost": 0.0},
				"transit": {"reachable": true, "minutes": transit_minutes, "cost": 0.0},
			},
		],
		"parameters": {
			"logit_scale_minutes": 5.0,
			"fare_minutes_per_currency": 0.0,
			"reference_income": 100.0,
			"minimum_income": 1.0,
			"unserved_penalty_minutes": 90.0,
		},
	})
	var choice_totals: Dictionary = choice["totals"]
	var shares: Dictionary = choice_totals["shares"]
	var demand := RoadTrafficDemand.from_travel_choice(choice, {
		"period_hours": 1.0,
		"average_car_occupancy": 1.0,
	})
	_expect(bool(demand["valid"]), "travel-choice result converts into valid road demand")
	var traffic := RoadTrafficModel.evaluate(city, demand["demands"])
	var road: Dictionary = (traffic["road_metrics"] as Dictionary)["regional-road"]
	return {
		"car_share": float(shares["car"]),
		"vehicle_vph": float((demand["totals"] as Dictionary)["vehicle_trips_per_hour"]),
		"road_flow_vph": float(road["flow_vph"]),
	}


func _fixture_city() -> Dictionary:
	return {
		"nodes": [
			{"id": "a", "x": 0.0, "y": 0.0},
			{"id": "b", "x": 1000.0, "y": 0.0},
		],
		"roads": [
			{"id": "regional-road", "class": "collector", "status": "built"},
		],
		"graph_edges": [
			{"id": "regional-edge", "roadId": "regional-road", "class": "collector", "a": "a", "b": "b"},
		],
	}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("RoadTrafficPipeline: %s" % message)
