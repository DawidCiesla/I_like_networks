extends SceneTree

const Data = preload("res://scripts/core/game_data.gd")
const GameStoreScript = preload("res://scripts/core/game_store.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const ResidentHealth = preload("res://scripts/simulation/resident_health.gd")

var failures := 0


func _initialize() -> void:
	var store = GameStoreScript.new()
	store.suppress_persistence = true
	store.city_seed = 731945
	store.reset_state(false)

	_test_starter_demand_favors_car(store)
	_test_transport_choice_uses_resident_age_cohorts(store)
	_test_health_feedback_does_not_duplicate_population_flows()
	_test_resident_health_joins_live_city_data(store)
	_test_transport_exposure_reaches_health_metrics(store)
	_test_reachable_service_captures_only_its_od_demand(store)
	_test_discounted_fares_reach_operator_revenue()
	_test_sandbox_transfers_wait_for_actual_alighting()
	_test_transfer_walk_delay_survives_save_load_and_fares()
	_test_transfer_capacity_preserves_discounted_fares()
	_test_old_custom_save_queues_remain_full_fare()
	_test_sandbox_line_price_includes_its_starter_bus(store)

	store.free()
	if failures == 0:
		print("Resident transport GameStore tests: PASS")
		quit(0)
	else:
		push_error("Resident transport GameStore tests: %d failure(s)" % failures)
		quit(1)


func _test_starter_demand_favors_car(store) -> void:
	var metrics: Dictionary = store.resident_transport_metrics()
	var snapshot: Dictionary = store._resident_transport_snapshot()
	var repeated_snapshot: Dictionary = store._resident_transport_snapshot()
	_expect(int(metrics.get("resident_count", 0)) > 0, "starter region has resident population")
	_expect(float(metrics.get("expected_transit_trips_per_hour", 0.0)) == 0.0, "no service means zero transit demand served")
	_expect(int(metrics.get("reachable_car_od_pairs", 0)) > 0, "completed starter roads connect at least part of the region")
	_expect(float(metrics.get("car_share", 0.0)) > 0.0, "starter population has car demand")
	_expect(
		float(metrics.get("car_share", 0.0)) > float(metrics.get("transit_share", 0.0)),
		"without transit, mode choice favors the available car option"
	)
	_expect(float(metrics.get("average_wellbeing", -1.0)) >= 0.0, "starter welfare metric is bounded and populated")
	_expect(float(metrics.get("public_treasury", -1.0)) == float(store.money), "metrics report the live public treasury")
	_expect(snapshot.get("choice", {}) == repeated_snapshot.get("choice", {}), "employment-weighted OD/cohort flows are deterministic")
	_expect(
		is_equal_approx(
			float(snapshot.get("choice", {}).get("totals", {}).get("trips", 0.0)),
			float(metrics.get("resident_count", 0)) * 0.55
		),
		"job attraction redistributes destinations without creating or losing resident trips"
	)


func _test_transport_choice_uses_resident_age_cohorts(store) -> void:
	var snapshot: Dictionary = store._resident_transport_snapshot()
	var age_metrics: Dictionary = snapshot.get("metrics", {}).get("age_group_transport", {})
	_expect(age_metrics.has("children") and age_metrics.has("adults") and age_metrics.has("seniors"), "resident transport reports child, adult, and senior outcomes")
	if not age_metrics.has("children") or not age_metrics.has("adults") or not age_metrics.has("seniors"):
		return
	var children: Dictionary = age_metrics["children"]
	var adults: Dictionary = age_metrics["adults"]
	var seniors: Dictionary = age_metrics["seniors"]
	var age_population := float(children.get("population", 0.0)) + float(adults.get("population", 0.0)) + float(seniors.get("population", 0.0))
	_expect(is_equal_approx(age_population, float(store.resident_transport_metrics().get("resident_count", 0))), "health-model age cohorts reconcile to city residents")
	_expect(is_equal_approx(float(children.get("car_share", -1.0)), 0.0), "children have no personal car option in the mode-choice model")
	_expect(float(seniors.get("car_share", 0.0)) < float(adults.get("car_share", 0.0)), "lower senior car access shifts trips away from private cars")
	var choice: Dictionary = snapshot.get("choice", {})
	var age_trip_total := float(children.get("trips_per_day", 0.0)) + float(adults.get("trips_per_day", 0.0)) + float(seniors.get("trips_per_day", 0.0))
	_expect(is_equal_approx(age_trip_total, float(choice.get("totals", {}).get("trips", 0.0))), "age-specific daily trips reconcile to city demand")


func _test_health_feedback_does_not_duplicate_population_flows() -> void:
	var health_store = GameStoreScript.new()
	health_store.suppress_persistence = true
	health_store.city_seed = 732015
	health_store.reset_state(false)
	var settlements: Array = health_store.city.get("regional_settlements", [])
	if settlements.is_empty():
		_expect(false, "health flow fixture includes a regional settlement")
		health_store.free()
		return
	var settlement: Dictionary = settlements[0]
	var settlement_id := str(settlement.get("id", ""))
	var starting_population := 100000.0
	settlement["population"] = starting_population
	var state: Dictionary = health_store.city.get("resident_health_state", {}).duplicate(true)
	var districts: Dictionary = state.get("districts", {})
	var district: Dictionary = districts.get(settlement_id, {})
	var cohorts: Dictionary = district.get("cohorts", {})
	for cohort_id in cohorts:
		var cohort: Dictionary = cohorts[cohort_id]
		cohort["population"] = starting_population if str(cohort.get("age_group", cohort_id)) == "seniors" else 0.0
		cohort["acute_cases"] = 0.0
		cohort["chronic_cases"] = 0.0
		cohorts[cohort_id] = cohort
	district["population"] = starting_population
	district["observed_population"] = starting_population
	district["cohorts"] = cohorts
	districts[settlement_id] = district
	state["districts"] = districts
	health_store.city["resident_health_state"] = state
	health_store._resident_health_snapshot_cache.clear()
	health_store._resident_transport_snapshot_cache.clear()

	var previous_stock := starting_population
	for step in range(3):
		_expect(health_store._advance_resident_health(30.0), "health simulation advances fixed-step cohort flows")
		var advanced_state: Dictionary = health_store.city.get("resident_health_state", {})
		var advanced_district: Dictionary = advanced_state.get("districts", {}).get(settlement_id, {})
		var advanced_stock := float(advanced_district.get("population", 0.0))
		_expect(advanced_stock < previous_stock, "senior mortality changes the population stock")
		var normalized_input: Dictionary = health_store._resident_health_input()
		var normalized_settlement: Dictionary = {}
		for row_value in normalized_input.get("settlements", []):
			var row: Dictionary = row_value
			if str(row.get("id", "")) == settlement_id:
				normalized_settlement = row
				break
		_expect(
			is_equal_approx(float(normalized_settlement.get("population", -1.0)), starting_population),
			"health-adjusted deaths are excluded from the external city-population observation"
		)
		previous_stock = advanced_stock

	settlement["population"] = float(settlement.get("population", 0.0)) + 100.0
	var grown_input: Dictionary = health_store._resident_health_input()
	var grown_settlement: Dictionary = {}
	for row_value in grown_input.get("settlements", []):
		var row: Dictionary = row_value
		if str(row.get("id", "")) == settlement_id:
			grown_settlement = row
			break
	_expect(
		is_equal_approx(float(grown_settlement.get("population", -1.0)), starting_population + 100.0),
		"autonomous city growth remains visible after removing the modeled health adjustment"
	)
	var grown_stock_before_tick := previous_stock
	_expect(health_store._advance_resident_health(30.0), "health simulation accepts new city growth")
	var final_state: Dictionary = health_store.city.get("resident_health_state", {})
	var final_district: Dictionary = final_state.get("districts", {}).get(settlement_id, {})
	var final_stock := float(final_district.get("population", 0.0))
	var advanced_metrics: Dictionary = health_store._resident_health_snapshot_cache.get("metrics", {})
	var final_health_district: Dictionary = advanced_metrics.get("districts", {}).get(settlement_id, {})
	var expected_stock := (
		grown_stock_before_tick
		+ 100.0
		+ float(final_health_district.get("births", 0.0))
		- float(final_health_district.get("deaths", 0.0))
	)
	_expect(
		is_equal_approx(final_stock, expected_stock),
		"external growth is incorporated once while fresh births and deaths apply once"
	)
	health_store.free()


func _test_resident_health_joins_live_city_data(store) -> void:
	var first: Dictionary = store.resident_health_metrics()
	var second: Dictionary = store.resident_health_metrics()
	var expected_population := 0
	var settlements: Array = store.city.get("regional_settlements", [])
	var current_services: Dictionary = store._current_regional_service_results()
	var service_districts: Dictionary = current_services.get("services", {}).get("districts", {})
	var transport_districts: Dictionary = store.resident_transport_metrics().get("districts", {})
	for settlement_value in settlements:
		var settlement: Dictionary = settlement_value
		var settlement_id := str(settlement.get("id", ""))
		expected_population += maxi(0, int(settlement.get("population", 0)))
		_expect(first.get("districts", {}).has(settlement_id), "health results preserve regional settlement identity")
		var care: Dictionary = service_districts.get(settlement_id, {}).get("services", {}).get("healthcare", {})
		var district_health: Dictionary = first.get("districts", {}).get(settlement_id, {})
		_expect(
			is_equal_approx(float(district_health.get("healthcare_coverage", -1.0)), float(care.get("coverage", -2.0))),
			"healthcare coverage is calculated from the current service facilities and settlement population"
		)
		_expect(transport_districts.has(settlement_id), "transport choice is attributed to its home settlement")
	_expect(int(first.get("population", -1.0)) == expected_population, "health population matches the aggregate regional population")
	_expect(first == second, "live health evaluation is deterministic")
	_expect(
		float(first.get("health_index", -1.0)) >= 0.0 and float(first.get("health_index", 101.0)) <= 100.0,
		"integrated health index stays within its public 0-100 scale"
	)
	_expect(
		float(first.get("healthcare_coverage", -1.0)) >= 0.0 and float(first.get("healthcare_coverage", 2.0)) <= 1.0,
		"integrated healthcare coverage is a normalized ratio"
	)
	var initial_health_state: Dictionary = store.city.get("resident_health_state", {}).duplicate(true)
	_expect(not store._advance_resident_health(29.0), "cohort health waits for its fixed simulation interval")
	_expect(
		store.city.get("resident_health_state", {}) == initial_health_state,
		"health cohorts do not change before the interval elapses"
	)
	_expect(store._advance_resident_health(1.0), "health cohorts advance when the interval elapses")
	var advanced_health_state: Dictionary = store.city.get("resident_health_state", {})
	_expect(
		float(advanced_health_state.get("elapsed_years", 0.0)) > float(initial_health_state.get("elapsed_years", 0.0)),
		"health state stores simulated years for save persistence"
	)
	var mirrored_population := 0.0
	for settlement_value in store.city.get("regional_settlements", []):
		mirrored_population += maxf(0.0, float(settlement_value.get("population", 0.0)))
	_expect(
		is_equal_approx(mirrored_population, float(store.resident_health_metrics().get("population", -1.0))),
		"health-driven births and deaths update the same population used by the city and transit simulation"
	)
	_expect(
		int(store.city.get("demographics", {}).get("residents", -1)) == roundi(mirrored_population),
		"regional demographic totals mirror the fractional population stock"
	)
	_expect(
		int(advanced_health_state.get("schema_version", 0)) == ResidentHealth.HEALTH_STATE_SCHEMA_VERSION,
		"health saves use the disease-aware state schema"
	)
	var original_facilities: Array = store.city.get("service_buildings", []).duplicate(true)
	for facility_value in store.city.get("service_buildings", []):
		var facility: Dictionary = facility_value
		if str(facility.get("service", "")) == "healthcare":
			facility["capacity"] = 0.0
	var strained: Dictionary = store.resident_health_metrics()
	_expect(
		float(strained.get("healthcare_coverage", 1.0)) < float(first.get("healthcare_coverage", 1.0)),
		"changing healthcare capacity invalidates the cached evaluation"
	)
	_expect(
		float(strained.get("health_index", 100.0)) < float(first.get("health_index", 100.0)),
		"health outcomes respond to the actual capacity of regional healthcare facilities"
	)
	store.city["service_buildings"] = original_facilities


func _test_transport_exposure_reaches_health_metrics(store) -> void:
	var transport: Dictionary = store.resident_transport_metrics()
	var health_input: Dictionary = store._resident_health_input(transport)
	var exposures: Dictionary = health_input.get("exposure_by_settlement", {})
	var transport_districts: Dictionary = transport.get("districts", {})
	var clean_input := health_input.duplicate(true)
	var clean_exposures: Dictionary = clean_input.get("exposure_by_settlement", {})
	var checked := 0
	for settlement_value in store.city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var settlement_id := str(settlement.get("id", ""))
		var local: Dictionary = transport_districts.get(settlement_id, {})
		var expected_exposure := clampf(
			0.06 + float(local.get("car_share", transport.get("car_share", 0.0))) * 0.60
			+ float(local.get("unserved_share", transport.get("unserved_share", 0.0))) * 0.12,
			0.0,
			1.0
		)
		_expect(
			is_equal_approx(float(exposures.get(settlement_id, -1.0)), expected_exposure),
			"local car use and unserved trips produce the settlement's health exposure input"
		)
		clean_exposures[settlement_id] = 0.0
		checked += 1
	clean_input["exposure_by_settlement"] = clean_exposures
	var exposed: Dictionary = ResidentHealth.evaluate(health_input)
	var clean: Dictionary = ResidentHealth.evaluate(clean_input)
	_expect(checked > 0, "transport exposure is checked against at least one settlement")
	_expect(
		float(clean.get("health_index", 0.0)) > float(exposed.get("health_index", 0.0)),
		"reducing transport exposure improves the integrated health estimate"
	)


func _test_reachable_service_captures_only_its_od_demand(store) -> void:
	var before: Dictionary = store.resident_transport_metrics()
	var settlements: Array = store.city.get("regional_settlements", [])
	var pair := _farthest_settlement_pair(settlements)
	if pair.size() != 2:
		_expect(false, "regional settlements provide a test OD pair")
		return
	var origin: Dictionary = pair[0]
	var destination: Dictionary = pair[1]
	var origin_position := _position(origin.get("position", Vector2.ZERO))
	var destination_position := _position(destination.get("position", Vector2.ZERO))
	var distance := origin_position.distance_to(destination_position)
	var line_id := "sandbox-test-line"
	var origin_stop_id := "sandbox-test-origin"
	var destination_stop_id := "sandbox-test-destination"
	store.transit_network = {
		"schema_version": 2,
		"source": "free_lines",
		"next_stop_serial": 1,
		"next_line_serial": 1,
		"stops": {
			origin_stop_id: _stop(origin_stop_id, origin_position, line_id),
			destination_stop_id: _stop(destination_stop_id, destination_position, line_id),
		},
		"lines": {
			line_id: {
				"id": line_id,
				"name": "Test service",
				"source": "custom",
				"status": "active",
				"stop_ids": [origin_stop_id, destination_stop_id],
				"route_segments": [{"length_world": distance}],
				"route_length_world": distance,
				"fleet_count": 1,
				"vehicles": [],
				"next_vehicle_id": 1,
				"waiting_by_stop": store._create_waiting_matrix(2),
				"queue_passengers": 0.0,
			},
		},
	}
	store._resident_transport_snapshot_cache.clear()
	var after: Dictionary = store.resident_transport_metrics()
	var age_groups: Dictionary = after.get("age_group_transport", {})
	_expect(float(age_groups.get("children", {}).get("transit_share", 0.0)) > 0.0, "children use a reachable transit line and receive the discounted fare")
	_expect(float(age_groups.get("seniors", {}).get("transit_share", 0.0)) > 0.0, "senior demand contributes to reachable public transit")
	_expect(
		float(age_groups.get("children", {}).get("fare_per_transit_trip", 0.0))
		< float(age_groups.get("adults", {}).get("fare_per_transit_trip", INF)),
		"age-based transit fare discounts are reflected in passenger cost metrics"
	)
	_expect(float(after.get("transit_share", 0.0)) > 0.0, "a reachable bus line captures resident trips")
	_expect(
		float(after.get("transit_share", 0.0)) > float(before.get("transit_share", 0.0)),
		"adding reachable transit increases aggregate transit share"
	)
	_expect(
		int(after.get("reachable_transit_od_pairs", 0)) > 0
		and int(after.get("reachable_transit_od_pairs", 0)) < int(after.get("total_od_pairs", 0)),
		"only some regional OD pairs can reach this line"
	)
	var saw_unreachable := false
	for diagnostic_value in after.get("od_diagnostics", []):
		var diagnostic: Dictionary = diagnostic_value
		if not bool(diagnostic.get("transit_reachable", false)):
			saw_unreachable = true
			_expect(
				float(diagnostic.get("transit_trips_per_hour", 0.0)) == 0.0,
				"unreachable OD pairs receive no transit flow"
			)
	_expect(saw_unreachable, "the diagnostics expose at least one unreachable OD pair")
	var network_lines: Dictionary = store.transit_network.get("lines", {})
	var test_line: Dictionary = network_lines[line_id]
	var clear_capacity_share := float(after.get("transit_share", 0.0))
	test_line["crowding_ratio"] = 1.0
	network_lines[line_id] = test_line
	store.transit_network["lines"] = network_lines
	store._resident_transport_snapshot_cache.clear()
	var crowded: Dictionary = store.resident_transport_metrics()
	_expect(
		float(crowded.get("transit_share", 1.0)) < clear_capacity_share,
		"overcrowded transit lowers mode-choice share until capacity improves"
	)
	_expect(
		float(crowded.get("average_transit_capacity_pressure", 0.0)) > 0.9,
		"aggregate resident metrics expose the overcrowding behind the lower share"
	)
	test_line["crowding_ratio"] = 0.0
	network_lines[line_id] = test_line
	store.transit_network["lines"] = network_lines
	store._resident_transport_snapshot_cache.clear()

	# A daily aggregate demand should be spread over 1,440 game minutes. This
	# full-day injection makes the passenger queue and fare-delivery path testable.
	store._generate_resident_transport_demand(1440.0)
	var line: Dictionary = store.transit_network["lines"][line_id]
	_expect(float(line.get("queue_passengers", 0.0)) > 0.0, "model transit flows enter the normal passenger queue")
	_expect(
		float(line.get("crowding_ratio", 0.0)) > 0.0,
		"station queue limits feed crowding back to the next travel-choice update"
	)
	store._simulate_custom_line(line_id, 300.0)
	_expect(float(store.stats.get("lifetime_revenue", 0.0)) > 0.0, "modeled riders can complete trips and pay fares")


func _test_discounted_fares_reach_operator_revenue() -> void:
	var fare_store = GameStoreScript.new()
	fare_store.suppress_persistence = true
	fare_store.reset_state(false)
	var line_id := "discount-fare-test"
	var origin_id := "discount-fare-origin"
	var destination_id := "discount-fare-destination"
	var origin_position := Vector2(100.0, 100.0)
	var destination_position := Vector2(500.0, 100.0)
	fare_store.transit_network = {
		"schema_version": 2,
		"source": "free_lines",
		"next_stop_serial": 1,
		"next_line_serial": 1,
		"stops": {
			origin_id: _stop(origin_id, origin_position, line_id),
			destination_id: _stop(destination_id, destination_position, line_id),
		},
		"lines": {
			line_id: {
				"id": line_id,
				"name": "Discount test",
				"source": "custom",
				"status": "active",
				"mode": "bus",
				"stop_ids": [origin_id, destination_id],
				"route_segments": [{"length_world": 400.0}],
				"route_length_world": 400.0,
				"fleet_count": 1,
				"vehicles": [],
				"next_vehicle_id": 1,
			},
		},
	}
	fare_store._ensure_custom_line_runtime(line_id)
	var network_lines: Dictionary = fare_store.transit_network.get("lines", {})
	var line: Dictionary = network_lines[line_id]
	line["waiting_by_stop"] = [[0.0, 10.0], [0.0, 0.0]]
	line["waiting_fare_weights_by_stop"] = [[0.0, 5.0], [0.0, 0.0]]
	network_lines[line_id] = line
	fare_store.transit_network["lines"] = network_lines
	line = fare_store.transit_network["lines"][line_id]
	var vehicle: Dictionary = line["vehicles"][0]
	var boarded := fare_store._custom_board_at_stop(line_id, vehicle)
	_expect(is_equal_approx(boarded, 10.0), "passenger boarding preserves the discounted cohort mix")
	var vehicle_revenue_basis: Array = vehicle.get("onboard_fare_weights_by_destination", [])
	_expect(is_equal_approx(float(vehicle_revenue_basis[1]), 5.0), "vehicle carries fare-weighted passengers to their destination")
	fare_store._custom_unload_at_stop(line_id, vehicle, 1)
	_expect(
		is_equal_approx(
			float(fare_store.stats.get("lifetime_revenue", 0.0)),
			5.0 * float(Data.ECONOMY["fare_per_passenger"])
		),
		"operator revenue reflects fares paid by discounted groups"
	)
	fare_store.free()


func _test_sandbox_transfers_wait_for_actual_alighting() -> void:
	var transfer_store = GameStoreScript.new()
	transfer_store.suppress_persistence = true
	transfer_store.reset_state(false)
	_install_transfer_test_lines(transfer_store, [
		{"id": "transfer-a", "stops": ["a0", "a1"], "points": [Vector2(100.0, 100.0), Vector2(400.0, 100.0)]},
		{"id": "transfer-b", "stops": ["b0", "b1"], "points": [Vector2(420.0, 100.0), Vector2(720.0, 100.0)]},
		{"id": "transfer-c", "stops": ["c0", "c1"], "points": [Vector2(740.0, 100.0), Vector2(1040.0, 100.0)]},
	])
	var route_legs := [
		{"mode": "ride", "line_id": "transfer-a", "from_stop_id": "a0", "to_stop_id": "a1"},
		{"mode": "walk", "line_id": "", "from_stop_id": "a1", "to_stop_id": "b0"},
		{"mode": "ride", "line_id": "transfer-b", "from_stop_id": "b0", "to_stop_id": "b1"},
		{"mode": "walk", "line_id": "", "from_stop_id": "b1", "to_stop_id": "c0"},
		{"mode": "ride", "line_id": "transfer-c", "from_stop_id": "c0", "to_stop_id": "c1"},
	]
	_cache_transfer_flow(transfer_store, 20.0, "seniors", route_legs)
	transfer_store._generate_resident_transport_demand(1440.0)
	var lines: Dictionary = transfer_store.transit_network.get("lines", {})
	var line_a: Dictionary = lines["transfer-a"]
	var line_b: Dictionary = lines["transfer-b"]
	var line_c: Dictionary = lines["transfer-c"]
	_expect(is_equal_approx(float(line_a["queue_passengers"]), 20.0), "a multileg trip enters only its first line queue")
	_expect(is_equal_approx(float(line_b.get("queue_passengers", 0.0)), 0.0), "a later line has no queue before the first boarding")
	_expect(is_equal_approx(float(line_c.get("queue_passengers", 0.0)), 0.0), "a third line has no queue before either transfer")
	var fare_weights_a: Array = line_a.get("waiting_fare_weights_by_stop", [])
	_expect(is_equal_approx(float(fare_weights_a[0][1]), 14.0), "the first queue keeps the senior fare weight")
	var vehicle_a: Dictionary = line_a["vehicles"][0]
	_expect(is_equal_approx(transfer_store._custom_board_at_stop("transfer-a", vehicle_a), 20.0), "the first line boards its queued cohort")
	transfer_store._custom_unload_at_stop("transfer-a", vehicle_a, 0)
	line_b = transfer_store.transit_network["lines"]["transfer-b"]
	_expect(is_equal_approx(float(line_b.get("queue_passengers", 0.0)), 0.0), "an origin-stop unload does not create transfer demand")
	transfer_store._custom_unload_at_stop("transfer-a", vehicle_a, 1)
	line_b = transfer_store.transit_network["lines"]["transfer-b"]
	_expect(is_equal_approx(float(line_b.get("queue_passengers", 0.0)), 20.0), "alighting on the first line creates the next-line queue")
	var fare_weights_b: Array = line_b.get("waiting_fare_weights_by_stop", [])
	_expect(is_equal_approx(float(fare_weights_b[0][1]), 14.0), "the senior discount carries to the second boarding")
	var vehicle_b: Dictionary = line_b["vehicles"][0]
	_expect(is_equal_approx(transfer_store._custom_board_at_stop("transfer-b", vehicle_b), 20.0), "the second line boards only the transferred cohort")
	transfer_store._custom_unload_at_stop("transfer-b", vehicle_b, 1)
	line_c = transfer_store.transit_network["lines"]["transfer-c"]
	_expect(is_equal_approx(float(line_c.get("queue_passengers", 0.0)), 20.0), "the remaining third-line ride is queued after the second alighting")
	var fare_weights_c: Array = line_c.get("waiting_fare_weights_by_stop", [])
	_expect(is_equal_approx(float(fare_weights_c[0][1]), 14.0), "the senior discount survives a second transfer")
	transfer_store.free()


func _test_transfer_capacity_preserves_discounted_fares() -> void:
	var capacity_store = GameStoreScript.new()
	capacity_store.suppress_persistence = true
	capacity_store.reset_state(false)
	_install_transfer_test_lines(capacity_store, [
		{"id": "capacity-b", "stops": ["b0", "b1"], "points": [Vector2(100.0, 100.0), Vector2(400.0, 100.0)]},
		{"id": "capacity-c", "stops": ["c0", "c1"], "points": [Vector2(420.0, 100.0), Vector2(720.0, 100.0)]},
	])
	var continuation := [
		{"mode": "ride", "line_id": "capacity-b", "from_stop_id": "b0", "to_stop_id": "b1"},
		{"mode": "ride", "line_id": "capacity-c", "from_stop_id": "c0", "to_stop_id": "c1"},
	]
	capacity_store._enqueue_resident_transfer_group({
		"passengers": 60.0,
		"fare_weighted_passengers": 42.0,
		"remaining_ride_legs": continuation,
	}, 10.0)
	var line_b: Dictionary = capacity_store.transit_network["lines"]["capacity-b"]
	var fare_weights_b: Array = line_b.get("waiting_fare_weights_by_stop", [])
	var transfer_groups_b: Array = line_b.get("resident_transfer_groups_by_stop", [])
	var expected_capacity := float(Data.STATION_UPGRADE["waiting_capacity"][0])
	_expect(is_equal_approx(float(line_b.get("queue_passengers", 0.0)), expected_capacity), "a transfer queue is capped at its stop capacity")
	_expect(is_equal_approx(float(fare_weights_b[0][1]), 31.5), "capacity abandonment scales discounted fare weight with passengers")
	_expect(is_equal_approx(float(line_b.get("total_abandoned_passengers", 0.0)), 15.0), "excess transfer passengers are recorded as abandoned")
	_expect(
		is_equal_approx(float(transfer_groups_b[0][1][0]["passengers"]), expected_capacity)
		and is_equal_approx(float(transfer_groups_b[0][1][0]["fare_weighted_passengers"]), 31.5),
		"the capped continuation manifest matches the surviving discounted queue"
	)
	var vehicle_b: Dictionary = line_b["vehicles"][0]
	var boarded := capacity_store._custom_board_at_stop("capacity-b", vehicle_b)
	_expect(is_equal_approx(boarded, 40.0), "vehicle capacity boards only part of the capped transfer group")
	capacity_store._custom_unload_at_stop("capacity-b", vehicle_b, 1)
	var line_c: Dictionary = capacity_store.transit_network["lines"]["capacity-c"]
	var fare_weights_c: Array = line_c.get("waiting_fare_weights_by_stop", [])
	_expect(is_equal_approx(float(line_c.get("queue_passengers", 0.0)), 40.0), "only the boarded passengers continue to the next line")
	_expect(is_equal_approx(float(fare_weights_c[0][1]), 28.0), "the transferred subset keeps its proportional age discount")
	capacity_store.free()


func _test_transfer_walk_delay_survives_save_load_and_fares() -> void:
	var transfer_store = GameStoreScript.new()
	transfer_store.suppress_persistence = true
	transfer_store.reset_state(false)
	_install_transfer_test_lines(transfer_store, [
		{"id": "walk-transfer-a", "stops": ["wa0", "wa1"], "points": [Vector2(100.0, 100.0), Vector2(400.0, 100.0)]},
		{"id": "walk-transfer-b", "stops": ["wb0", "wb1"], "points": [Vector2(420.0, 100.0), Vector2(720.0, 100.0)]},
		{"id": "walk-transfer-c", "stops": ["wc0", "wc1"], "points": [Vector2(740.0, 100.0), Vector2(1040.0, 100.0)]},
	])
	var route_legs := [
		{"mode": "ride", "line_id": "walk-transfer-a", "from_stop_id": "wa0", "to_stop_id": "wa1"},
		{"mode": "walk", "line_id": "", "from_stop_id": "wa1", "to_stop_id": "wb0", "time_minutes": 4.0},
		{"mode": "ride", "line_id": "walk-transfer-b", "from_stop_id": "wb0", "to_stop_id": "wb1"},
		{"mode": "walk", "line_id": "", "from_stop_id": "wb1", "to_stop_id": "wc0", "time_minutes": 6.0},
		{"mode": "ride", "line_id": "walk-transfer-c", "from_stop_id": "wc0", "to_stop_id": "wc1"},
	]
	_cache_transfer_flow(transfer_store, 45.0, "seniors", route_legs)
	transfer_store._generate_resident_transport_demand(1440.0)
	var line_a: Dictionary = transfer_store.transit_network["lines"]["walk-transfer-a"]
	var line_b: Dictionary = transfer_store.transit_network["lines"]["walk-transfer-b"]
	var line_c: Dictionary = transfer_store.transit_network["lines"]["walk-transfer-c"]
	var vehicle_a: Dictionary = line_a["vehicles"][0]
	_expect(is_equal_approx(transfer_store._custom_board_at_stop("walk-transfer-a", vehicle_a), 40.0), "the first bus boards up to its passenger capacity")
	transfer_store._custom_unload_at_stop("walk-transfer-a", vehicle_a, 1)
	line_b = transfer_store.transit_network["lines"]["walk-transfer-b"]
	line_c = transfer_store.transit_network["lines"]["walk-transfer-c"]
	_expect(is_equal_approx(float(line_b.get("queue_passengers", 0.0)), 0.0), "the next line remains empty while transfer passengers walk")
	_expect(is_equal_approx(float(line_c.get("queue_passengers", 0.0)), 0.0), "a later transfer line remains empty before either walk")
	var pending: Array = transfer_store.transit_network.get("pending_resident_transfers", [])
	_expect(pending.size() == 1 and is_equal_approx(float(pending[0].get("remaining_walk_minutes", 0.0)), 4.0), "the transfer stores the unelapsed walking time")

	var save_json := JSON.stringify(transfer_store._current_save_payload())
	var parsed_save := JSON.new()
	var parse_error := parsed_save.parse(save_json)
	_expect(parse_error == OK, "pending transfer state serializes as a valid save")
	if parse_error != OK:
		transfer_store.free()
		return
	var restored_store = GameStoreScript.new()
	restored_store.suppress_persistence = true
	restored_store.reset_state(false)
	restored_store._apply_payload(parsed_save.data)
	var restored_pending: Array = restored_store.transit_network.get("pending_resident_transfers", [])
	_expect(
		restored_pending.size() == 1
		and is_equal_approx(float(restored_pending[0].get("remaining_walk_minutes", 0.0)), 4.0)
		and is_equal_approx(float(restored_pending[0].get("fare_weighted_passengers", 0.0)), 28.0),
		"save/load preserves the transfer delay and discounted passenger manifest"
	)
	_set_empty_transfer_test_snapshot(restored_store)
	restored_store._generate_resident_transport_demand(3.5)
	line_b = restored_store.transit_network["lines"]["walk-transfer-b"]
	_expect(is_equal_approx(float(line_b.get("queue_passengers", 0.0)), 0.0), "the transfer does not arrive before the walk finishes")
	restored_store._generate_resident_transport_demand(0.6)
	line_b = restored_store.transit_network["lines"]["walk-transfer-b"]
	var fare_weights_b: Array = line_b.get("waiting_fare_weights_by_stop", [])
	_expect(is_equal_approx(float(line_b.get("queue_passengers", 0.0)), 40.0), "the transferred boarded passengers join the next line after walking")
	_expect(is_equal_approx(float(fare_weights_b[0][1]), 28.0), "the delayed queue preserves the senior discount proportionally")
	var vehicle_b: Dictionary = line_b["vehicles"][0]
	_expect(is_equal_approx(restored_store._custom_board_at_stop("walk-transfer-b", vehicle_b), 40.0), "the next bus boards the arriving transfer cohort")
	restored_store._custom_unload_at_stop("walk-transfer-b", vehicle_b, 1)
	line_c = restored_store.transit_network["lines"]["walk-transfer-c"]
	_expect(is_equal_approx(float(line_c.get("queue_passengers", 0.0)), 0.0), "the third-line queue waits for its own transfer walk")
	restored_store._generate_resident_transport_demand(5.9)
	line_c = restored_store.transit_network["lines"]["walk-transfer-c"]
	_expect(is_equal_approx(float(line_c.get("queue_passengers", 0.0)), 0.0), "the third line stays empty until its six-minute walk completes")
	restored_store._generate_resident_transport_demand(0.2)
	line_c = restored_store.transit_network["lines"]["walk-transfer-c"]
	var fare_weights_c: Array = line_c.get("waiting_fare_weights_by_stop", [])
	_expect(is_equal_approx(float(line_c.get("queue_passengers", 0.0)), 40.0), "the final transfer joins the third line only after walking")
	_expect(is_equal_approx(float(fare_weights_c[0][1]), 28.0), "the age-based fare weight survives a second walking transfer")
	restored_store.free()
	transfer_store.free()


func _test_old_custom_save_queues_remain_full_fare() -> void:
	var legacy_store = GameStoreScript.new()
	legacy_store.suppress_persistence = true
	legacy_store.reset_state(false)
	_install_transfer_test_lines(legacy_store, [
		{"id": "legacy-line", "stops": ["old0", "old1"], "points": [Vector2(100.0, 100.0), Vector2(400.0, 100.0)]},
	])
	var network_lines: Dictionary = legacy_store.transit_network.get("lines", {})
	var line: Dictionary = network_lines["legacy-line"]
	line.erase("waiting_fare_weights_by_stop")
	line["waiting_by_stop"] = [[0.0, 3.0], [0.0, 0.0]]
	line["vehicles"] = [{
		"current_stop_index": 0,
		"next_stop_index": 1,
		"onboard_by_destination": [0.0, 5.0],
		"onboard_passengers": 5.0,
	}]
	line.erase("resident_transfer_groups_by_stop")
	network_lines["legacy-line"] = line
	legacy_store.transit_network["lines"] = network_lines
	legacy_store._ensure_custom_line_runtime("legacy-line")
	line = legacy_store.transit_network["lines"]["legacy-line"]
	var waiting_weights: Array = line.get("waiting_fare_weights_by_stop", [])
	var vehicle: Dictionary = line["vehicles"][0]
	var onboard_weights: Array = vehicle.get("onboard_fare_weights_by_destination", [])
	_expect(is_equal_approx(float(waiting_weights[0][1]), 3.0), "legacy queued riders default to full-fare weight")
	_expect(is_equal_approx(float(onboard_weights[1]), 5.0), "legacy onboard riders default to full-fare weight")
	var legacy_payload: Dictionary = legacy_store._current_save_payload()
	var legacy_network: Dictionary = legacy_payload.get("transit_network", {})
	legacy_network.erase("pending_resident_transfers")
	legacy_payload["transit_network"] = legacy_network
	legacy_store._apply_payload(legacy_payload)
	_expect(
		legacy_store.transit_network.get("pending_resident_transfers", []) == [],
		"older saves without a pending-transfer field load with an empty walking queue"
	)
	legacy_store.free()


func _install_transfer_test_lines(store, line_specs: Array) -> void:
	var stops: Dictionary = {}
	var lines: Dictionary = {}
	for spec_value in line_specs:
		var spec: Dictionary = spec_value
		var line_id := str(spec["id"])
		var stop_ids: Array = spec["stops"]
		var points: Array = spec["points"]
		for stop_index in range(stop_ids.size()):
			var stop_id := str(stop_ids[stop_index])
			stops[stop_id] = _stop(stop_id, points[stop_index], line_id)
		var length := (points[0] as Vector2).distance_to(points[1] as Vector2)
		lines[line_id] = {
			"id": line_id,
			"name": line_id,
			"source": "custom",
			"status": "active",
			"mode": "bus",
			"stop_ids": stop_ids.duplicate(),
			"route_segments": [{"length_world": length}],
			"route_length_world": length,
			"fleet_count": 1,
			"vehicles": [],
			"next_vehicle_id": 1,
			"waiting_by_stop": store._create_waiting_matrix(stop_ids.size()),
		}
	store.transit_network = {
		"schema_version": 2,
		"source": "free_lines",
		"next_stop_serial": 1,
		"next_line_serial": 1,
		"stops": stops,
		"lines": lines,
		"pending_resident_transfers": [],
	}
	for line_id_value in lines.keys():
		store._ensure_custom_line_runtime(str(line_id_value))
	store._resident_transport_snapshot_cache.clear()


func _cache_transfer_flow(store, trips: float, age_group: String, route_legs: Array) -> void:
	var od_id := "resident-transfer-test"
	var age_key := "%s|%s" % [od_id, age_group]
	store._resident_transport_snapshot_cache = {
		"signature": store._resident_transport_signature(),
		"metrics": {},
		"choice": {"flows": [{
			"od_id": od_id,
			"age_group": age_group,
			"flows": {"transit": trips},
		}]},
		"routes_by_od": {},
		"routes_by_od_age": {
			age_key: {"reachable": true, "legs": route_legs.duplicate(true)},
		},
	}


func _set_empty_transfer_test_snapshot(store) -> void:
	store._resident_transport_snapshot_cache = {
		"signature": store._resident_transport_signature(),
		"metrics": {},
		"choice": {"flows": []},
		"routes_by_od": {},
		"routes_by_od_age": {},
	}


func _test_sandbox_line_price_includes_its_starter_bus(store) -> void:
	var points := _first_built_road_segment(store.city)
	_expect(points.size() == 2, "starter region has a built road for route pricing")
	if points.size() != 2:
		return
	var route_length := float(store._draft_route_length(points))
	var route_cost := route_length * float(Data.ECONOMY["sandbox_route_cost_per_world_unit"])
	var base_without_bus := (
		float(Data.ECONOMY["sandbox_line_base_cost"])
		+ float(points.size()) * float(Data.ECONOMY["sandbox_stop_cost"])
		+ route_cost
	)
	var expected := roundi(base_without_bus + float(store.vehicle_purchase_cost()))
	_expect(
		store.free_line_build_cost(points) == expected,
		"sandbox build cost includes the bus auto-created with a new line"
	)
	store.world_map = MapDefinition.create(MapDefinition.LEGACY_CITY_MAP_ID, store.city_seed)
	var legacy_expected := roundi(
		float(Data.ECONOMY["free_line_base_cost"])
		+ float(points.size()) * float(Data.ECONOMY["free_stop_cost"])
		+ route_length * float(Data.ECONOMY["free_route_cost_per_world_unit"])
	)
	_expect(store.free_line_build_cost(points) == legacy_expected, "legacy line build pricing remains unchanged")
	store.world_map = MapDefinition.create(MapDefinition.DEFAULT_MAP_ID, store.city_seed)


func _first_built_road_segment(city: Dictionary) -> Array[Vector2]:
	var roads_by_id: Dictionary = {}
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		roads_by_id[str(road.get("id", ""))] = road
	var nodes_by_id: Dictionary = {}
	for node_value in city.get("nodes", []):
		var node: Dictionary = node_value
		nodes_by_id[str(node.get("id", ""))] = Vector2(
			float(node.get("x", 0.0)),
			float(node.get("y", 0.0))
		)
	for edge_value in city.get("graph_edges", []):
		var edge: Dictionary = edge_value
		var road: Dictionary = roads_by_id.get(str(edge.get("roadId", "")), {})
		if str(road.get("status", "")) != "built":
			continue
		var a_id := str(edge.get("a", ""))
		var b_id := str(edge.get("b", ""))
		if nodes_by_id.has(a_id) and nodes_by_id.has(b_id):
			var points: Array[Vector2] = [nodes_by_id[a_id], nodes_by_id[b_id]]
			if points[0].distance_to(points[1]) >= 120.0:
				return points
	return []


func _farthest_settlement_pair(settlements: Array) -> Array[Dictionary]:
	var best: Array[Dictionary] = []
	var best_distance := -1.0
	for first_index in range(settlements.size()):
		var first: Dictionary = settlements[first_index]
		for second_index in range(first_index + 1, settlements.size()):
			var second: Dictionary = settlements[second_index]
			var distance := _position(first.get("position", Vector2.ZERO)).distance_to(
				_position(second.get("position", Vector2.ZERO))
			)
			if distance > best_distance:
				best_distance = distance
				best = [first, second]
	return best


func _position(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if typeof(value) == TYPE_DICTIONARY:
		var point: Dictionary = value
		return Vector2(float(point.get("x", 0.0)), float(point.get("y", 0.0)))
	return Vector2.ZERO


func _stop(stop_id: String, point: Vector2, line_id: String) -> Dictionary:
	return {
		"id": stop_id,
		"status": "built",
		"source": "custom",
		"x": point.x,
		"y": point.y,
		"level": 0,
		"served_line_ids": [line_id],
	}


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	failures += 1
	push_error("Resident transport GameStore: %s" % description)
