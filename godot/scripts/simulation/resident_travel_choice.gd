extends RefCounted
class_name ResidentTravelChoice

## Deterministic aggregate mode choice for resident OD/cohort records.
##
## `evaluate` accepts `{"od_cohorts": [...], "parameters": {...}}`. Each
## `od_cohorts` row contains `od_id`, `origin_id`, `destination_id`,
## `cohort_id`, `population`, `trip_count`, `income`, `fare_sensitivity`,
## `car_eligible`, optional `age_group` and `car_availability` (0..1), plus `car` and `transit` dictionaries. A mode dictionary
## contains `minutes`, `cost`, and `reachable`. Income and mode costs must use
## the same currency and modeled time period; trip counts are aggregate trips
## over that period. Each row is one OD/cohort segment, so its population is
## attributed to that segment.
## Optional `parameters` keys are `logit_scale_minutes` (30),
## `fare_minutes_per_currency` (10), `reference_income` (3000),
## `minimum_income` (100), and `unserved_penalty_minutes` (90). A mode is
## feasible only when reachable; car also requires `car_eligible`, and its
## logit availability is scaled by `car_availability`. Missing or
## malformed numeric inputs use safe defaults or zero and are clamped nonnegative.
##
## `fare_sensitivity` multiplies the income-adjusted money cost. Generalized
## cost is measured in minutes: travel minutes plus money cost times
## `fare_minutes_per_currency * fare_sensitivity * reference_income /
## max(income, minimum_income)`.
## Available modes and the always-available `unserved` option are assigned
## multinomial-logit shares using `logit_scale_minutes` as the scale. The
## returned flow values are expected aggregate counts, not sampled people.
## Each result row returns OD/cohort flows, shares, feasible-option costs,
## expected generalized cost, and choice accessibility (the logsum in minutes;
## higher is better). `cohort_welfare` combines rows with the same cohort ID;
## fare burden is expected fares divided by the segment population's income.

const DEFAULT_LOGIT_SCALE_MINUTES := 30.0
const DEFAULT_FARE_MINUTES_PER_CURRENCY := 10.0
const DEFAULT_REFERENCE_INCOME := 3000.0
const DEFAULT_MINIMUM_INCOME := 100.0
const DEFAULT_UNSERVED_PENALTY_MINUTES := 90.0
const EPSILON := 0.000001


static func evaluate(input: Dictionary) -> Dictionary:
	var parameters := _as_dictionary(input.get("parameters", {}))
	var logit_scale := _positive_number(
		parameters.get("logit_scale_minutes", DEFAULT_LOGIT_SCALE_MINUTES),
		DEFAULT_LOGIT_SCALE_MINUTES
	)
	var fare_minutes_per_currency := _non_negative_number(
		parameters.get("fare_minutes_per_currency", DEFAULT_FARE_MINUTES_PER_CURRENCY),
		DEFAULT_FARE_MINUTES_PER_CURRENCY
	)
	var reference_income := _positive_number(
		parameters.get("reference_income", DEFAULT_REFERENCE_INCOME),
		DEFAULT_REFERENCE_INCOME
	)
	var minimum_income := _positive_number(
		parameters.get("minimum_income", DEFAULT_MINIMUM_INCOME),
		DEFAULT_MINIMUM_INCOME
	)
	var unserved_penalty := _non_negative_number(
		parameters.get("unserved_penalty_minutes", DEFAULT_UNSERVED_PENALTY_MINUTES),
		DEFAULT_UNSERVED_PENALTY_MINUTES
	)

	var input_rows: Variant = input.get("od_cohorts", [])
	var flows: Array[Dictionary] = []
	var cohort_accumulators: Dictionary = {}
	var totals := {
		"population": 0.0,
		"trips": 0.0,
		"car": 0.0,
		"transit": 0.0,
		"unserved": 0.0,
		"expected_fare_paid": 0.0,
	}

	if typeof(input_rows) == TYPE_ARRAY:
		var rows: Array = input_rows
		for row_index in range(rows.size()):
			var row_value: Variant = rows[row_index]
			if typeof(row_value) != TYPE_DICTIONARY:
				continue
			var row: Dictionary = row_value
			var car_eligible := bool(row.get("car_eligible", false))
			var car_availability := clampf(
				_non_negative_number(
					row.get("car_availability", 1.0 if car_eligible else 0.0),
					0.0
				),
				0.0,
				1.0
			)
			var row_variants: Array[Dictionary] = [row]
			if car_eligible and car_availability > EPSILON and car_availability < 1.0 - EPSILON:
				var population := _non_negative_number(row.get("population", 0.0), 0.0)
				var trip_count := _non_negative_number(row.get("trip_count", 0.0), 0.0)
				var car_accessible_row := row.duplicate(true)
				car_accessible_row["population"] = population * car_availability
				car_accessible_row["trip_count"] = trip_count * car_availability
				car_accessible_row["car_availability"] = 1.0
				var no_car_row := row.duplicate(true)
				no_car_row["population"] = population * (1.0 - car_availability)
				no_car_row["trip_count"] = trip_count * (1.0 - car_availability)
				no_car_row["car_eligible"] = false
				no_car_row["car_availability"] = 0.0
				row_variants = [car_accessible_row, no_car_row]
			for row_variant in row_variants:
				var evaluated := _evaluate_row(
					row_variant,
					row_index,
					logit_scale,
					fare_minutes_per_currency,
					reference_income,
					minimum_income,
					unserved_penalty
				)
				flows.append(evaluated)
				_add_to_totals(totals, evaluated)
				var row_population := float(evaluated["population"])
				var row_income := _non_negative_number(row_variant.get("income", 0.0), 0.0)
				_add_to_cohort(cohort_accumulators, evaluated, row_population * row_income)

	var cohort_welfare: Dictionary = {}
	for cohort_id_value in cohort_accumulators.keys():
		var accumulator: Dictionary = cohort_accumulators[cohort_id_value]
		var trip_count := float(accumulator["trips"])
		var income_base := float(accumulator["income_base"])
		cohort_welfare[str(cohort_id_value)] = {
			"age_group": str(accumulator.get("age_group", "adults")),
			"population": float(accumulator["population"]),
			"trips": trip_count,
			"flows": {
				"car": float(accumulator["car"]),
				"transit": float(accumulator["transit"]),
				"unserved": float(accumulator["unserved"]),
			},
			"shares": _shares(
				trip_count,
				float(accumulator["car"]),
				float(accumulator["transit"]),
				float(accumulator["unserved"])
			),
			"expected_generalized_cost_minutes": (
				float(accumulator["generalized_cost_trip_sum"]) / trip_count
				if trip_count > EPSILON else 0.0
			),
			"average_commute_minutes": (
				float(accumulator["commute_trip_minutes_sum"]) / trip_count
				if trip_count > EPSILON else 0.0
			),
			"income_base": income_base,
			"choice_accessibility_minutes": (
				float(accumulator["accessibility_trip_sum"]) / trip_count
				if trip_count > EPSILON else 0.0
			),
			"expected_fare_paid": float(accumulator["fare_paid"]),
			"fare_burden": (
				float(accumulator["fare_paid"]) / income_base
				if income_base > EPSILON else 0.0
			),
		}

	var total_trips := float(totals["trips"])
	var total_car := float(totals["car"])
	var total_transit := float(totals["transit"])
	var total_unserved := float(totals["unserved"])
	return {
		"schema_version": 1,
		"flows": flows,
		"cohort_welfare": cohort_welfare,
		"totals": {
			"population": float(totals["population"]),
			"trips": total_trips,
			"flows": {
				"car": total_car,
				"transit": total_transit,
				"unserved": total_unserved,
			},
			"shares": _shares(total_trips, total_car, total_transit, total_unserved),
			"expected_fare_paid": float(totals["expected_fare_paid"]),
		},
	}


static func _evaluate_row(
	row: Dictionary,
	row_index: int,
	logit_scale: float,
	fare_minutes_per_currency: float,
	reference_income: float,
	minimum_income: float,
	unserved_penalty: float
) -> Dictionary:
	var population := _non_negative_number(row.get("population", 0.0), 0.0)
	var trip_count := _non_negative_number(row.get("trip_count", 0.0), 0.0)
	var income := _non_negative_number(row.get("income", 0.0), 0.0)
	var fare_sensitivity := _non_negative_number(row.get("fare_sensitivity", 1.0), 1.0)
	var income_ratio := reference_income / maxf(income, minimum_income)
	var money_cost_multiplier := fare_minutes_per_currency * fare_sensitivity * income_ratio
	var car_eligible := bool(row.get("car_eligible", false))
	var car_availability := clampf(
		_non_negative_number(row.get("car_availability", 1.0 if car_eligible else 0.0), 0.0),
		0.0,
		1.0
	)
	var options: Array[Dictionary] = []
	var generalized_costs: Dictionary = {}
	var transit_cost := 0.0
	var transit_available := false

	for mode in ["car", "transit"]:
		var mode_data := _as_dictionary(row.get(mode, {}))
		var mode_reachable := bool(mode_data.get("reachable", false))
		if not mode_reachable or (mode == "car" and (not car_eligible or car_availability <= EPSILON)):
			continue
		var minutes := _non_negative_number(mode_data.get("minutes", 0.0), 0.0)
		var cost := _non_negative_number(mode_data.get("cost", 0.0), 0.0)
		var generalized_cost := minutes + cost * money_cost_multiplier
		generalized_costs[mode] = generalized_cost
		options.append({
			"mode": mode,
			"minutes": minutes,
			"generalized_cost_minutes": generalized_cost,
			"cost": cost,
		})
		if mode == "transit":
			transit_cost = cost
			transit_available = true

	options.append({
		"mode": "unserved",
		"minutes": unserved_penalty,
		"generalized_cost_minutes": unserved_penalty,
		"cost": 0.0,
	})
	generalized_costs["unserved"] = unserved_penalty
	var minimum_generalized_cost := INF
	for option in options:
		minimum_generalized_cost = minf(
			minimum_generalized_cost,
			float(option["generalized_cost_minutes"])
		)

	var weights: Dictionary = {}
	var total_weight := 0.0
	for option in options:
		var mode := str(option["mode"])
		var generalized_cost := float(option["generalized_cost_minutes"])
		var weight := exp(-(generalized_cost - minimum_generalized_cost) / logit_scale)
		weights[mode] = weight
		total_weight += weight

	var probabilities := {"car": 0.0, "transit": 0.0, "unserved": 1.0}
	if total_weight > EPSILON:
		for mode in weights.keys():
			probabilities[str(mode)] = float(weights[mode]) / total_weight
	# Compute the residual share explicitly so the three alternatives reconcile.
	probabilities["unserved"] = maxf(
		0.0,
		1.0 - float(probabilities["car"]) - float(probabilities["transit"])
	)

	var car_flow := trip_count * float(probabilities["car"])
	var transit_flow := trip_count * float(probabilities["transit"])
	var unserved_flow := maxf(0.0, trip_count - car_flow - transit_flow)
	var expected_generalized_cost := 0.0
	var expected_commute_minutes := 0.0
	var logsum_weight := 0.0
	for option in options:
		var mode := str(option["mode"])
		var probability := float(probabilities[mode])
		var generalized_cost := float(option["generalized_cost_minutes"])
		expected_generalized_cost += probability * generalized_cost
		expected_commute_minutes += probability * float(option.get("minutes", 0.0))
		logsum_weight += exp(-(generalized_cost - minimum_generalized_cost) / logit_scale)
	var accessibility := -minimum_generalized_cost + logit_scale * log(maxf(logsum_weight, EPSILON))
	var fare_paid := transit_flow * transit_cost if transit_available else 0.0
	var income_base := population * income
	var fare_burden := fare_paid / income_base if income_base > EPSILON else 0.0
	var od_id := str(row.get("od_id", "")).strip_edges()
	if od_id.is_empty():
		od_id = "od-%d" % row_index
	var cohort_id := str(row.get("cohort_id", "")).strip_edges()
	if cohort_id.is_empty():
		cohort_id = "cohort-%d" % row_index

	return {
		"od_id": od_id,
		"origin_id": str(row.get("origin_id", "")),
		"destination_id": str(row.get("destination_id", "")),
		"cohort_id": cohort_id,
		"age_group": str(row.get("age_group", "adults")),
		"population": population,
		"trips": trip_count,
		"flows": {"car": car_flow, "transit": transit_flow, "unserved": unserved_flow},
		"shares": {
			"car": float(probabilities["car"]),
			"transit": float(probabilities["transit"]),
			"unserved": float(probabilities["unserved"]),
		},
		"generalized_costs_minutes": generalized_costs,
		"option_probabilities": probabilities,
		"expected_generalized_cost_minutes": expected_generalized_cost,
		"expected_commute_minutes": expected_commute_minutes,
		"choice_accessibility_minutes": accessibility,
		"expected_fare_paid": fare_paid,
		"fare_burden": fare_burden,
	}


static func _add_to_totals(totals: Dictionary, row: Dictionary) -> void:
	totals["population"] = float(totals["population"]) + float(row["population"])
	totals["trips"] = float(totals["trips"]) + float(row["trips"])
	var flows: Dictionary = row["flows"]
	for mode in ["car", "transit", "unserved"]:
		totals[mode] = float(totals[mode]) + float(flows[mode])
	totals["expected_fare_paid"] = float(totals["expected_fare_paid"]) + float(row["expected_fare_paid"])


static func _add_to_cohort(cohorts: Dictionary, row: Dictionary, income_base: float) -> void:
	var cohort_id := str(row["cohort_id"])
	if not cohorts.has(cohort_id):
		cohorts[cohort_id] = {
			"age_group": str(row.get("age_group", "adults")),
			"population": 0.0,
			"trips": 0.0,
			"car": 0.0,
			"transit": 0.0,
			"unserved": 0.0,
			"generalized_cost_trip_sum": 0.0,
			"accessibility_trip_sum": 0.0,
			"fare_paid": 0.0,
			"income_base": 0.0,
			"commute_trip_minutes_sum": 0.0,
		}
	var accumulator: Dictionary = cohorts[cohort_id]
	var flows: Dictionary = row["flows"]
	var trip_count := float(row["trips"])
	accumulator["population"] = float(accumulator["population"]) + float(row["population"])
	accumulator["trips"] = float(accumulator["trips"]) + trip_count
	for mode in ["car", "transit", "unserved"]:
		accumulator[mode] = float(accumulator[mode]) + float(flows[mode])
	accumulator["generalized_cost_trip_sum"] = (
		float(accumulator["generalized_cost_trip_sum"])
		+ float(row["expected_generalized_cost_minutes"]) * trip_count
	)
	accumulator["accessibility_trip_sum"] = (
		float(accumulator["accessibility_trip_sum"])
		+ float(row["choice_accessibility_minutes"]) * trip_count
	)
	accumulator["fare_paid"] = float(accumulator["fare_paid"]) + float(row["expected_fare_paid"])
	accumulator["income_base"] = float(accumulator["income_base"]) + income_base
	accumulator["commute_trip_minutes_sum"] = (
		float(accumulator["commute_trip_minutes_sum"])
		+ float(row.get("expected_commute_minutes", 0.0)) * trip_count
	)
	cohorts[cohort_id] = accumulator


static func _shares(trips: float, car: float, transit: float, unserved: float) -> Dictionary:
	if trips <= EPSILON:
		return {"car": 0.0, "transit": 0.0, "unserved": 0.0}
	return {
		"car": car / trips,
		"transit": transit / trips,
		"unserved": unserved / trips,
	}


static func _as_dictionary(value: Variant) -> Dictionary:
	return value if typeof(value) == TYPE_DICTIONARY else {}


static func _number(value: Variant, fallback: float) -> float:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return fallback
	var result := float(value)
	if is_nan(result) or is_inf(result):
		return fallback
	return result


static func _non_negative_number(value: Variant, fallback: float) -> float:
	return maxf(0.0, _number(value, fallback))


static func _positive_number(value: Variant, fallback: float) -> float:
	var result := _number(value, fallback)
	return result if result > EPSILON else fallback
