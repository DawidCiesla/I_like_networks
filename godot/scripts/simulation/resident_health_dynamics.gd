extends RefCounted
class_name ResidentHealthDynamics

## Aggregate gameplay dynamics layered over ResidentHealth's transparent
## planning scores. These constants are deliberately stylized, not clinical.
const SCHEMA_VERSION := 3
const MAX_YEAR_STEP := 1000.0
const EPSILON := 0.000001
const ACUTE_INCIDENCE := 0.16
const ACUTE_RECOVERY := 8.0
const ACUTE_CARE_RECOVERY := 18.0
const CHRONIC_INCIDENCE := {"children": 0.001, "adults": 0.003, "seniors": 0.010}
const CHRONIC_REMISSION := 0.006
const CHRONIC_CARE_REMISSION := 0.035
const MORTALITY := {"children": 0.001, "adults": 0.004, "seniors": 0.025}
const FERTILITY_PER_ADULT := 0.015
const CHILD_AGE_RATE := 1.0 / 18.0
const ADULT_AGE_RATE := 1.0 / 49.0


## `health_step` contains the planning metrics and health-trend state already
## produced by ResidentHealth. `previous_state` supplies prior case burdens.
static func advance(previous_state: Dictionary, health_step: Dictionary, elapsed_years: float) -> Dictionary:
	var metrics: Dictionary = _dict(health_step.get("metrics", {})).duplicate(true)
	var state: Dictionary = _dict(health_step.get("state", {})).duplicate(true)
	var districts: Dictionary = _dict(metrics.get("districts", {}))
	var previous_districts := _dict(previous_state.get("districts", {})) if _supported(previous_state) else {}
	var state_districts: Dictionary = _dict(state.get("districts", {}))
	var dt := clampf(_number(elapsed_years, 0.0), 0.0, MAX_YEAR_STEP)
	var city_population := 0.0
	var city_health_sum := 0.0
	var city_acute := 0.0
	var city_chronic := 0.0
	var city_incident := 0.0
	var city_treated := 0.0
	var city_deaths := 0.0
	var city_births := 0.0
	var aggregate_cohorts: Dictionary = {}
	var district_ids: Array[String] = []
	for key in districts:
		district_ids.append(str(key))
	district_ids.sort()

	for district_id in district_ids:
		var district: Dictionary = _dict(districts[district_id]).duplicate(true)
		var district_state: Dictionary = _dict(state_districts.get(district_id, {})).duplicate(true)
		var cohort_state: Dictionary = _dict(district_state.get("cohorts", {})).duplicate(true)
		var old_cohorts := _dict(_dict(previous_districts.get(district_id, {})).get("cohorts", {}))
		var metric_cohorts: Dictionary = _dict(district.get("cohorts", {})).duplicate(true)
		var ids: Array[String] = []
		for key in cohort_state:
			ids.append(str(key))
		ids.sort()
		var incident := 0.0
		var treated := 0.0
		var deaths := 0.0
		var start_population := 0.0
		var acute_total := 0.0
		var chronic_total := 0.0
		var health_sum := 0.0

		for cohort_id in ids:
			var row: Dictionary = _dict(cohort_state[cohort_id]).duplicate(true)
			var output: Dictionary = _dict(metric_cohorts.get(cohort_id, {})).duplicate(true)
			var age := _age(row.get("age_group", cohort_id))
			var population := _non_negative(_number(row.get("population", output.get("population", 0.0)), 0.0))
			var old: Dictionary = _dict(old_cohorts.get(cohort_id, {}))
			var old_population := _non_negative(_number(old.get("population", population), population))
			var reconcile := population / old_population if old_population > EPSILON else 1.0
			var acute_before := minf(population, _non_negative(_number(old.get("acute_cases", 0.0), 0.0)) * reconcile)
			var chronic_before := minf(population, _non_negative(_number(old.get("chronic_cases", 0.0), 0.0)) * reconcile)
			var care := clampf(_number(output.get("healthcare_coverage", 0.0), 0.0), 0.0, 1.0)
			var exposure := clampf(_number(output.get("pollution_exposure", 0.0), 0.0), 0.0, 1.0)
			var commute := clampf((_non_negative(_number(output.get("average_commute_minutes", 0.0), 0.0)) - 20.0) / 80.0, 0.0, 1.0)
			var wellbeing := clampf(_number(output.get("average_wellbeing", 70.0), 70.0), 0.0, 100.0)
			row["average_wellbeing"] = wellbeing
			var low_wellbeing := clampf((70.0 - wellbeing) / 70.0, 0.0, 1.0)
			var age_risk := 1.25 if age == "children" else (1.4 if age == "seniors" else 1.0)
			var stress := 1.0 + exposure * 0.9 + commute * 0.45 + low_wellbeing * 0.25
			var acute_rate := clampf(ACUTE_INCIDENCE * age_risk * stress * (1.0 - care * 0.25), 0.0, 1.5)
			var acute_step := _advance_condition(population, acute_before, acute_rate, ACUTE_RECOVERY + care * ACUTE_CARE_RECOVERY, dt)
			var acute_new := float(acute_step["new"])
			var acute_recovered := float(acute_step["recovered"])
			var acute_after := float(acute_step["cases"])
			var chronic_rate := clampf(float(CHRONIC_INCIDENCE.get(age, 0.003)) * stress * (1.0 - care * 0.45), 0.0, 0.10)
			var chronic_step := _advance_condition(population, chronic_before, chronic_rate, CHRONIC_REMISSION + care * CHRONIC_CARE_REMISSION, dt)
			var chronic_new := float(chronic_step["new"])
			var chronic_recovered := float(chronic_step["recovered"])
			var chronic_after := float(chronic_step["cases"])
			incident += acute_new + chronic_new
			treated += (acute_new + acute_recovered + chronic_new + chronic_recovered) * care

			var chronic_share := chronic_after / population if population > EPSILON else 0.0
			var acute_share := acute_after / population if population > EPSILON else 0.0
			var risk := clampf(exposure * 0.7 + commute * 0.25 + low_wellbeing * 0.2 + chronic_share * 0.8 + acute_share * 0.35, 0.0, 1.5)
			var hazard := clampf(float(MORTALITY.get(age, 0.004)) * (1.0 + risk) * (1.0 - care * 0.3), 0.0, 0.10)
			var deaths_here := population * (1.0 - exp(-hazard * dt))
			var survivors := maxf(0.0, population - deaths_here)
			var survivor_fraction := survivors / population if population > EPSILON else 0.0
			acute_after *= survivor_fraction
			chronic_after *= survivor_fraction
			var underlying_health := clampf(_number(row.get("underlying_health_index", row.get("health_index", 100.0)), 100.0), 0.0, 100.0)
			var disease_penalty := minf(30.0, (acute_after / maxf(survivors, EPSILON)) * 18.0 + (chronic_after / maxf(survivors, EPSILON)) * 12.0)
			var final_health := clampf(underlying_health - disease_penalty, 0.0, 100.0)
			row["population"] = survivors
			row["acute_cases"] = acute_after
			row["chronic_cases"] = chronic_after
			row["health_index"] = final_health
			row["underlying_health_index"] = underlying_health
			row["age_group"] = age
			row["births"] = 0.0
			row["deaths"] = deaths_here
			row["new_cases"] = acute_new + chronic_new
			row["treated_cases"] = (acute_new + acute_recovered + chronic_new + chronic_recovered) * care
			row["annual_mortality_rate"] = hazard
			row["average_wellbeing"] = wellbeing
			cohort_state[cohort_id] = row
			start_population += population
			deaths += deaths_here

		# Calculate births from the surviving adults in the starting age bands,
		# then add newborns after transitions so neither new adults nor newborns
		# are treated as having occupied their new age band for the whole step.
		var births := _births(cohort_state, dt)
		_age_cohorts(cohort_state, dt)
		_add_births(cohort_state, births)
		for cohort_id in cohort_state:
			var row: Dictionary = cohort_state[cohort_id]
			var population := _non_negative(_number(row.get("population", 0.0), 0.0))
			var age := _age(row.get("age_group", cohort_id))
			var acute := minf(population, _non_negative(_number(row.get("acute_cases", 0.0), 0.0)))
			var chronic := minf(population, _non_negative(_number(row.get("chronic_cases", 0.0), 0.0)))
			var final_health := clampf(_number(row.get("health_index", 100.0), 100.0), 0.0, 100.0)
			var metric: Dictionary = _dict(metric_cohorts.get(cohort_id, {})).duplicate(true)
			metric["id"] = cohort_id
			metric["age_group"] = age
			metric["population"] = population
			metric["health_index"] = final_health
			metric["preventable_burden"] = 100.0 - final_health
			metric["acute_cases"] = acute
			metric["acute_prevalence"] = acute / population if population > EPSILON else 0.0
			metric["chronic_cases"] = chronic
			metric["chronic_prevalence"] = chronic / population if population > EPSILON else 0.0
			metric["new_cases"] = _non_negative(_number(row.get("new_cases", 0.0), 0.0))
			metric["treated_cases"] = _non_negative(_number(row.get("treated_cases", 0.0), 0.0))
			metric["deaths"] = _non_negative(_number(row.get("deaths", 0.0), 0.0))
			metric["births"] = _non_negative(_number(row.get("births", 0.0), 0.0))
			metric["annual_mortality_rate"] = clampf(_number(row.get("annual_mortality_rate", 0.0), 0.0), 0.0, 0.10)
			metric_cohorts[cohort_id] = metric
			cohort_state[cohort_id] = row
			var case_metric: Dictionary = _dict(aggregate_cohorts.get(cohort_id, {"age_group": age, "population": 0.0, "health": 0.0, "trend": 0.0, "acute": 0.0, "chronic": 0.0, "new": 0.0, "treated": 0.0, "deaths": 0.0, "births": 0.0, "hazard": 0.0})).duplicate(true)
			case_metric["population"] = float(case_metric["population"]) + population
			case_metric["health"] = float(case_metric["health"]) + final_health * population
			case_metric["trend"] = float(case_metric["trend"]) + _number(metric.get("annual_health_trend", 0.0), 0.0) * population
			case_metric["acute"] = float(case_metric["acute"]) + acute
			case_metric["chronic"] = float(case_metric["chronic"]) + chronic
			case_metric["new"] = float(case_metric["new"]) + float(metric["new_cases"])
			case_metric["treated"] = float(case_metric["treated"]) + float(metric["treated_cases"])
			case_metric["deaths"] = float(case_metric["deaths"]) + float(metric["deaths"])
			case_metric["births"] = float(case_metric["births"]) + float(metric["births"])
			case_metric["hazard"] = float(case_metric["hazard"]) + float(metric["annual_mortality_rate"]) * population
			aggregate_cohorts[cohort_id] = case_metric
			start_population += 0.0
			city_population += population
			city_health_sum += final_health * population
			city_acute += acute
			city_chronic += chronic
			city_incident += float(metric["new_cases"])
			city_treated += float(metric["treated_cases"])
			city_deaths += float(metric["deaths"])
			city_births += float(metric["births"])
			acute_total += acute
			chronic_total += chronic
			health_sum += final_health * population

		var total_population := 0.0
		for row_value in cohort_state.values():
			total_population += _non_negative(_number(_dict(row_value).get("population", 0.0), 0.0))
		district["cohorts"] = metric_cohorts
		district["population"] = total_population
		district["health_index"] = health_sum / total_population if total_population > EPSILON else 100.0
		district["preventable_burden"] = 100.0 - float(district["health_index"])
		district["acute_cases"] = acute_total
		district["acute_prevalence"] = acute_total / total_population if total_population > EPSILON else 0.0
		district["chronic_cases"] = chronic_total
		district["chronic_prevalence"] = chronic_total / total_population if total_population > EPSILON else 0.0
		district["new_cases"] = incident
		district["treated_cases"] = treated
		district["deaths"] = deaths
		district["births"] = births
		district["net_population_change"] = births - deaths
		district["annual_mortality_rate"] = deaths / start_population / dt if start_population > EPSILON and dt > EPSILON else 0.0
		districts[district_id] = district
		district_state["population"] = total_population
		district_state["observed_population"] = _non_negative(_number(
			district_state.get("observed_population", total_population),
		total_population
	))
		district_state["cohorts"] = cohort_state
		state_districts[district_id] = district_state

	metrics["districts"] = districts
	metrics["population"] = city_population
	metrics["health_index"] = city_health_sum / city_population if city_population > EPSILON else 100.0
	metrics["preventable_burden"] = 100.0 - float(metrics["health_index"])
	metrics["acute_cases"] = city_acute
	metrics["acute_prevalence"] = city_acute / city_population if city_population > EPSILON else 0.0
	metrics["chronic_cases"] = city_chronic
	metrics["chronic_prevalence"] = city_chronic / city_population if city_population > EPSILON else 0.0
	metrics["new_cases"] = city_incident
	metrics["treated_cases"] = city_treated
	metrics["deaths"] = city_deaths
	metrics["births"] = city_births
	metrics["net_population_change"] = city_births - city_deaths
	metrics["annual_mortality_rate"] = city_deaths / maxf(EPSILON, city_population + city_deaths - city_births) / dt if dt > EPSILON else 0.0
	metrics["cohorts"] = _aggregate_cohorts(aggregate_cohorts)
	state["schema_version"] = SCHEMA_VERSION
	state["districts"] = state_districts
	return {"state": state, "metrics": metrics}


static func saved_population_cohorts(districts: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var district_ids: Array[String] = []
	for key in districts:
		district_ids.append(str(key))
	district_ids.sort()
	for district_id in district_ids:
		var district := _dict(districts.get(district_id, {}))
		var cohorts := _dict(district.get("cohorts", {}))
		for cohort_id in cohorts:
			var cohort := _dict(cohorts[cohort_id])
			rows.append({"id": str(cohort_id), "district_id": district_id, "age_group": str(cohort.get("age_group", cohort_id)), "population": _non_negative(_number(cohort.get("population", 0.0), 0.0))})
	return rows


static func _advance_condition(population: float, cases: float, incidence: float, recovery: float, years: float) -> Dictionary:
	var stock := maxf(0.0, population)
	var prior := clampf(cases, 0.0, stock)
	if stock <= EPSILON or years <= 0.0:
		return {"cases": prior, "new": 0.0, "recovered": 0.0}
	var rate := maxf(0.0, incidence)
	var recovery_rate := maxf(0.0, recovery)
	var combined_rate := rate + recovery_rate
	if combined_rate <= EPSILON:
		return {"cases": prior, "new": 0.0, "recovered": 0.0}
	var prior_share := prior / stock
	var equilibrium := rate / combined_rate
	var decay := exp(-combined_rate * years)
	var next_share := clampf(equilibrium + (prior_share - equilibrium) * decay, 0.0, 1.0)
	var new_share := rate * ((1.0 - equilibrium) * years - (prior_share - equilibrium) * (1.0 - decay) / combined_rate)
	var new_cases := clampf(new_share * stock, 0.0, stock - prior)
	var next_cases := next_share * stock
	var recovered := clampf(prior + new_cases - next_cases, 0.0, prior + new_cases)
	return {"cases": next_cases, "new": new_cases, "recovered": recovered}


static func _births(cohorts: Dictionary, years: float) -> float:
	if years <= 0.0:
		return 0.0
	var children_id := _first_age_id(cohorts, "children")
	var adults_id := _first_age_id(cohorts, "adults")
	if children_id.is_empty() or adults_id.is_empty():
		return 0.0
	var adults: Dictionary = cohorts[adults_id]
	var fertility := clampf(1.0 + (_number(adults.get("average_wellbeing", 70.0), 70.0) - 70.0) / 100.0, 0.75, 1.25)
	var amount := _non_negative(_number(adults.get("population", 0.0), 0.0)) * FERTILITY_PER_ADULT * fertility * years
	return amount


static func _add_births(cohorts: Dictionary, amount: float) -> void:
	if amount <= 0.0:
		return
	var children_id := _first_age_id(cohorts, "children")
	if children_id.is_empty():
		return
	var children: Dictionary = cohorts[children_id]
	children["population"] = _non_negative(_number(children.get("population", 0.0), 0.0)) + _non_negative(amount)
	children["births"] = amount
	cohorts[children_id] = children


static func _age_cohorts(cohorts: Dictionary, years: float) -> void:
	if years <= 0.0:
		return
	# Apply the exact end-of-step probabilities for the two-stage age process.
	# Moving children into adults before calculating adult ageing would age those
	# same residents for the full step twice, and could move newborns born during
	# this step into older cohorts immediately.
	var child_survival := exp(-CHILD_AGE_RATE * years)
	var adult_survival := exp(-ADULT_AGE_RATE * years)
	var rate_difference := CHILD_AGE_RATE - ADULT_AGE_RATE
	var child_to_adult := 0.0
	if absf(rate_difference) > EPSILON:
		child_to_adult = CHILD_AGE_RATE * (adult_survival - child_survival) / rate_difference
	else:
		child_to_adult = CHILD_AGE_RATE * years * child_survival
	child_to_adult = clampf(child_to_adult, 0.0, 1.0 - child_survival)
	var child_to_senior := clampf(1.0 - child_survival - child_to_adult, 0.0, 1.0)
	var remaining_children := maxf(EPSILON, 1.0 - child_to_adult)
	var remaining_child_to_senior := clampf(child_to_senior / remaining_children, 0.0, 1.0)

	# Adults present at the start of the step age first. Children are then routed
	# to adults or seniors using their calculated end-of-step probabilities.
	_transfer(cohorts, "adults", "seniors", 1.0 - adult_survival)
	_transfer(cohorts, "children", "adults", child_to_adult)
	_transfer(cohorts, "children", "seniors", remaining_child_to_senior)


static func _transfer(cohorts: Dictionary, source_age: String, target_age: String, fraction: float) -> void:
	var sources := _ids_for_age(cohorts, source_age)
	var targets := _ids_for_age(cohorts, target_age)
	if sources.is_empty() or targets.is_empty() or fraction <= 0.0:
		return
	var moved_population := 0.0
	var moved_acute := 0.0
	var moved_chronic := 0.0
	var moved_health := 0.0
	var moved_planning_health := 0.0
	for id in sources:
		var row: Dictionary = cohorts[id]
		var population := _non_negative(_number(row.get("population", 0.0), 0.0))
		var moved := population * fraction
		if moved <= 0.0:
			continue
		var share := moved / population
		moved_population += moved
		moved_acute += _non_negative(_number(row.get("acute_cases", 0.0), 0.0)) * share
		moved_chronic += _non_negative(_number(row.get("chronic_cases", 0.0), 0.0)) * share
		moved_health += clampf(_number(row.get("health_index", 100.0), 100.0), 0.0, 100.0) * moved
		moved_planning_health += clampf(_number(row.get("planning_health_index", 100.0), 100.0), 0.0, 100.0) * moved
		row["population"] = population - moved
		row["acute_cases"] = maxf(0.0, _non_negative(_number(row.get("acute_cases", 0.0), 0.0)) * (1.0 - share))
		row["chronic_cases"] = maxf(0.0, _non_negative(_number(row.get("chronic_cases", 0.0), 0.0)) * (1.0 - share))
		cohorts[id] = row
	if moved_population <= 0.0:
		return
	var target_id := targets[0]
	var target: Dictionary = cohorts[target_id]
	var target_population := _non_negative(_number(target.get("population", 0.0), 0.0))
	var combined := target_population + moved_population
	target["population"] = combined
	target["acute_cases"] = _non_negative(_number(target.get("acute_cases", 0.0), 0.0)) + moved_acute
	target["chronic_cases"] = _non_negative(_number(target.get("chronic_cases", 0.0), 0.0)) + moved_chronic
	target["health_index"] = (clampf(_number(target.get("health_index", 100.0), 100.0), 0.0, 100.0) * target_population + moved_health) / combined
	target["underlying_health_index"] = (clampf(_number(target.get("underlying_health_index", 100.0), 100.0), 0.0, 100.0) * target_population + moved_planning_health) / combined
	target["planning_health_index"] = (clampf(_number(target.get("planning_health_index", 100.0), 100.0), 0.0, 100.0) * target_population + moved_planning_health) / combined
	cohorts[target_id] = target


static func _first_age_id(cohorts: Dictionary, age: String) -> String:
	var ids := _ids_for_age(cohorts, age)
	return ids[0] if not ids.is_empty() else ""


static func _ids_for_age(cohorts: Dictionary, age: String) -> Array[String]:
	var result: Array[String] = []
	for key in cohorts:
		if _age(_dict(cohorts[key]).get("age_group", key)) == age:
			result.append(str(key))
	result.sort()
	return result


static func _aggregate_cohorts(totals: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in totals:
		var row: Dictionary = totals[key]
		var population := float(row.get("population", 0.0))
		var acute := float(row.get("acute", 0.0))
		var chronic := float(row.get("chronic", 0.0))
		result[key] = {
			"age_group": str(row.get("age_group", "adults")),
			"population": population,
			"health_index": float(row.get("health", 100.0 * population)) / population if population > EPSILON else 100.0,
			"acute_cases": acute,
			"acute_prevalence": acute / population if population > EPSILON else 0.0,
			"chronic_cases": chronic,
			"chronic_prevalence": chronic / population if population > EPSILON else 0.0,
			"new_cases": float(row.get("new", 0.0)),
			"treated_cases": float(row.get("treated", 0.0)),
			"deaths": float(row.get("deaths", 0.0)),
			"births": float(row.get("births", 0.0)),
			"annual_mortality_rate": float(row.get("hazard", 0.0)) / population if population > EPSILON else 0.0,
			"annual_health_trend": float(row.get("trend", 0.0)) / population if population > EPSILON else 0.0,
		}
	return result


static func _supported(state: Dictionary) -> bool:
	var version := int(_number(state.get("schema_version", 0), 0.0))
	return version in [1, 2, SCHEMA_VERSION]


static func _age(value: Variant) -> String:
	var normalized := str(value).to_lower()
	if normalized.contains("child") or normalized.contains("student") or normalized.contains("young"):
		return "children"
	if normalized.contains("senior") or normalized.contains("elder") or normalized.contains("older"):
		return "seniors"
	return "adults"


static func _number(value: Variant, fallback: float) -> float:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return fallback
	var number := float(value)
	return number if is_finite(number) else fallback


static func _non_negative(value: float) -> float:
	return clampf(_number(value, 0.0), 0.0, 1.0e12)


static func _dict(value: Variant) -> Dictionary:
	return value if typeof(value) == TYPE_DICTIONARY else {}
