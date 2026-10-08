extends SceneTree

const TravelChoice = preload("res://scripts/simulation/resident_travel_choice.gd")

var failures := 0


func _initialize() -> void:
	_test_deterministic_flow_reconciliation()
	_test_reachability_and_car_eligibility()
	_test_fares_and_income_affect_choice_and_burden()
	_test_faster_transit_increases_share()
	_test_partial_car_access_changes_mode_choice()
	if failures == 0:
		print("ResidentTravelChoice tests: PASS")
		quit(0)
	else:
		push_error("ResidentTravelChoice tests: %d failure(s)" % failures)
		quit(1)


func _test_deterministic_flow_reconciliation() -> void:
	var input := {
		"od_cohorts": [
			{
				"od_id": "east-west",
				"origin_id": "east",
				"destination_id": "west",
				"cohort_id": "workers",
				"population": 100,
				"trip_count": 240,
				"income": 3000,
				"fare_sensitivity": 1.0,
				"car_eligible": true,
				"car": {"minutes": 34, "cost": 4, "reachable": true},
				"transit": {"minutes": 48, "cost": 2, "reachable": true},
			},
			{
				"od_id": "north-center",
				"origin_id": "north",
				"destination_id": "center",
				"cohort_id": "students",
				"population": 30,
				"trip_count": 72,
				"income": 900,
				"fare_sensitivity": 1.4,
				"car_eligible": false,
				"car": {"minutes": 20, "cost": 3, "reachable": true},
				"transit": {"minutes": 25, "cost": 1, "reachable": true},
			},
		],
	}
	var result: Dictionary = TravelChoice.evaluate(input)
	var repeated: Dictionary = TravelChoice.evaluate(input)
	_expect(result == repeated, "same inputs produce identical OD/cohort flows")
	_expect(is_equal_approx(float(result["totals"]["population"]), 130.0), "population total reconciles")
	_expect(is_equal_approx(float(result["totals"]["trips"]), 312.0), "trip total reconciles")
	var summed_trips := 0.0
	for flow_value in result["flows"]:
		var flow: Dictionary = flow_value
		var mode_flows: Dictionary = flow["flows"]
		var reconciled := float(mode_flows["car"]) + float(mode_flows["transit"]) + float(mode_flows["unserved"])
		_expect(is_equal_approx(reconciled, float(flow["trips"])), "each OD/cohort flow reconciles to trip count")
		_expect(float(mode_flows["car"]) >= 0.0, "car flow is nonnegative")
		_expect(float(mode_flows["transit"]) >= 0.0, "transit flow is nonnegative")
		_expect(float(mode_flows["unserved"]) >= 0.0, "unserved flow is nonnegative")
		summed_trips += reconciled
	_expect(is_equal_approx(summed_trips, float(result["totals"]["trips"])), "all row trips reconcile to aggregate total")


func _test_reachability_and_car_eligibility() -> void:
	var unavailable_transit: Dictionary = TravelChoice.evaluate({
		"od_cohorts": [_base_row({"transit": {"minutes": 15, "cost": 1, "reachable": false}})],
	})
	_expect(
		is_equal_approx(float(unavailable_transit["totals"]["flows"]["transit"]), 0.0),
		"unreachable transit receives no trips"
	)
	var ineligible_car: Dictionary = TravelChoice.evaluate({
		"od_cohorts": [_base_row({"car_eligible": false})],
	})
	_expect(
		is_equal_approx(float(ineligible_car["totals"]["flows"]["car"]), 0.0),
		"car-ineligible cohort receives no car trips"
	)


func _test_fares_and_income_affect_choice_and_burden() -> void:
	var low_income_base := _base_row({"cohort_id": "low", "income": 1000.0, "trip_count": 100.0})
	var low_income_expensive := _base_row({
		"cohort_id": "low",
		"income": 1000.0,
		"trip_count": 100.0,
		"transit": {"minutes": 25, "cost": 2, "reachable": true},
	})
	var high_income_base := _base_row({"cohort_id": "high", "income": 6000.0, "trip_count": 100.0})
	var high_income_expensive := _base_row({
		"cohort_id": "high",
		"income": 6000.0,
		"trip_count": 100.0,
		"transit": {"minutes": 25, "cost": 2, "reachable": true},
	})
	var base: Dictionary = TravelChoice.evaluate({"od_cohorts": [low_income_base, high_income_base]})
	var expensive: Dictionary = TravelChoice.evaluate({"od_cohorts": [low_income_expensive, high_income_expensive]})
	var base_low: Dictionary = base["cohort_welfare"]["low"]
	var base_high: Dictionary = base["cohort_welfare"]["high"]
	var expensive_low: Dictionary = expensive["cohort_welfare"]["low"]
	var expensive_high: Dictionary = expensive["cohort_welfare"]["high"]
	var low_share_change := float(base_low["shares"]["transit"]) - float(expensive_low["shares"]["transit"])
	var high_share_change := float(base_high["shares"]["transit"]) - float(expensive_high["shares"]["transit"])
	_expect(low_share_change > 0.0, "higher fare lowers lower-income transit share")
	_expect(high_share_change > 0.0, "higher fare lowers higher-income transit share")
	_expect(low_share_change > high_share_change, "higher fare shifts lower-income transit share more")
	_expect(float(expensive_low["fare_burden"]) > float(base_low["fare_burden"]), "higher fare raises lower-income fare burden")
	_expect(
		float(expensive_low["fare_burden"]) - float(base_low["fare_burden"])
		> float(expensive_high["fare_burden"]) - float(base_high["fare_burden"]),
		"higher fare raises lower-income fare burden more"
	)


func _test_faster_transit_increases_share() -> void:
	var ordinary: Dictionary = TravelChoice.evaluate({"od_cohorts": [_base_row()]})
	var fast_row := _base_row({"transit": {"minutes": 12, "cost": 1, "reachable": true}})
	var faster: Dictionary = TravelChoice.evaluate({"od_cohorts": [fast_row]})
	_expect(
		float(faster["totals"]["shares"]["transit"]) > float(ordinary["totals"]["shares"]["transit"]),
		"faster transit increases transit share"
	)


func _test_partial_car_access_changes_mode_choice() -> void:
	var full_access_row := _base_row({"cohort_id": "adults", "age_group": "adults", "car_availability": 1.0})
	var limited_access_row := _base_row({"cohort_id": "seniors", "age_group": "seniors", "car_availability": 0.45})
	var no_access_row := _base_row({"cohort_id": "children", "age_group": "children", "car_eligible": false, "car_availability": 0.0})
	var result: Dictionary = TravelChoice.evaluate({"od_cohorts": [full_access_row, limited_access_row, no_access_row]})
	var adult: Dictionary = result["cohort_welfare"]["adults"]
	var senior: Dictionary = result["cohort_welfare"]["seniors"]
	var child: Dictionary = result["cohort_welfare"]["children"]
	_expect(
		float(senior["shares"]["car"]) < float(adult["shares"]["car"]),
		"partial senior car access lowers the car alternative share"
	)
	_expect(
		float(senior["shares"]["transit"]) > float(adult["shares"]["transit"]),
		"partial senior car access makes transit relatively more attractive"
	)
	_expect(
		float(senior["shares"]["car"]) <= 0.45 + 0.000001,
		"car trips cannot exceed the cohort's fractional access to cars"
	)
	_expect(is_equal_approx(float(child["flows"]["car"]), 0.0), "children without a driving alternative never use cars")
	_expect(str(child.get("age_group", "")) == "children", "choice welfare retains age-group diagnostics")
	var scarce_cars: Dictionary = TravelChoice.evaluate({
		"od_cohorts": [_base_row({
			"car_availability": 0.45,
			"car": {"minutes": 0, "cost": 0, "reachable": true},
			"transit": {"reachable": false},
		})],
	})
	_expect(
		float(scarce_cars["totals"]["shares"]["car"]) <= 0.45 + 0.000001,
		"car remains limited to available drivers even when it is the best alternative"
	)


func _base_row(overrides: Dictionary = {}) -> Dictionary:
	var row := {
		"od_id": "home-job",
		"origin_id": "home",
		"destination_id": "job",
		"cohort_id": "adults",
		"population": 50,
		"trip_count": 80,
		"income": 3000,
		"fare_sensitivity": 1.0,
		"car_eligible": true,
		"car": {"minutes": 35, "cost": 4, "reachable": true},
		"transit": {"minutes": 25, "cost": 1, "reachable": true},
	}
	for key in overrides:
		row[key] = overrides[key]
	return row


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	failures += 1
	push_error("FAIL: %s" % description)
