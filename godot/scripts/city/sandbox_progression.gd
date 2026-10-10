extends RefCounted
class_name SandboxProgression

## Optional regional-sandbox objectives and infrastructure readiness.
##
## `evaluate` accepts public aggregate metrics already exposed by GameStore and
## the regional runtimes. It remains pure-data: the progression model never
## mutates simulation state or unlocks infrastructure by itself.

const TransitModes = preload("res://scripts/transport/transit_modes.gd")

const NEXT_MODE_ORDER := ["tram", "metro"]
const EARLY_PASSENGER_TARGET := 250.0
const REGIONAL_ACCESS_TARGET := 0.25
const CURRENT_TRANSIT_SHARE_TARGET := 0.15
const MOBILITY_ACCESS_TARGET := 0.65
const HEALTHCARE_COVERAGE_TARGET := 0.95
const EPSILON := 0.000001


static func evaluate(metrics: Dictionary) -> Dictionary:
	var population := _non_negative_int(metrics.get("resident_count", metrics.get("population", 0)))
	var treasury := _non_negative(metrics.get("public_treasury", metrics.get("treasury", 0.0)))
	var unlocked_modes: Variant = metrics.get("unlocked_modes", {"bus": true})
	var startup_capital_by_mode: Variant = metrics.get("minimum_startup_capital_by_mode", {})
	var mode_unlocks: Dictionary = {}
	for mode in NEXT_MODE_ORDER:
		var startup_capital := 0.0
		if typeof(startup_capital_by_mode) == TYPE_DICTIONARY:
			startup_capital = _non_negative(startup_capital_by_mode.get(mode, 0.0))
		mode_unlocks[mode] = _mode_unlock(mode, population, treasury, unlocked_modes, startup_capital)

	var early_goals: Array[Dictionary] = [
		_passenger_service_goal(metrics),
		_regional_access_goal(metrics),
		_operator_balance_goal(metrics),
	]
	var quality_goals: Array[Dictionary] = [
		_transit_share_goal(metrics),
		_mobility_access_goal(metrics),
		_healthcare_goal(metrics),
	]
	var goals: Array[Dictionary] = []
	goals.append_array(early_goals)
	goals.append_array(quality_goals)

	# A transport mode unlock is a strategic reward, not the first instruction.
	# Prove that the current network works before progression points at tram/metro.
	var next_objective := _next_available_goal(early_goals)
	if next_objective.is_empty():
		next_objective = _next_mode_objective(mode_unlocks)
	if next_objective.is_empty():
		next_objective = _next_available_goal(quality_goals)

	return {
		"mode_unlocks": mode_unlocks,
		"goals": goals,
		"next_objective": next_objective,
	}


static func _mode_unlock(
	mode: String,
	population: int,
	treasury: float,
	unlocked_modes: Variant,
	minimum_startup_capital: float
) -> Dictionary:
	var eligibility := TransitModes.unlock_status(mode, population, treasury, minimum_startup_capital)
	var owned := false
	if typeof(unlocked_modes) == TYPE_DICTIONARY:
		owned = bool(unlocked_modes.get(mode, mode == "bus"))
	var requirements_met := bool(eligibility.get("unlocked", false))
	var status := "locked"
	var feedback := _locked_mode_feedback(mode, eligibility)
	if owned:
		status = "owned"
		feedback = "%s service is available in your network." % mode.capitalize()
	elif requirements_met:
		status = "ready"
		feedback = "%s is ready to unlock." % mode.capitalize()

	var population_remaining := maxi(0, int(eligibility.get("population_remaining", 0)))
	var funds_remaining := _non_negative(eligibility.get("funds_remaining", 0.0))
	return {
		"id": mode,
		"label": mode.capitalize(),
		"status": status,
		"owned": owned,
		"available": owned or requirements_met,
		"requirements_met": requirements_met,
		"population": {
			"current": population,
			"target": int(eligibility.get("population_required", 0)),
			"remaining": population_remaining,
			"met": population_remaining == 0,
		},
		"treasury": {
			"current": treasury,
			"target": float(eligibility.get("unlock_cost", 0.0)),
			"remaining": funds_remaining,
			"met": funds_remaining <= EPSILON,
		},
		"feedback": feedback,
	}


static func _locked_mode_feedback(mode: String, eligibility: Dictionary) -> String:
	var unmet: Array[String] = []
	var population_remaining := maxi(0, int(eligibility.get("population_remaining", 0)))
	var funds_remaining := _non_negative(eligibility.get("funds_remaining", 0.0))
	if population_remaining > 0:
		unmet.append("%s more residents" % _format_integer(population_remaining))
	if funds_remaining > EPSILON:
		unmet.append("$%s more for the licence and a minimum viable line" % _format_integer(roundi(funds_remaining)))
	if unmet.is_empty():
		return "%s is not available yet." % mode.capitalize()
	return "%s needs %s." % [mode.capitalize(), " and ".join(unmet)]


static func _passenger_service_goal(metrics: Dictionary) -> Dictionary:
	var available := metrics.has("lifetime_passengers")
	var passengers := _non_negative(metrics.get("lifetime_passengers", 0.0))
	var complete := available and passengers + EPSILON >= EARLY_PASSENGER_TARGET
	var feedback := "Passenger delivery data is not available yet."
	if available and complete:
		feedback = "Your network has delivered at least %s passengers." % _format_integer(roundi(EARLY_PASSENGER_TARGET))
	elif available:
		feedback = "Deliver %s more passengers to prove the first network works." % _format_integer(roundi(maxf(0.0, EARLY_PASSENGER_TARGET - passengers)))
	return {
		"id": "passenger_service",
		"label": "Prove passenger service",
		"metric": "lifetime_passengers",
		"available": available,
		"complete": complete,
		"value": passengers,
		"target": EARLY_PASSENGER_TARGET,
		"progress": clampf(passengers / EARLY_PASSENGER_TARGET, 0.0, 1.0) if available else 0.0,
		"feedback": feedback,
	}


static func _regional_access_goal(metrics: Dictionary) -> Dictionary:
	var total_pairs := _non_negative(metrics.get("total_od_pairs", 0.0))
	var reachable_pairs := _non_negative(metrics.get("reachable_transit_od_pairs", 0.0))
	var available := total_pairs > EPSILON
	var access_share := clampf(reachable_pairs / total_pairs, 0.0, 1.0) if available else 0.0
	var progress := clampf(access_share / REGIONAL_ACCESS_TARGET, 0.0, 1.0)
	var complete := available and access_share + EPSILON >= REGIONAL_ACCESS_TARGET
	var feedback := "No regional trips are available to measure yet."
	if available and complete:
		feedback = "Transit reaches at least one in four modeled settlement pairs."
	elif available:
		feedback = "Extend a route to reach more settlement pairs by transit."
	return {
		"id": "regional_access",
		"label": "Connect the region",
		"metric": "transit_access_share",
		"available": available,
		"complete": complete,
		"value": access_share,
		"target": REGIONAL_ACCESS_TARGET,
		"progress": progress,
		"feedback": feedback,
	}


static func _operator_balance_goal(metrics: Dictionary) -> Dictionary:
	if metrics.has("current_net_per_minute"):
		var net := _finite(metrics.get("current_net_per_minute", 0.0))
		var revenue := _non_negative(metrics.get("current_revenue_per_minute", 0.0))
		var operating_costs := _non_negative(metrics.get("current_opex_per_minute", 0.0))
		var available := bool(metrics.get("current_cashflow_available", true))
		var progress := 0.0
		if available:
			progress = clampf(revenue / operating_costs, 0.0, 1.0) if operating_costs > EPSILON else (1.0 if net >= 0.0 else 0.0)
		var complete := available and net >= -EPSILON
		var feedback := "Current operating cashflow is not available yet."
		if available and complete:
			feedback = "Current service covers operating costs by $%.1f/min." % maxf(0.0, net)
		elif available:
			feedback = "Current service loses $%.1f/min. Adjust fleet, routes or ridership." % -net
		return {
			"id": "operator_balance",
			"label": "Balance transit operations",
			"metric": "current_operator_net_per_minute",
			"available": available,
			"complete": complete,
			"value": net,
			"target": 0.0,
			"progress": progress,
			"feedback": feedback,
		}

	# Compatibility fallback for callers/saves that do not yet expose Economy V1.
	var revenue := _non_negative(metrics.get("lifetime_revenue", 0.0))
	var operating_costs := _non_negative(metrics.get("lifetime_operating_costs", 0.0))
	var activity := revenue + operating_costs
	var net := revenue - operating_costs
	var available := activity > EPSILON
	var progress := 0.0
	if available:
		progress = clampf(revenue / operating_costs, 0.0, 1.0) if operating_costs > EPSILON else 1.0
	var complete := available and net >= -EPSILON
	var feedback := "Start service to begin tracking fare revenue and operating costs."
	if available and complete:
		feedback = "Fare revenue covers recorded operating costs by $%s." % _format_integer(roundi(maxf(0.0, net)))
	elif available:
		feedback = "Recorded fare revenue is $%s below operating costs." % _format_integer(roundi(-net))
	return {
		"id": "operator_balance",
		"label": "Balance transit operations",
		"metric": "operator_net",
		"available": available,
		"complete": complete,
		"value": net,
		"target": 0.0,
		"progress": progress,
		"feedback": feedback,
	}


static func _transit_share_goal(metrics: Dictionary) -> Dictionary:
	var available := metrics.has("transit_share")
	var share := clampf(_non_negative(metrics.get("transit_share", 0.0)), 0.0, 1.0)
	var complete := available and share + EPSILON >= CURRENT_TRANSIT_SHARE_TARGET
	var feedback := "Mode-share data is not available yet."
	if available and complete:
		feedback = "At least 15% of modeled resident trips use public transport."
	elif available:
		feedback = "Improve frequency, coverage and travel time to grow transit share."
	return {
		"id": "transit_share",
		"label": "Make transit competitive",
		"metric": "transit_share",
		"available": available,
		"complete": complete,
		"value": share,
		"target": CURRENT_TRANSIT_SHARE_TARGET,
		"progress": clampf(share / CURRENT_TRANSIT_SHARE_TARGET, 0.0, 1.0) if available else 0.0,
		"feedback": feedback,
	}


static func _mobility_access_goal(metrics: Dictionary) -> Dictionary:
	var available := metrics.has("average_mobility_accessibility")
	var score := clampf(_non_negative(metrics.get("average_mobility_accessibility", 0.0)), 0.0, 1.0)
	var complete := available and score + EPSILON >= MOBILITY_ACCESS_TARGET
	var feedback := "Regional mobility accessibility is not available yet."
	if available and complete:
		feedback = "Average settlement mobility accessibility is at least 65/100."
	elif available:
		feedback = "Reduce commute times, unserved trips and congestion across settlements."
	return {
		"id": "mobility_access",
		"label": "Improve regional accessibility",
		"metric": "average_mobility_accessibility",
		"available": available,
		"complete": complete,
		"value": score,
		"target": MOBILITY_ACCESS_TARGET,
		"progress": clampf(score / MOBILITY_ACCESS_TARGET, 0.0, 1.0) if available else 0.0,
		"feedback": feedback,
	}


static func _healthcare_goal(metrics: Dictionary) -> Dictionary:
	var coverage := clampf(_non_negative(metrics.get("healthcare_coverage", 0.0)), 0.0, 1.0)
	var available := bool(metrics.get("healthcare_data_available", metrics.has("healthcare_coverage")))
	var progress := clampf(coverage / HEALTHCARE_COVERAGE_TARGET, 0.0, 1.0)
	var complete := available and coverage + EPSILON >= HEALTHCARE_COVERAGE_TARGET
	var feedback := "Healthcare coverage is not available to measure yet."
	if available and complete:
		feedback = "Healthcare services cover at least 95% of modeled demand."
	elif available:
		feedback = "Improve facility coverage by %d percentage points." % roundi(
			maxf(0.0, HEALTHCARE_COVERAGE_TARGET - coverage) * 100.0
		)
	return {
		"id": "healthcare_coverage",
		"label": "Cover local care needs",
		"metric": "healthcare_coverage",
		"available": available,
		"complete": complete,
		"value": coverage,
		"target": HEALTHCARE_COVERAGE_TARGET,
		"progress": progress,
		"feedback": feedback,
	}


static func _next_mode_objective(mode_unlocks: Dictionary) -> Dictionary:
	for mode in NEXT_MODE_ORDER:
		var unlock: Dictionary = mode_unlocks.get(mode, {})
		if bool(unlock.get("owned", false)):
			continue
		return {
			"kind": "infrastructure_unlock",
			"id": mode,
			"label": "Unlock %s service" % mode.capitalize(),
			"complete": bool(unlock.get("owned", false)),
			"ready_to_unlock": bool(unlock.get("available", false)) and not bool(unlock.get("owned", false)),
			"feedback": str(unlock.get("feedback", "")),
		}
	return {}


static func _next_available_goal(goals: Array[Dictionary]) -> Dictionary:
	for goal in goals:
		if bool(goal.get("available", false)) and not bool(goal.get("complete", false)):
			return {
				"kind": "milestone",
				"id": str(goal.get("id", "")),
				"label": str(goal.get("label", "")),
				"complete": false,
				"feedback": str(goal.get("feedback", "")),
			}
	return {}


static func _non_negative(value: Variant) -> float:
	var number := _finite(value)
	return maxf(0.0, number)


static func _finite(value: Variant) -> float:
	if typeof(value) not in [TYPE_FLOAT, TYPE_INT]:
		return 0.0
	var number := float(value)
	return number if is_finite(number) else 0.0


static func _non_negative_int(value: Variant) -> int:
	return mini(2147483647, roundi(_non_negative(value)))


static func _format_integer(value: int) -> String:
	var amount := absi(value)
	var groups: Array[String] = []
	while amount >= 1000:
		groups.push_front("%03d" % (amount % 1000))
		amount /= 1000
	groups.push_front(str(amount))
	var formatted := ",".join(groups)
	return "-%s" % formatted if value < 0 else formatted