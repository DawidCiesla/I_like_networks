extends SceneTree

const ResidentHealth = preload("res://scripts/simulation/resident_health.gd")

var failures := 0


func _initialize() -> void:
	_test_healthcare_coverage_improves_outcomes()
	_test_strain_commute_and_exposure_reduce_health()
	_test_districts_remain_isolated()
	_test_regional_city_shape()
	_test_age_cohorts_are_reported()
	_test_age_specific_commute_reaches_health_cohorts()
	_test_longitudinal_outcomes_respond_to_city_conditions()
	_test_longitudinal_state_is_deterministic_and_migration_safe()
	_test_disease_burden_and_population_feedback()
	_test_age_transitions_and_births_preserve_step_stock_flows()
	_test_population_stock_survives_repeated_steps_and_external_changes()
	_test_reproducibility_and_input_immutability()
	_test_zero_population_and_bounds()
	if failures == 0:
		print("ResidentHealth tests: PASS")
		quit(0)
	else:
		push_error("ResidentHealth tests: %d failure(s)" % failures)
		quit(1)


func _test_healthcare_coverage_improves_outcomes() -> void:
	var poor: Dictionary = ResidentHealth.evaluate(_city_input(0.25))
	var full: Dictionary = ResidentHealth.evaluate(_city_input(1.0))
	_expect(float(full["health_index"]) > float(poor["health_index"]), "better healthcare coverage improves the health index")
	_expect(float(full["preventable_burden"]) < float(poor["preventable_burden"]), "better coverage lowers preventable burden")
	_expect(is_equal_approx(float(full["healthcare_coverage"]), 1.0), "served capacity is reported as full healthcare coverage")
	_expect(is_equal_approx(float(poor["healthcare_coverage"]), 0.25), "served capacity is reported as partial healthcare coverage")


func _test_strain_commute_and_exposure_reduce_health() -> void:
	var baseline: Dictionary = ResidentHealth.evaluate(_city_input(1.0))
	var strained_input := _city_input(0.2)
	strained_input["transport_metrics"] = {"average_commute_minutes": 100.0, "average_wellbeing": 40.0}
	strained_input["pollution_exposure"] = 0.8
	var strained: Dictionary = ResidentHealth.evaluate(strained_input)
	_expect(float(strained["health_index"]) < float(baseline["health_index"]), "healthcare strain, long commutes, pollution, and low wellbeing reduce health")
	_expect(float(strained["healthcare_penalty"]) > float(baseline["healthcare_penalty"]), "healthcare capacity strain is visible in its penalty")
	_expect(float(strained["commute_penalty"]) > 0.0, "long commutes produce a nonzero penalty")
	_expect(float(strained["exposure_penalty"]) > 0.0, "pollution exposure produces a nonzero penalty")
	_expect(float(strained["wellbeing_effect"]) < 0.0, "low wellbeing produces a negative adjustment")


func _test_districts_remain_isolated() -> void:
	var input := {
		"settlements": [
			{"id": "east", "population": 80},
			{"id": "west", "population": 20},
		],
		"service_results": _service_results({"east": 1.0, "west": 0.1}),
		"transport_metrics": {
			"districts": {
				"east": {"average_commute_minutes": 15.0, "average_wellbeing": 80.0},
				"west": {"average_commute_minutes": 90.0, "average_wellbeing": 40.0},
			},
		},
		"exposure_by_settlement": {"east": 0.1, "west": 0.9},
	}
	var result: Dictionary = ResidentHealth.evaluate(input)
	var east: Dictionary = result["districts"]["east"]
	var west: Dictionary = result["districts"]["west"]
	_expect(float(east["health_index"]) > float(west["health_index"]), "well-served low-exposure district scores above isolated district")
	_expect(float(east["healthcare_coverage"]) == 1.0 and float(west["healthcare_coverage"]) == 0.1, "healthcare coverage is kept at district level")
	_expect(float(result["health_index"]) > float(west["health_index"]), "city score aggregates district populations")
	var west_before := float(west["health_index"])
	var changed := input.duplicate(true)
	changed["service_results"] = _service_results({"east": 0.0, "west": 0.1})
	var changed_result: Dictionary = ResidentHealth.evaluate(changed)
	_expect(is_equal_approx(float(changed_result["districts"]["west"]["health_index"]), west_before), "changing one district does not leak into another district")


func _test_age_cohorts_are_reported() -> void:
	var input := _city_input(0.4)
	input["population_cohorts"] = [
		{"id": "children", "age_group": "children", "share": 0.2},
		{"id": "adults", "age_group": "adults", "share": 0.5},
		{"id": "seniors", "age_group": "seniors", "share": 0.3},
	]
	var result: Dictionary = ResidentHealth.evaluate(input)
	var city_cohorts: Dictionary = result["cohorts"]
	_expect(city_cohorts.has("children") and city_cohorts.has("adults") and city_cohorts.has("seniors"), "city result exposes cohort metrics")
	_expect(float(city_cohorts["seniors"]["health_index"]) < float(city_cohorts["adults"]["health_index"]), "higher age-related vulnerability raises burden under care strain")
	_expect(is_equal_approx(float(city_cohorts["seniors"]["population"]), 30.0), "cohort shares reconcile to aggregate residents")
	var scoped := input.duplicate(true)
	scoped["population_cohorts"] = [
		{"id": "older", "district_id": "origin", "age_group": "seniors", "share": 1.0},
	]
	var scoped_result: Dictionary = ResidentHealth.evaluate(scoped)
	_expect(is_equal_approx(float(scoped_result["districts"]["origin"]["cohorts"]["older"]["population"]), 100.0), "district-scoped cohort shares reconcile to district residents")


func _test_age_specific_commute_reaches_health_cohorts() -> void:
	var input := {
		"settlements": [{"id": "origin", "population": 100}],
		"service_results": _service_results({"origin": 0.8}),
		"population_cohorts": [
			{"id": "children", "age_group": "children", "share": 0.5},
			{"id": "adults", "age_group": "adults", "share": 0.5},
		],
		"transport_metrics": {
			"districts": {
				"origin": {
					"average_commute_minutes": 30.0,
					"average_wellbeing": 70.0,
					"age_groups": {
						"children": {"average_commute_minutes": 95.0, "average_wellbeing": 35.0},
						"adults": {"average_commute_minutes": 15.0, "average_wellbeing": 80.0},
					},
				},
			},
		},
	}
	var result: Dictionary = ResidentHealth.evaluate(input)
	var district_cohorts: Dictionary = result["districts"]["origin"]["cohorts"]
	_expect(
		float(district_cohorts["children"]["average_commute_minutes"])
		> float(district_cohorts["adults"]["average_commute_minutes"]),
		"age-specific transport burden feeds the matching health cohort"
	)
	_expect(
		float(district_cohorts["children"]["average_wellbeing"])
		< float(district_cohorts["adults"]["average_wellbeing"]),
		"each age cohort receives its own transport wellbeing"
	)


func _test_longitudinal_outcomes_respond_to_city_conditions() -> void:
	var seed_input := _longitudinal_input(1.0, 15.0, 0.5, 70.0)
	var seeded: Dictionary = ResidentHealth.advance({}, seed_input, 0.0)
	var initial_state: Dictionary = seeded["state"]
	var calm_input := _longitudinal_input(1.0, 15.0, 0.0, 70.0)
	var calm: Dictionary = ResidentHealth.advance(initial_state, calm_input, 1.0)["metrics"]
	var weak_care: Dictionary = ResidentHealth.advance(initial_state, _longitudinal_input(0.25, 15.0, 0.0, 70.0), 1.0)["metrics"]
	var long_commute: Dictionary = ResidentHealth.advance(initial_state, _longitudinal_input(1.0, 100.0, 0.0, 70.0), 1.0)["metrics"]
	var dirty_air: Dictionary = ResidentHealth.advance(initial_state, _longitudinal_input(1.0, 15.0, 0.8, 70.0), 1.0)["metrics"]
	var low_wellbeing: Dictionary = ResidentHealth.advance(initial_state, _longitudinal_input(1.0, 15.0, 0.0, 40.0), 1.0)["metrics"]
	_expect(float(calm["health_index"]) > float(weak_care["health_index"]), "limited healthcare capacity worsens the longitudinal outcome")
	_expect(float(calm["health_index"]) > float(long_commute["health_index"]), "long commutes worsen the longitudinal outcome")
	_expect(float(calm["health_index"]) > float(dirty_air["health_index"]), "pollution worsens the longitudinal outcome")
	_expect(float(calm["health_index"]) > float(low_wellbeing["health_index"]), "low wellbeing worsens the longitudinal outcome")
	var child_trend := float(weak_care["cohorts"]["children"]["annual_health_trend"])
	var adult_trend := float(weak_care["cohorts"]["adults"]["annual_health_trend"])
	var senior_trend := float(weak_care["cohorts"]["seniors"]["annual_health_trend"])
	_expect(child_trend > adult_trend and adult_trend > senior_trend, "age vulnerability changes the rate of longitudinal health decline")
	_expect(float(weak_care["population"]) > 0.0, "health dynamics keep population nonnegative")
	_expect(float(weak_care["deaths"]) > 0.0 and float(weak_care["births"]) > 0.0, "aggregate health simulation records mortality and births")
	_expect(
		float(weak_care["cohorts"]["children"]["annual_mortality_rate"])
		< float(weak_care["cohorts"]["adults"]["annual_mortality_rate"])
		and float(weak_care["cohorts"]["adults"]["annual_mortality_rate"])
		< float(weak_care["cohorts"]["seniors"]["annual_mortality_rate"]),
		"expected mortality risk rises across children, adults, and seniors"
	)
	_expect(float(weak_care["health_index"]) >= 0.0 and float(weak_care["health_index"]) <= 100.0, "longitudinal health stays bounded")
	_expect(weak_care.has("health_simulation_years") and is_equal_approx(float(weak_care["health_simulation_years"]), 1.0), "simulation time is exposed in returned metrics")


func _test_longitudinal_state_is_deterministic_and_migration_safe() -> void:
	var seed_input := _longitudinal_input(1.0, 15.0, 0.5, 70.0)
	var initial_state: Dictionary = ResidentHealth.advance({}, seed_input, 0.0)["state"]
	var strained_input := _longitudinal_input(0.4, 55.0, 0.35, 55.0)
	var original_state := initial_state.duplicate(true)
	var original_input := strained_input.duplicate(true)
	var first: Dictionary = ResidentHealth.advance(initial_state, strained_input, 0.5)
	var second: Dictionary = ResidentHealth.advance(initial_state, strained_input, 0.5)
	_expect(first == second, "same state and inputs produce identical cohort outcomes")
	_expect(initial_state == original_state and strained_input == original_input, "advance leaves state and input dictionaries unchanged")
	var quarter: Dictionary = ResidentHealth.advance(initial_state, strained_input, 0.25)
	var split: Dictionary = ResidentHealth.advance(quarter["state"], strained_input, 0.25)
	var continuous_health := float(first["metrics"]["health_index"])
	var split_health := float(split["metrics"]["health_index"])
	_expect(absf(continuous_health - split_health) < 0.1, "fractional steps compose closely under unchanged conditions")
	var unsupported_state := {
		"schema_version": 99,
		"elapsed_years": 500.0,
		"districts": {"origin": {"cohorts": {"adults": {"health_index": 0.0}}}},
	}
	var migrated: Dictionary = ResidentHealth.advance(unsupported_state, strained_input, 0.25)
	_expect(is_equal_approx(float(migrated["state"]["elapsed_years"]), 0.25), "unsupported saved-state versions safely reseed their simulation clock")
	_expect(float(migrated["metrics"]["health_index"]) > 0.0, "unsupported saved state does not inject invalid health outcomes")
	var long_run: Dictionary = ResidentHealth.advance(initial_state, strained_input, 1000000000.0)
	_expect(is_equal_approx(float(long_run["state"]["elapsed_years"]), 1000.0), "extreme durations are capped for bounded deterministic advancement")
	_expect(float(long_run["metrics"]["population"]) >= 0.0, "long runs keep aggregate population nonnegative")
	_expect(float(long_run["metrics"]["health_index"]) >= 0.0, "long runs clamp health outcomes while simulating demographic change")
	_expect(int(long_run["state"]["schema_version"]) == ResidentHealth.HEALTH_STATE_SCHEMA_VERSION, "current state writes the supported disease model schema")
	var v1_state := initial_state.duplicate(true)
	v1_state["schema_version"] = 1
	var migrated_v1: Dictionary = ResidentHealth.advance(v1_state, seed_input, 0.0)
	_expect(is_equal_approx(float(migrated_v1["state"]["elapsed_years"]), float(v1_state["elapsed_years"])), "version 1 health saves migrate without resetting elapsed simulation")
	_expect(float(migrated_v1["metrics"]["acute_cases"]) == 0.0, "version 1 saves seed new morbidity fields deterministically")


func _test_disease_burden_and_population_feedback() -> void:
	var base := _longitudinal_input(0.1, 90.0, 0.9, 45.0)
	base["settlements"] = [{"id": "origin", "population": 1000.0}]
	var seeded: Dictionary = ResidentHealth.advance({}, base, 0.0)
	var poor: Dictionary = ResidentHealth.advance(seeded["state"], base, 1.0)
	var better_input := base.duplicate(true)
	better_input["service_results"] = _service_results({"origin": 1.0})
	better_input["transport_metrics"] = {"average_commute_minutes": 15.0, "average_wellbeing": 80.0}
	better_input["environment"] = {"pollution_exposure": 0.0}
	var better: Dictionary = ResidentHealth.advance(seeded["state"], better_input, 1.0)
	_expect(float(poor["metrics"]["acute_cases"]) > 0.0 and float(poor["metrics"]["chronic_cases"]) > 0.0, "health simulation exposes acute and chronic case burdens")
	_expect(float(better["metrics"]["acute_prevalence"]) < float(poor["metrics"]["acute_prevalence"]), "care and cleaner, shorter commutes reduce acute prevalence")
	_expect(float(better["metrics"]["deaths"]) < float(poor["metrics"]["deaths"]), "care and healthier conditions reduce expected deaths")
	_expect(float(poor["metrics"]["treated_cases"]) < float(better["metrics"]["treated_cases"]), "higher care capacity treats more cases")
	var children_before := float(seeded["metrics"]["cohorts"]["children"]["population"])
	var seniors_before := float(seeded["metrics"]["cohorts"]["seniors"]["population"])
	_expect(float(poor["metrics"]["cohorts"]["children"]["population"]) < children_before, "children age into adult cohorts over time")
	_expect(float(poor["metrics"]["cohorts"]["seniors"]["population"]) > seniors_before, "adults age into senior cohorts over time")
	_expect(float(poor["metrics"]["population"]) > 0.0, "births and deaths produce a bounded population stock")
	var grown_input := base.duplicate(true)
	grown_input["settlements"] = [{"id": "origin", "population": float(seeded["metrics"]["population"]) + 12.0}]
	var reconciled: Dictionary = ResidentHealth.advance(seeded["state"], grown_input, 0.0)
	_expect(is_equal_approx(float(reconciled["metrics"]["population"]), float(seeded["metrics"]["population"]) + 12.0), "external city growth is reconciled into saved cohorts once")
	var unchanged: Dictionary = ResidentHealth.advance(reconciled["state"], grown_input, 0.0)
	_expect(is_equal_approx(float(unchanged["metrics"]["population"]), float(reconciled["metrics"]["population"])), "the same external city population is not applied twice")
	var reduced_input := grown_input.duplicate(true)
	reduced_input["settlements"] = [{"id": "origin", "population": float(reconciled["metrics"]["population"]) - 7.0}]
	var reduced: Dictionary = ResidentHealth.advance(reconciled["state"], reduced_input, 0.0)
	_expect(is_equal_approx(float(reduced["metrics"]["population"]), float(reconciled["metrics"]["population"]) - 7.0), "external population losses are reconciled across saved cohorts")
	var low_care_input := _longitudinal_input(0.1, 35.0, 0.3, 70.0)
	var full_care_input := _longitudinal_input(1.0, 35.0, 0.3, 70.0)
	var care_seed: Dictionary = ResidentHealth.advance({}, low_care_input, 0.0)
	var low_care: Dictionary = ResidentHealth.advance(care_seed["state"], low_care_input, 1.0)
	var full_care: Dictionary = ResidentHealth.advance(care_seed["state"], full_care_input, 1.0)
	_expect(float(full_care["metrics"]["treated_cases"]) > float(low_care["metrics"]["treated_cases"]), "more healthcare capacity reaches more modeled cases")


func _test_age_transitions_and_births_preserve_step_stock_flows() -> void:
	var child_input := _longitudinal_input(1.0, 15.0, 0.0, 70.0)
	child_input["population_cohorts"] = [
		{"id": "children", "age_group": "children", "share": 1.0},
		{"id": "adults", "age_group": "adults", "share": 0.0},
		{"id": "seniors", "age_group": "seniors", "share": 0.0},
	]
	var child_seed: Dictionary = ResidentHealth.advance({}, child_input, 0.0)
	var aged_children: Dictionary = ResidentHealth.advance(child_seed["state"], child_input, 18.0)["metrics"]
	var age_cohorts: Dictionary = aged_children["cohorts"]
	var post_death_population := 100.0 - float(aged_children["deaths"])
	_expect(
		absf(float(age_cohorts["children"]["population"]) / post_death_population - 0.367879) < 0.002
		and absf(float(age_cohorts["adults"]["population"]) / post_death_population - 0.51299) < 0.002
		and absf(float(age_cohorts["seniors"]["population"]) / post_death_population - 0.11913) < 0.002,
		"children cross age bands with end-of-step probabilities without being aged twice"
	)

	var adult_input := _longitudinal_input(1.0, 15.0, 0.0, 70.0)
	adult_input["population_cohorts"] = [
		{"id": "children", "age_group": "children", "share": 0.0},
		{"id": "adults", "age_group": "adults", "share": 1.0},
		{"id": "seniors", "age_group": "seniors", "share": 0.0},
	]
	var adult_seed: Dictionary = ResidentHealth.advance({}, adult_input, 0.0)
	var after_births: Dictionary = ResidentHealth.advance(adult_seed["state"], adult_input, 1.0)["metrics"]
	var adult_cohorts: Dictionary = after_births["cohorts"]
	_expect(
		is_equal_approx(float(adult_cohorts["children"]["population"]), float(after_births["births"])),
		"newborn population enters the child stock after the step's age transitions"
	)
	_expect(
		is_equal_approx(float(after_births["population"]), 100.0 - float(after_births["deaths"]) + float(after_births["births"])),
		"ageing preserves population while births and deaths change the total exactly once"
	)


func _test_population_stock_survives_repeated_steps_and_external_changes() -> void:
	var input := _longitudinal_input(0.0, 90.0, 0.9, 20.0)
	input["settlements"] = [{"id": "origin", "population": 100.0}]
	input["population_cohorts"] = [
		{"id": "children", "age_group": "children", "share": 0.0},
		{"id": "adults", "age_group": "adults", "share": 0.0},
		{"id": "seniors", "age_group": "seniors", "share": 1.0},
	]
	var seeded: Dictionary = ResidentHealth.advance({}, input, 0.0)
	var state: Dictionary = seeded["state"]
	var initial_population := float(seeded["metrics"]["population"])
	var total_deaths := 0.0
	for _step in range(20):
		var advanced: Dictionary = ResidentHealth.advance(state, input, 0.1)
		state = advanced["state"]
		var district: Dictionary = advanced["metrics"]["districts"]["origin"]
		total_deaths += float(district.get("deaths", 0.0))
		var cohort_stock := _cohort_population(state["districts"]["origin"]["cohorts"])
		_expect(is_equal_approx(cohort_stock, float(advanced["metrics"]["population"])), "ageing and mortality preserve exact city/cohort population totals")
		for cohort_value in state["districts"]["origin"]["cohorts"].values():
			var cohort: Dictionary = cohort_value
			var population := float(cohort.get("population", 0.0))
			_expect(population >= 0.0, "cohort population never becomes negative")
			_expect(float(cohort.get("acute_cases", 0.0)) <= population + 0.000001, "acute case stock never exceeds its cohort population")
			_expect(float(cohort.get("chronic_cases", 0.0)) <= population + 0.000001, "chronic case stock never exceeds its cohort population")
	_expect(total_deaths > 0.0, "unhealthy senior cohorts record deaths across repeated steps")
	var simulated_population := _cohort_population(state["districts"]["origin"]["cohorts"])
	_expect(simulated_population < initial_population - 1.0, "unchanged external population does not erase cumulative demographic losses")
	_expect(is_equal_approx(float(state["districts"]["origin"]["observed_population"]), 100.0), "the state keeps the last raw city population separate from its simulated stock")

	var grown_input := input.duplicate(true)
	grown_input["settlements"] = [{"id": "origin", "population": 125.0}]
	var grown: Dictionary = ResidentHealth.advance(state, grown_input, 0.0)
	var grown_population := float(grown["metrics"]["population"])
	_expect(is_equal_approx(grown_population, simulated_population + 25.0), "external city growth is added on top of saved health-adjusted population once")
	_expect(is_equal_approx(float(grown["state"]["districts"]["origin"]["observed_population"]), 125.0), "external growth updates the raw observation baseline")
	var repeated: Dictionary = ResidentHealth.advance(grown["state"], grown_input, 0.0)
	_expect(is_equal_approx(float(repeated["metrics"]["population"]), grown_population), "the same external city growth is not counted twice")
	var reduced_input := grown_input.duplicate(true)
	reduced_input["settlements"] = [{"id": "origin", "population": 123.0}]
	var reduced: Dictionary = ResidentHealth.advance(repeated["state"], reduced_input, 0.0)
	_expect(is_equal_approx(float(reduced["metrics"]["population"]), grown_population - 2.0), "external population reductions reconcile once without resetting simulated stock")

	var migrated_state := state.duplicate(true)
	migrated_state["schema_version"] = 2
	var migrated: Dictionary = ResidentHealth.advance(migrated_state, input, 0.0)
	_expect(is_equal_approx(float(migrated["metrics"]["population"]), simulated_population), "schema 2 migration preserves the saved health-adjusted population")
	_expect(int(migrated["state"]["schema_version"]) == ResidentHealth.HEALTH_STATE_SCHEMA_VERSION, "migration writes the current population-observation schema")

	var negative_inputs := _longitudinal_input(-1.0, -900.0, -4.0, -300.0)
	negative_inputs["settlements"] = [{"id": "origin", "population": 40.0}]
	negative_inputs["service_results"] = {
		"services": {
			"districts": {
				"origin": {"services": {"healthcare": {"coverage": -5.0, "served": -100.0, "demand": -20.0}}},
			},
		},
	}
	var bounded: Dictionary = ResidentHealth.advance({}, negative_inputs, 1000000.0)
	var bounded_metrics: Dictionary = bounded["metrics"]
	_expect(float(bounded_metrics["population"]) >= 0.0, "invalid negative care and environment inputs keep the population nonnegative")
	_expect(float(bounded_metrics["health_index"]) >= 0.0 and float(bounded_metrics["health_index"]) <= 100.0, "negative care and exposure inputs keep health bounded")
	_expect(float(bounded_metrics["acute_cases"]) >= 0.0 and float(bounded_metrics["chronic_cases"]) >= 0.0, "invalid inputs do not create negative disease stocks")
	_expect(float(bounded_metrics["treated_cases"]) >= 0.0 and float(bounded_metrics["deaths"]) >= 0.0 and float(bounded_metrics["births"]) >= 0.0, "treatment, mortality, and birth flows remain nonnegative")


func _cohort_population(cohorts: Dictionary) -> float:
	var total := 0.0
	for cohort_value in cohorts.values():
		total += maxf(0.0, float((cohort_value as Dictionary).get("population", 0.0)))
	return total


func _test_regional_city_shape() -> void:
	var city := {
		"demographics": {"residents": 100},
		"regional_settlements": [
			{"id": "north", "population": 75},
			{"id": "south", "population": 25},
		],
		"service_results": _service_results({"north": 0.8, "south": 0.4}),
	}
	var result: Dictionary = ResidentHealth.evaluate({"city": city})
	_expect(is_equal_approx(float(result["population"]), 100.0), "regional demographics accept aggregate settlement records")
	_expect(result["districts"].has("north") and result["districts"].has("south"), "regional settlement IDs key district health metrics")
	_expect(float(result["districts"]["north"]["healthcare_coverage"]) > float(result["districts"]["south"]["healthcare_coverage"]), "regional CityServices results join by settlement ID")


func _test_reproducibility_and_input_immutability() -> void:
	var input := _city_input(0.65)
	input["exposure_by_settlement"] = {"origin": {"pollution_index": 35.0}}
	var original := input.duplicate(true)
	var first: Dictionary = ResidentHealth.evaluate(input)
	var second: Dictionary = ResidentHealth.evaluate(input)
	_expect(first == second, "identical inputs produce identical city, district, and cohort outputs")
	_expect(input == original, "evaluation leaves all supplied dictionaries unchanged")


func _test_zero_population_and_bounds() -> void:
	var zero: Dictionary = ResidentHealth.evaluate({
		"settlements": [{"id": "empty", "population": 0}],
		"transport_metrics": {"average_commute_minutes": 10000000.0, "average_wellbeing": -400.0},
		"exposure_by_settlement": {"empty": 1.0},
		"service_results": _service_results({"empty": 0.0}),
	})
	_expect(float(zero["population"]) == 0.0, "zero population stays zero")
	_expect(float(zero["health_index"]) == 100.0, "empty population has a neutral index")
	_expect(float(zero["preventable_burden"]) == 0.0, "empty population has no modeled burden")
	var empty: Dictionary = ResidentHealth.evaluate({})
	_expect(float(empty["population"]) == 0.0 and float(empty["health_index"]) == 100.0, "missing city data returns stable empty metrics")
	var mapped: Dictionary = ResidentHealth.evaluate({
		"districts": {"mapped": {"population": 10, "healthcare_coverage": 1.0}},
	})
	_expect(is_equal_approx(float(mapped["population"]), 10.0) and mapped["districts"].has("mapped"), "dictionary-keyed district aggregates are accepted")
	var extreme: Dictionary = ResidentHealth.evaluate({
		"demographics": {"residents": -10},
		"transport_metrics": {"average_commute_minutes": 1.0e30, "average_wellbeing": 1.0e30},
		"pollution_exposure": 100000.0,
	})
	_expect(float(extreme["health_index"]) >= 0.0 and float(extreme["health_index"]) <= 100.0, "health index remains bounded for extreme inputs")
	_expect(float(extreme["preventable_burden"]) >= 0.0 and float(extreme["preventable_burden"]) <= 100.0, "preventable burden remains bounded")
	_expect(float(extreme["population"]) == 0.0, "negative population is clamped to zero")


func _city_input(coverage: float) -> Dictionary:
	return {
		"settlements": [{"id": "origin", "population": 100}],
		"service_results": _service_results({"origin": coverage}),
		"transport_metrics": {"average_commute_minutes": 15.0, "average_wellbeing": 70.0},
	}


func _longitudinal_input(coverage: float, commute: float, pollution: float, wellbeing: float) -> Dictionary:
	var input := _city_input(coverage)
	input["transport_metrics"] = {
		"average_commute_minutes": commute,
		"average_wellbeing": wellbeing,
	}
	input["environment"] = {"pollution_exposure": pollution}
	return input


func _service_results(coverage_by_id: Dictionary) -> Dictionary:
	var service_districts: Dictionary = {}
	var total_demand := 0.0
	var total_served := 0.0
	for district_id in coverage_by_id:
		var demand := 100.0
		var served := demand * clampf(float(coverage_by_id[district_id]), 0.0, 1.0)
		total_demand += demand
		total_served += served
		service_districts[str(district_id)] = {
			"id": str(district_id),
			"services": {
				"healthcare": {
					"demand": demand,
					"served": served,
					"coverage": served / demand,
				},
			},
		}
	return {
		"services": {
			"districts": service_districts,
			"totals": {
				"services": {
					"healthcare": {
						"demand": total_demand,
						"served": total_served,
						"coverage": total_served / total_demand if total_demand > 0.0 else 0.0,
					},
				},
			},
		},
	}


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	failures += 1
	push_error("FAIL: %s" % description)
