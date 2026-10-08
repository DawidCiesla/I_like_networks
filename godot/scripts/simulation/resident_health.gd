extends RefCounted
class_name ResidentHealth

## Deterministic health-planning estimates over aggregate resident cohorts.
##
## `evaluate` accepts a plain dictionary containing `settlements` (or
## `districts`), optional `service_results`, `transport_metrics`,
## `exposure_by_settlement` or aggregate `pollution_exposure`, and optional
## `population_cohorts`. Settlement records use `id` and `population`.
## CityServices results are read from `service_results.services.districts` and
## `service_results.services.totals.services.healthcare`.
##
## Cohort rows may contain `id`, `age_group`, `population`, `share`, and an
## optional `district_id`. Unscoped rows describe the age mix applied to each
## district; scoped rows describe that district directly. Age shares are
## normalized before use. Pollution exposure is a normalized 0..1 risk input
## (`pollution_index` is accepted on a 0..100 scale). Commute is in minutes and
## wellbeing is on a 0..100 scale.
##
## Output health_index and preventable_burden are transparent 0..100 planning
## indices, not diagnoses, expected deaths, or population changes. All
## calculations are bounded, aggregate, deterministic, and side-effect free.

const EPSILON := 0.000001
const MAX_AGGREGATE_VALUE := 1000000000000.0
const HEALTH_STATE_SCHEMA_VERSION := 3
const ResidentHealthDynamics = preload("res://scripts/simulation/resident_health_dynamics.gd")
const MAX_SIMULATION_STEP_YEARS := 1000.0
const DEFAULT_AGE_SHARES := {"children": 0.18, "adults": 0.64, "seniors": 0.18}
const AGE_RISK := {"children": 0.85, "adults": 1.0, "seniors": 1.65}
const REFERENCE_AGE_RISK := 0.18 * 0.85 + 0.64 + 0.18 * 1.65
const HEALTHCARE_PENALTY := 28.0
const COMMUTE_PENALTY := 10.0
const EXPOSURE_PENALTY := 22.0
const WELLBEING_REFERENCE := 70.0
const WELLBEING_SLOPE := 0.12
const WELLBEING_MIN_EFFECT := -8.0
const WELLBEING_MAX_EFFECT := 4.0
const ANNUAL_CARE_STRESS := 1.8
const ANNUAL_COMMUTE_STRESS := 1.2
const ANNUAL_POLLUTION_STRESS := 2.0
const ANNUAL_LOW_WELLBEING_STRESS := 0.8
const ANNUAL_BASE_RECOVERY := 0.5
const ANNUAL_CARE_RECOVERY := 0.9
const ANNUAL_HIGH_WELLBEING_RECOVERY := 0.7
const ACUTE_ANNUAL_INCIDENCE := 0.16
const ACUTE_BASE_RECOVERY_RATE := 8.0
const ACUTE_CARE_RECOVERY_RATE := 18.0
const CHRONIC_ANNUAL_INCIDENCE := {"children": 0.001, "adults": 0.003, "seniors": 0.010}
const CHRONIC_BASE_REMISSION_RATE := 0.006
const CHRONIC_CARE_REMISSION_RATE := 0.035
const ANNUAL_MORTALITY_RATE := {"children": 0.001, "adults": 0.004, "seniors": 0.025}
const ANNUAL_BIRTH_RATE_PER_ADULT := 0.015
const CHILD_TO_ADULT_AGE_RATE := 1.0 / 18.0
const ADULT_TO_SENIOR_AGE_RATE := 1.0 / 49.0


## Returns city-wide metrics, metrics keyed by district/settlement ID, and
## population-cohort metrics. No input dictionary is modified.
static func evaluate(input: Dictionary) -> Dictionary:
	var city_value: Variant = input.get("city", input)
	var city: Dictionary = _as_dictionary(city_value)
	var service_results := _as_dictionary(input.get("service_results", city.get("service_results", {})))
	var service_root := _as_dictionary(service_results.get("services", service_results))
	var service_districts := _as_dictionary(service_root.get("districts", {}))
	var service_totals := _as_dictionary(service_root.get("totals", {}))
	var aggregate_service_totals := _as_dictionary(service_totals.get("services", {}))
	var aggregate_healthcare := _as_dictionary(aggregate_service_totals.get("healthcare", {}))
	var transport := _as_dictionary(input.get("transport_metrics", city.get("transport_metrics", {})))
	var environment := _as_dictionary(input.get("environment", city.get("environment", {})))
	var exposure_by_settlement := _as_dictionary(input.get("exposure_by_settlement", city.get("exposure_by_settlement", {})))
	var population_cohorts: Variant = input.get(
		"population_cohorts",
		city.get("population_cohorts", input.get("age_shares", city.get("age_shares", [])))
	)
	var settlements := _as_records(input.get("settlements", city.get("regional_settlements", city.get("settlements", []))))
	var supplied_districts := _as_records(input.get("districts", city.get("districts", [])))
	var district_records := _district_records(settlements, supplied_districts, city)

	var district_metrics: Dictionary = {}
	var city_cohort_accumulators: Dictionary = {}
	var city_population := 0.0
	var weighted_totals := _empty_weighted_totals()
	var healthcare_demand := 0.0
	var healthcare_served := 0.0
	var healthcare_data_available := false

	for district_index in range(district_records.size()):
		var district: Dictionary = district_records[district_index]
		var district_id := str(district.get("id", "district-%d" % district_index)).strip_edges()
		if district_id.is_empty():
			district_id = "district-%d" % district_index
		if district_metrics.has(district_id):
			district_id = "%s-%d" % [district_id, district_index]
		var population := _non_negative_number(district.get("population", 0.0))
		var local_transport := _district_metrics_for(transport, district_id)
		var local_environment := _district_metrics_for(environment, district_id)
		var local_exposure: Variant = exposure_by_settlement.get(district_id, null)
		if typeof(local_exposure) == TYPE_DICTIONARY:
			local_environment = _merged_dictionary(local_environment, local_exposure)
		elif local_exposure != null:
			local_environment["pollution_exposure"] = local_exposure
		var care := _healthcare_metrics(
			district_id,
			district,
			service_districts,
			aggregate_healthcare,
			population
		)
		var commute_minutes := _metric_number(
			[district, local_transport, transport],
			["average_commute_minutes", "commute_minutes"],
			0.0
		)
		var pollution_exposure := _pollution_exposure([district, local_environment, environment, input])
		var wellbeing := clampf(
			_metric_number([district, local_transport, transport], ["average_wellbeing", "wellbeing"], WELLBEING_REFERENCE),
			0.0,
			100.0
		)
		var cohorts := _cohorts_for_district(population_cohorts, district_id, district, population)
		var district_cohorts: Dictionary = {}
		var district_weighted := _empty_weighted_totals()
		for cohort_value in cohorts:
			var cohort: Dictionary = cohort_value
			var cohort_id := str(cohort.get("id", "adults"))
			var cohort_population := _non_negative_number(cohort.get("population", 0.0))
			var age_group := _age_group(cohort.get("age_group", cohort_id))
			var age_transport: Dictionary = _as_dictionary(local_transport.get("age_groups", {})).get(age_group, {})
			var cohort_commute := _metric_number(
				[age_transport, district, local_transport, transport],
				["average_commute_minutes", "commute_minutes"],
				commute_minutes
			)
			var cohort_wellbeing := clampf(
				_metric_number(
					[age_transport, district, local_transport, transport],
					["average_wellbeing", "wellbeing"],
					wellbeing
				),
				0.0,
				100.0
			)
			var health := _score_cohort(
				care,
				cohort_commute,
				pollution_exposure,
				cohort_wellbeing,
				age_group,
				cohort_population
			)
			health["id"] = cohort_id
			health["age_group"] = age_group
			health["population"] = cohort_population
			district_cohorts[cohort_id] = health
			_accumulate_health(district_weighted, health, cohort_population)
			_add_cohort_metrics(city_cohort_accumulators, cohort_id, age_group, health, cohort_population)

		_accumulate_context(district_weighted, population, commute_minutes, pollution_exposure, wellbeing)
		var district_result := _metrics_from_weighted(district_weighted, population, care, commute_minutes, pollution_exposure, wellbeing)
		district_result["id"] = district_id
		district_result["cohorts"] = district_cohorts
		district_metrics[district_id] = district_result
		city_population += population
		_merge_weighted(weighted_totals, district_weighted)
		healthcare_demand += float(care["demand"])
		healthcare_served += float(care["served"])
		healthcare_data_available = healthcare_data_available or bool(care["data_available"])

	var city_population_fallback := _city_population(city)
	if district_records.is_empty():
		city_population = city_population_fallback
		var empty_care := {"coverage": 0.0, "demand": 0.0, "served": 0.0, "data_available": false}
		var aggregate_commute := _metric_number([transport, input], ["average_commute_minutes", "commute_minutes"], 0.0)
		var aggregate_exposure := _pollution_exposure([environment, input])
		var aggregate_wellbeing := clampf(
			_metric_number([transport, input], ["average_wellbeing", "wellbeing"], WELLBEING_REFERENCE),
			0.0,
			100.0
		)
		var fallback_cohorts := _cohorts_for_district(population_cohorts, "city", {}, city_population)
		for cohort_value in fallback_cohorts:
			var cohort: Dictionary = cohort_value
			var age_group := _age_group(cohort.get("age_group", cohort.get("id", "adults")))
			var health := _score_cohort(empty_care, aggregate_commute, aggregate_exposure, aggregate_wellbeing, age_group, float(cohort["population"]))
			health["id"] = str(cohort["id"])
			health["age_group"] = age_group
			health["population"] = float(cohort["population"])
			_accumulate_health(weighted_totals, health, float(cohort["population"]))
			_add_cohort_metrics(city_cohort_accumulators, str(cohort["id"]), age_group, health, float(cohort["population"]))
		_accumulate_context(weighted_totals, city_population, aggregate_commute, aggregate_exposure, aggregate_wellbeing)

	if healthcare_demand <= EPSILON and aggregate_healthcare.has("demand"):
		healthcare_demand = _non_negative_number(aggregate_healthcare.get("demand", 0.0))
		healthcare_served = minf(healthcare_demand, _non_negative_number(aggregate_healthcare.get("served", 0.0)))
	var city_care := {
		"coverage": healthcare_served / healthcare_demand if healthcare_demand > EPSILON else (float(aggregate_healthcare.get("coverage", 0.0)) if healthcare_data_available else 0.0),
		"demand": healthcare_demand,
		"served": healthcare_served,
		"data_available": healthcare_data_available,
	}
	if district_records.is_empty() and aggregate_healthcare.has("coverage"):
		city_care["coverage"] = clampf(_number(aggregate_healthcare.get("coverage", 0.0), 0.0), 0.0, 1.0)
	var result := _metrics_from_weighted(
		weighted_totals,
		city_population,
		city_care,
		_metric_number([transport, input], ["average_commute_minutes", "commute_minutes"], 0.0),
		_pollution_exposure([environment, input]),
		clampf(_metric_number([transport, input], ["average_wellbeing", "wellbeing"], WELLBEING_REFERENCE), 0.0, 100.0)
	)
	result["districts"] = district_metrics
	result["cohorts"] = _finalize_cohort_metrics(city_cohort_accumulators)
	result["population"] = city_population
	result["healthcare_demand"] = healthcare_demand
	result["healthcare_served"] = healthcare_served
	result["healthcare_unserved"] = maxf(0.0, healthcare_demand - healthcare_served)
	result["healthcare_data_available"] = healthcare_data_available or aggregate_healthcare.has("coverage")
	return result


## Advances a versioned aggregate health state by `elapsed_years`. The planning
## index is combined with aggregate acute/chronic burden, treatment, births,
## age transitions, and expected deaths. New city growth is reconciled into the
## saved age cohorts; fractional population remains in the state. Rates are
## gameplay parameters on the accelerated simulation clock, not medical data.
## Negative/non-finite durations become zero; very long steps are capped at
## 1000 years. Schema 1 health state migrates; unknown versions safely reseed.
## Neither supplied dictionary is modified.
static func advance(previous_state: Dictionary, input: Dictionary, elapsed_years: float = 1.0) -> Dictionary:
	var step_years := clampf(_number(elapsed_years, 0.0), 0.0, MAX_SIMULATION_STEP_YEARS)
	var schema_version := int(_number(previous_state.get("schema_version", 0), 0.0))
	var compatible_state := schema_version in [1, 2, HEALTH_STATE_SCHEMA_VERSION]
	var previous_districts := _as_dictionary(previous_state.get("districts", {})) if compatible_state else {}
	var prior_elapsed := _non_negative_number(previous_state.get("elapsed_years", 0.0)) if compatible_state else 0.0
	var observed_population_by_district := _observed_population_by_district(input)
	var evaluation_input := input.duplicate(true)
	if not previous_districts.is_empty():
		evaluation_input = _reconcile_saved_population(
			evaluation_input,
			previous_districts,
			schema_version >= HEALTH_STATE_SCHEMA_VERSION
		)
		evaluation_input["population_cohorts"] = ResidentHealthDynamics.saved_population_cohorts(previous_districts)
	var metrics: Dictionary = evaluate(evaluation_input)
	var next_districts: Dictionary = {}
	var cohort_totals: Dictionary = {}
	var weighted_health := 0.0
	var weighted_trend := 0.0
	var metric_population := 0.0
	var district_metrics := _as_dictionary(metrics.get("districts", {}))
	var district_ids: Array[String] = []
	for value in district_metrics.keys():
		district_ids.append(str(value))
	district_ids.sort()

	for district_id in district_ids:
		var district: Dictionary = _as_dictionary(district_metrics[district_id])
		var previous_district := _as_dictionary(previous_districts.get(district_id, {}))
		var previous_cohorts := _as_dictionary(previous_district.get("cohorts", {}))
		var district_cohorts := _as_dictionary(district.get("cohorts", {}))
		var next_cohorts: Dictionary = {}
		var district_health_sum := 0.0
		var district_trend_sum := 0.0
		var district_cohort_population := 0.0
		var cohort_ids: Array[String] = []
		for value in district_cohorts.keys():
			cohort_ids.append(str(value))
		cohort_ids.sort()
		for cohort_id in cohort_ids:
			var cohort: Dictionary = _as_dictionary(district_cohorts[cohort_id]).duplicate(true)
			var population := _non_negative_number(cohort.get("population", 0.0))
			var current_health := clampf(_number(cohort.get("health_index", 100.0), 100.0), 0.0, 100.0)
			var prior_cohort := _as_dictionary(previous_cohorts.get(cohort_id, {}))
			var prior_health := clampf(_number(prior_cohort.get("underlying_health_index", prior_cohort.get("health_index", current_health)), current_health), 0.0, 100.0)
			var prior_planning_health := clampf(
				_number(prior_cohort.get("planning_health_index", prior_health), prior_health),
				0.0,
				100.0
			)
			var annual_trend := _annual_health_trend(cohort)
			# A newly worsened planning estimate applies once when conditions change.
			# The recorded planning baseline makes unchanged conditions compose
			# identically whether time advances in one step or many smaller steps.
			var immediate_condition_change := minf(0.0, current_health - prior_planning_health)
			var simulated_health := prior_health + annual_trend * step_years + immediate_condition_change
			var health_index := clampf(minf(simulated_health, current_health), 0.0, 100.0)
			cohort["health_index"] = health_index
			cohort["preventable_burden"] = 100.0 - health_index
			cohort["annual_health_trend"] = annual_trend
			cohort["health_simulation_years"] = minf(MAX_AGGREGATE_VALUE, prior_elapsed + step_years)
			next_cohorts[cohort_id] = {
				"age_group": _age_group(cohort.get("age_group", cohort_id)),
				"population": population,
				"health_index": health_index,
				"underlying_health_index": health_index,
				"planning_health_index": current_health,
			}
			district_cohorts[cohort_id] = cohort
			var cohort_age := _age_group(cohort.get("age_group", cohort_id))
			if not cohort_totals.has(cohort_id):
				cohort_totals[cohort_id] = {"population": 0.0, "weighted_health": 0.0, "weighted_trend": 0.0, "age_group": cohort_age}
			var total: Dictionary = cohort_totals[cohort_id]
			total["population"] = float(total.get("population", 0.0)) + population
			total["weighted_health"] = float(total.get("weighted_health", 0.0)) + health_index * population
			total["weighted_trend"] = float(total.get("weighted_trend", 0.0)) + annual_trend * population
			total["age_group"] = cohort_age
			cohort_totals[cohort_id] = total
			district_health_sum += health_index * population
			district_trend_sum += annual_trend * population
			district_cohort_population += population
			weighted_health += health_index * population
			weighted_trend += annual_trend * population
			metric_population += population
		district["cohorts"] = district_cohorts
		var district_health_index := district_health_sum / district_cohort_population if district_cohort_population > EPSILON else 100.0
		district["health_index"] = clampf(district_health_index, 0.0, 100.0)
		district["preventable_burden"] = 100.0 - float(district["health_index"])
		district["annual_health_trend"] = district_trend_sum / district_cohort_population if district_cohort_population > EPSILON else 0.0
		district["health_simulation_years"] = minf(MAX_AGGREGATE_VALUE, prior_elapsed + step_years)
		district_metrics[district_id] = district
		next_districts[district_id] = {"cohorts": next_cohorts}
		next_districts[district_id]["observed_population"] = _non_negative_number(
			observed_population_by_district.get(district_id, district.get("population", 0.0))
		)

	var city_health_index := weighted_health / metric_population if metric_population > EPSILON else 100.0
	metrics["districts"] = district_metrics
	metrics["health_index"] = clampf(city_health_index, 0.0, 100.0)
	metrics["preventable_burden"] = 100.0 - float(metrics["health_index"])
	metrics["annual_health_trend"] = weighted_trend / metric_population if metric_population > EPSILON else 0.0
	metrics["health_simulation_years"] = minf(MAX_AGGREGATE_VALUE, prior_elapsed + step_years)
	var top_cohorts := _as_dictionary(metrics.get("cohorts", {}))
	for cohort_id in cohort_totals:
		var total: Dictionary = cohort_totals[cohort_id]
		var cohort_population := float(total.get("population", 0.0))
		if cohort_population <= EPSILON or not top_cohorts.has(cohort_id):
			continue
		var aggregate: Dictionary = _as_dictionary(top_cohorts[cohort_id]).duplicate(true)
		aggregate["health_index"] = clampf(float(total["weighted_health"]) / cohort_population, 0.0, 100.0)
		aggregate["preventable_burden"] = 100.0 - float(aggregate["health_index"])
		aggregate["annual_health_trend"] = float(total["weighted_trend"]) / cohort_population
		aggregate["age_group"] = str(total.get("age_group", "adults"))
		top_cohorts[cohort_id] = aggregate
	metrics["cohorts"] = top_cohorts

	var next_elapsed := minf(MAX_AGGREGATE_VALUE, prior_elapsed + step_years)
	var next_state := {
		"schema_version": HEALTH_STATE_SCHEMA_VERSION,
		"elapsed_years": next_elapsed,
		"districts": next_districts,
	}
	return ResidentHealthDynamics.advance(previous_state, {"state": next_state, "metrics": metrics}, step_years)


static func _reconcile_saved_population(
	input: Dictionary,
	previous_districts: Dictionary,
	trust_previous_observation: bool
) -> Dictionary:
	var reconciled := input.duplicate(true)
	var nested_city := _as_dictionary(reconciled.get("city", {})).duplicate(true)
	var top_level_settlements := reconciled.has("settlements")
	var settlements := _as_records(reconciled.get("settlements", nested_city.get("regional_settlements", [])))
	var updated_rows: Array = []
	var aggregate_delta := 0.0
	for row_value in settlements:
		var row: Dictionary = row_value.duplicate(true)
		var district_id := str(row.get("id", ""))
		var previous := _as_dictionary(previous_districts.get(district_id, {}))
		if not previous.is_empty():
			var saved_stock := _non_negative_number(previous.get("population", _cohort_state_population(previous)))
			var observed := _non_negative_number(previous.get("observed_population", saved_stock))
			var raw_observed := _non_negative_number(row.get("population", observed))
			# Schema 1/2 stored the health-adjusted stock as the external observation.
			# Establish a clean source baseline on migration instead of counting that
			# old simulated drift as a fresh city edit.
			var external_delta := raw_observed - observed if trust_previous_observation else 0.0
			# Ignore sub-person mirror drift. Real city changes are whole residents;
			# the health state keeps fractional expectations between those changes.
			if absf(external_delta) < 0.5:
				external_delta = 0.0
			row["population"] = maxf(0.0, saved_stock + external_delta)
			aggregate_delta += external_delta
		updated_rows.append(row)
	if not settlements.is_empty():
		if top_level_settlements:
			reconciled["settlements"] = updated_rows
		else:
			nested_city["regional_settlements"] = updated_rows
			reconciled["city"] = nested_city
	elif not nested_city.is_empty() and absf(aggregate_delta) >= 0.5:
		var demographics := _as_dictionary(nested_city.get("demographics", {})).duplicate(true)
		demographics["residents"] = maxf(0.0, _number(demographics.get("residents", 0.0), 0.0) + aggregate_delta)
		nested_city["demographics"] = demographics
		reconciled["city"] = nested_city
	return reconciled


static func _observed_population_by_district(input: Dictionary) -> Dictionary:
	var city := _as_dictionary(input.get("city", input))
	var settlements := _as_records(input.get("settlements", city.get("regional_settlements", city.get("settlements", []))))
	var districts := _as_records(input.get("districts", city.get("districts", [])))
	var rows := _district_records(settlements, districts, city)
	var result: Dictionary = {}
	for index in range(rows.size()):
		var district: Dictionary = rows[index]
		var district_id := str(district.get("id", "district-%d" % index)).strip_edges()
		if district_id.is_empty():
			district_id = "district-%d" % index
		if result.has(district_id):
			district_id = "%s-%d" % [district_id, index]
		result[district_id] = _non_negative_number(district.get("population", 0.0))
	return result


static func _cohort_state_population(district: Dictionary) -> float:
	var cohorts := _as_dictionary(district.get("cohorts", {}))
	var total := 0.0
	for cohort_value in cohorts.values():
		total += _non_negative_number(_as_dictionary(cohort_value).get("population", 0.0))
	return total


static func _annual_health_trend(cohort: Dictionary) -> float:
	var age_risk := _age_risk_multiplier(_age_group(cohort.get("age_group", "adults")))
	var care_coverage := clampf(_number(cohort.get("healthcare_coverage", 0.0), 0.0), 0.0, 1.0)
	var commute_minutes := maxf(0.0, _number(cohort.get("average_commute_minutes", 0.0), 0.0))
	var commute_pressure := clampf((commute_minutes - 20.0) / 80.0, 0.0, 1.0)
	var pollution_pressure := clampf(_number(cohort.get("pollution_exposure", 0.0), 0.0), 0.0, 1.0)
	var wellbeing := clampf(_number(cohort.get("average_wellbeing", WELLBEING_REFERENCE), WELLBEING_REFERENCE), 0.0, 100.0)
	var low_wellbeing_pressure := clampf((WELLBEING_REFERENCE - wellbeing) / WELLBEING_REFERENCE, 0.0, 1.0)
	var high_wellbeing_support := clampf((wellbeing - WELLBEING_REFERENCE) / (100.0 - WELLBEING_REFERENCE), 0.0, 1.0)
	var annual_stress := age_risk * (
		ANNUAL_CARE_STRESS * (1.0 - care_coverage)
		+ ANNUAL_COMMUTE_STRESS * commute_pressure
		+ ANNUAL_POLLUTION_STRESS * pollution_pressure
		+ ANNUAL_LOW_WELLBEING_STRESS * low_wellbeing_pressure
	)
	var annual_recovery := ANNUAL_BASE_RECOVERY + care_coverage * ANNUAL_CARE_RECOVERY + high_wellbeing_support * ANNUAL_HIGH_WELLBEING_RECOVERY
	return annual_recovery - annual_stress


static func _district_records(settlements: Array, districts: Array, city: Dictionary) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var population_rows := settlements
	if population_rows.is_empty():
		population_rows = districts
	if population_rows.is_empty():
		var city_population := _city_population(city)
		if city_population > 0.0:
			records.append({"id": "city", "population": city_population})
		return records

	var districts_by_settlement: Dictionary = {}
	for district in districts:
		var linked_id := str(district.get("settlement_id", district.get("settlementId", district.get("id", ""))))
		if not linked_id.is_empty():
			districts_by_settlement[linked_id] = district
	for row_value in population_rows:
		var row: Dictionary = row_value.duplicate(true)
		var row_id := str(row.get("id", ""))
		if districts_by_settlement.has(row_id):
			var overlay: Dictionary = districts_by_settlement[row_id]
			for key in overlay:
				if str(key) != "population" and str(key) != "id":
					row[key] = overlay[key]
		if row_id.is_empty():
			row["id"] = "district-%d" % records.size()
		records.append(row)
	var known_population := 0.0
	for record in records:
		known_population += _non_negative_number(record.get("population", 0.0))
	if known_population <= EPSILON and _city_population(city) > EPSILON:
		return [{"id": "city", "population": _city_population(city)}]
	return records


static func _healthcare_metrics(
	district_id: String,
	district: Dictionary,
	service_districts: Dictionary,
	aggregate_healthcare: Dictionary,
	population: float
) -> Dictionary:
	var local_result := _as_dictionary(service_districts.get(district_id, {}))
	var local_services := _as_dictionary(local_result.get("services", {}))
	var local_healthcare := _as_dictionary(local_services.get("healthcare", {}))
	if local_healthcare.is_empty() and district.has("healthcare"):
		local_healthcare = _as_dictionary(district.get("healthcare", {}))
	if local_healthcare.is_empty() and (district.has("healthcare_coverage") or district.has("healthcare_served") or district.has("healthcare_demand")):
		local_healthcare = {
			"coverage": district.get("healthcare_coverage", null),
			"served": district.get("healthcare_served", null),
			"demand": district.get("healthcare_demand", null),
		}
	var source := local_healthcare
	var data_available := not source.is_empty()
	if source.is_empty() and not aggregate_healthcare.is_empty():
		source = {"coverage": aggregate_healthcare.get("coverage", 0.0)}
		data_available = true
	var demand := _non_negative_number(source.get("demand", 0.0))
	var served := _non_negative_number(source.get("served", 0.0))
	var coverage := 0.0
	if demand > EPSILON:
		coverage = clampf(served / demand, 0.0, 1.0)
	elif source.has("coverage") and source.get("coverage") != null:
		coverage = clampf(_number(source.get("coverage", 0.0), 0.0), 0.0, 1.0)
	elif population <= EPSILON:
		coverage = 1.0
	return {
		"coverage": coverage,
		"demand": demand,
		"served": minf(demand, served) if demand > EPSILON else served,
		"data_available": data_available,
	}


static func _cohorts_for_district(
	population_cohorts: Variant,
	district_id: String,
	district: Dictionary,
	population: float
) -> Array[Dictionary]:
	var source: Variant = population_cohorts
	if typeof(source) == TYPE_DICTIONARY:
		var cohort_map: Dictionary = source
		if cohort_map.has(district_id):
			source = cohort_map[district_id]
		elif cohort_map.has("cohorts"):
			source = cohort_map["cohorts"]
		elif cohort_map.has("age_shares"):
			source = cohort_map["age_shares"]
		else:
			source = []
	var scoped_rows: Array[Dictionary] = []
	var global_rows: Array[Dictionary] = []
	if typeof(source) == TYPE_ARRAY:
		for value in source:
			if typeof(value) != TYPE_DICTIONARY:
				continue
			var cohort: Dictionary = value
			var scope := str(cohort.get("district_id", cohort.get("districtId", "")))
			if scope.is_empty():
				global_rows.append(cohort)
			elif scope == district_id:
				scoped_rows.append(cohort)
	elif typeof(source) == TYPE_DICTIONARY:
		global_rows = _cohort_rows_from_shares(source)

	var chosen_rows := scoped_rows if not scoped_rows.is_empty() else global_rows
	if chosen_rows.is_empty():
		var local_cohorts: Variant = district.get("population_cohorts", district.get("cohorts", null))
		if typeof(local_cohorts) == TYPE_ARRAY:
			chosen_rows = _as_records(local_cohorts)
		elif typeof(district.get("age_shares", district.get("age_composition", null))) == TYPE_DICTIONARY:
			chosen_rows = _cohort_rows_from_shares(_as_dictionary(district.get("age_shares", district.get("age_composition", {}))))
		else:
			chosen_rows = _cohort_rows_from_shares(DEFAULT_AGE_SHARES)

	var prepared: Array[Dictionary] = []
	var explicit_population_total := 0.0
	var share_total := 0.0
	var uses_explicit_population := not scoped_rows.is_empty()
	for index in range(chosen_rows.size()):
		var row: Dictionary = chosen_rows[index]
		var row_population := _non_negative_number(row.get("population", 0.0))
		var share := _non_negative_number(row.get("share", 0.0))
		if uses_explicit_population:
			explicit_population_total += row_population
		if share <= EPSILON and row.has("population"):
			share = row_population
		share_total += share
		prepared.append({
			"id": str(row.get("id", row.get("age_group", row.get("group", "cohort-%d" % index)))),
			"age_group": _age_group(row.get("age_group", row.get("group", row.get("id", "adults")))),
			"population": row_population,
			"share": share,
		})
	if uses_explicit_population and explicit_population_total > EPSILON:
		for row in prepared:
			row["population"] = population * float(row["population"]) / explicit_population_total
	else:
		if share_total <= EPSILON:
			for row in prepared:
				row["share"] = 0.0
			share_total = 0.0
		for row in prepared:
			var share := float(row["share"]) / share_total if share_total > EPSILON else 1.0 / float(maxi(1, prepared.size()))
			row["population"] = population * share
	if prepared.is_empty():
		prepared = [
			{"id": "children", "age_group": "children", "population": population * 0.18},
			{"id": "adults", "age_group": "adults", "population": population * 0.64},
			{"id": "seniors", "age_group": "seniors", "population": population * 0.18},
		]
	return prepared


static func _cohort_rows_from_shares(shares: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for key in shares.keys():
		rows.append({"id": str(key), "age_group": str(key), "share": shares[key]})
	return rows


static func _score_cohort(
	care: Dictionary,
	commute_minutes: float,
	pollution_exposure: float,
	wellbeing: float,
	age_group: String,
	population: float
) -> Dictionary:
	if population <= EPSILON:
		return {
			"health_index": 100.0,
			"preventable_burden": 0.0,
			"healthcare_coverage": 1.0,
			"healthcare_penalty": 0.0,
			"commute_penalty": 0.0,
			"exposure_penalty": 0.0,
			"wellbeing_effect": 0.0,
			"age_risk_multiplier": _age_risk_multiplier(age_group),
			"average_commute_minutes": 0.0,
			"pollution_exposure": 0.0,
			"average_wellbeing": WELLBEING_REFERENCE,
		}
	var age_risk := _age_risk_multiplier(age_group)
	var coverage := clampf(_number(care.get("coverage", 0.0), 0.0), 0.0, 1.0)
	var care_penalty := (1.0 - coverage) * HEALTHCARE_PENALTY * age_risk
	var commute_excess := clampf((maxf(0.0, commute_minutes) - 20.0) / 80.0, 0.0, 1.0)
	var commute_penalty := commute_excess * COMMUTE_PENALTY * age_risk
	var exposure_penalty := clampf(pollution_exposure, 0.0, 1.0) * EXPOSURE_PENALTY * age_risk
	var wellbeing_effect := clampf(
		(wellbeing - WELLBEING_REFERENCE) * WELLBEING_SLOPE,
		WELLBEING_MIN_EFFECT,
		WELLBEING_MAX_EFFECT
	)
	var health_index := clampf(100.0 - care_penalty - commute_penalty - exposure_penalty + wellbeing_effect, 0.0, 100.0)
	return {
		"health_index": health_index,
		"preventable_burden": 100.0 - health_index,
		"healthcare_coverage": coverage,
		"healthcare_penalty": care_penalty,
		"commute_penalty": commute_penalty,
		"exposure_penalty": exposure_penalty,
		"wellbeing_effect": wellbeing_effect,
		"age_risk_multiplier": age_risk,
		"average_commute_minutes": maxf(0.0, commute_minutes),
		"pollution_exposure": clampf(pollution_exposure, 0.0, 1.0),
		"average_wellbeing": clampf(wellbeing, 0.0, 100.0),
	}


static func _metrics_from_weighted(
	weighted: Dictionary,
	population: float,
	care: Dictionary,
	commute_minutes: float,
	pollution_exposure: float,
	wellbeing: float
) -> Dictionary:
	var denominator := float(weighted.get("population", 0.0))
	var health_index := float(weighted.get("health_index", 0.0)) / denominator if denominator > EPSILON else 100.0
	var coverage := float(care.get("coverage", 0.0))
	if float(care.get("demand", 0.0)) <= EPSILON and denominator > EPSILON and weighted.has("healthcare_coverage"):
		coverage = float(weighted["healthcare_coverage"]) / denominator
	return {
		"population": maxf(0.0, population),
		"health_index": clampf(health_index, 0.0, 100.0),
		"preventable_burden": clampf(100.0 - health_index, 0.0, 100.0),
		"healthcare_coverage": clampf(coverage, 0.0, 1.0),
		"healthcare_demand": maxf(0.0, float(care.get("demand", 0.0))),
		"healthcare_served": maxf(0.0, float(care.get("served", 0.0))),
		"healthcare_unserved": maxf(0.0, float(care.get("demand", 0.0)) - float(care.get("served", 0.0))),
		"healthcare_data_available": bool(care.get("data_available", false)),
		"average_commute_minutes": clampf(
			float(weighted.get("commute_minutes_sum", 0.0)) / denominator if denominator > EPSILON else maxf(0.0, commute_minutes),
			0.0,
			1000000.0
		),
		"pollution_exposure": clampf(
			float(weighted.get("pollution_exposure_sum", 0.0)) / denominator if denominator > EPSILON else pollution_exposure,
			0.0,
			1.0
		),
		"average_wellbeing": clampf(
			float(weighted.get("wellbeing_sum", 0.0)) / denominator if denominator > EPSILON else wellbeing,
			0.0,
			100.0
		),
		"healthcare_penalty": float(weighted.get("healthcare_penalty", 0.0)) / denominator if denominator > EPSILON else 0.0,
		"commute_penalty": float(weighted.get("commute_penalty", 0.0)) / denominator if denominator > EPSILON else 0.0,
		"exposure_penalty": float(weighted.get("exposure_penalty", 0.0)) / denominator if denominator > EPSILON else 0.0,
		"wellbeing_effect": float(weighted.get("wellbeing_effect", 0.0)) / denominator if denominator > EPSILON else 0.0,
		"age_risk_multiplier": float(weighted.get("age_risk_multiplier", 0.0)) / denominator if denominator > EPSILON else 1.0,
	}


static func _empty_weighted_totals() -> Dictionary:
	return {
		"population": 0.0,
		"health_index": 0.0,
		"healthcare_coverage": 0.0,
		"healthcare_penalty": 0.0,
		"commute_penalty": 0.0,
		"exposure_penalty": 0.0,
		"wellbeing_effect": 0.0,
		"age_risk_multiplier": 0.0,
		"commute_minutes_sum": 0.0,
		"pollution_exposure_sum": 0.0,
		"wellbeing_sum": 0.0,
	}


static func _accumulate_health(target: Dictionary, health: Dictionary, population: float) -> void:
	if population <= EPSILON:
		return
	target["population"] = float(target.get("population", 0.0)) + population
	for key in ["health_index", "healthcare_coverage", "healthcare_penalty", "commute_penalty", "exposure_penalty", "wellbeing_effect", "age_risk_multiplier"]:
		target[key] = float(target.get(key, 0.0)) + float(health.get(key, 0.0)) * population


static func _accumulate_context(target: Dictionary, population: float, commute: float, exposure: float, wellbeing: float) -> void:
	if population <= EPSILON:
		return
	target["commute_minutes_sum"] = float(target.get("commute_minutes_sum", 0.0)) + commute * population
	target["pollution_exposure_sum"] = float(target.get("pollution_exposure_sum", 0.0)) + exposure * population
	target["wellbeing_sum"] = float(target.get("wellbeing_sum", 0.0)) + wellbeing * population


static func _merge_weighted(target: Dictionary, source: Dictionary) -> void:
	for key in target.keys():
		target[key] = float(target.get(key, 0.0)) + float(source.get(key, 0.0))


static func _add_cohort_metrics(
	accumulators: Dictionary,
	cohort_id: String,
	age_group: String,
	health: Dictionary,
	population: float
) -> void:
	if not accumulators.has(cohort_id):
		accumulators[cohort_id] = {"age_group": age_group, "weighted": _empty_weighted_totals()}
	var entry: Dictionary = accumulators[cohort_id]
	var weighted: Dictionary = entry["weighted"]
	_accumulate_health(weighted, health, population)
	_accumulate_context(
		weighted,
		population,
		float(health.get("average_commute_minutes", 0.0)),
		float(health.get("pollution_exposure", 0.0)),
		float(health.get("average_wellbeing", WELLBEING_REFERENCE))
	)
	entry["weighted"] = weighted
	entry["age_group"] = age_group
	accumulators[cohort_id] = entry


static func _finalize_cohort_metrics(accumulators: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var cohort_ids: Array[String] = []
	for value in accumulators.keys():
		cohort_ids.append(str(value))
	cohort_ids.sort()
	for cohort_id in cohort_ids:
		var entry: Dictionary = accumulators[cohort_id]
		var weighted: Dictionary = entry["weighted"]
		var cohort_population := float(weighted.get("population", 0.0))
		var metrics := _metrics_from_weighted(weighted, cohort_population, {"coverage": 0.0}, 0.0, 0.0, WELLBEING_REFERENCE)
		metrics["age_group"] = str(entry.get("age_group", "adults"))
		result[cohort_id] = metrics
	return result


static func _district_metrics_for(metrics: Dictionary, district_id: String) -> Dictionary:
	var nested := _as_dictionary(metrics.get("districts", metrics.get("settlements", {})))
	var value: Variant = nested.get(district_id, {})
	return _as_dictionary(value).duplicate(true)


static func _metric_number(sources: Array, keys: Array, default_value: float) -> float:
	for source_value in sources:
		var source := _as_dictionary(source_value)
		for key in keys:
			if source.has(key):
				return clampf(_number(source[key], default_value), 0.0, 1000000.0)
	return default_value


static func _pollution_exposure(sources: Array) -> float:
	for source_value in sources:
		var source := _as_dictionary(source_value)
		if source.has("pollution_exposure"):
			return clampf(_number(source["pollution_exposure"], 0.0), 0.0, 1.0)
		if source.has("exposure"):
			return clampf(_number(source["exposure"], 0.0), 0.0, 1.0)
		if source.has("pollution_index"):
			return clampf(_number(source["pollution_index"], 0.0) / 100.0, 0.0, 1.0)
	return 0.0


static func _age_group(value: Variant) -> String:
	var normalized := str(value).to_lower()
	if normalized.contains("child") or normalized.contains("student") or normalized.contains("young"):
		return "children"
	if normalized.contains("senior") or normalized.contains("elder") or normalized.contains("older"):
		return "seniors"
	return "adults"


static func _age_risk_multiplier(age_group: String) -> float:
	return float(AGE_RISK.get(age_group, 1.0)) / REFERENCE_AGE_RISK


static func _city_population(city: Dictionary) -> float:
	var demographics := _as_dictionary(city.get("demographics", {}))
	return _non_negative_number(demographics.get("residents", city.get("population", city.get("residents", 0.0))))


static func _merged_dictionary(base: Dictionary, overlay: Dictionary) -> Dictionary:
	var merged := base.duplicate(true)
	for key in overlay:
		merged[key] = overlay[key]
	return merged


static func _as_records(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if typeof(value) == TYPE_ARRAY:
		for row in value:
			if typeof(row) == TYPE_DICTIONARY:
				result.append(row)
	elif typeof(value) == TYPE_DICTIONARY:
		var records: Dictionary = value
		if records.has("id"):
			result.append(records)
		else:
			var record_ids: Array[String] = []
			for key in records.keys():
				record_ids.append(str(key))
			record_ids.sort()
			for record_id in record_ids:
				var row: Variant = records[record_id]
				if typeof(row) != TYPE_DICTIONARY:
					continue
				var entry: Dictionary = row.duplicate(true)
				if not entry.has("id"):
					entry["id"] = record_id
				result.append(entry)
	return result


static func _as_dictionary(value: Variant) -> Dictionary:
	return value if typeof(value) == TYPE_DICTIONARY else {}


static func _number(value: Variant, default_value: float) -> float:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return default_value
	var number := float(value)
	return number if is_finite(number) else default_value


static func _non_negative_number(value: Variant) -> float:
	return clampf(_number(value, 0.0), 0.0, MAX_AGGREGATE_VALUE)
