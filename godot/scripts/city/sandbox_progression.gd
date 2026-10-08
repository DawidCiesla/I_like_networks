extends RefCounted
class_name SandboxProgression

## Optional regional-sandbox objectives and infrastructure readiness.
##
## `evaluate` accepts the public aggregate metrics already exposed by
## GameStore/HUD: resident_count, public_treasury, reachable_transit_od_pairs,
## total_od_pairs, healthcare_coverage, healthcare_data_available,
## lifetime_revenue, lifetime_operating_costs, and optional unlocked_modes.
## It does not own or mutate simulation state. Tram/metro eligibility is
## delegated to TransitModes so their existing unlock rules remain canonical.

const TransitModes = preload("res://scripts/transport/transit_modes.gd")

const NEXT_MODE_ORDER := ["tram", "metro"]
const REGIONAL_ACCESS_TARGET := 0.25
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

	var goals: Array[Dictionary] = [
		_regional_access_goal(metrics),
		_operator_balance_goal(metrics),
		_healthcare_goal(metrics),
	]
	var next_objective := _next_mode_objective(mode_unlocks)
	if next_objective.is_empty():
		next_objective = _next_available_goal(goals)

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
		feedback = "Fare revenue covers operating costs by $%s." % _format_integer(roundi(maxf(0.0, net)))
	elif available:
		feedback = "Fare revenue is $%s below operating costs." % _format_integer(roundi(-net))
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
	if typeof(value) not in [TYPE_FLOAT, TYPE_INT]:
		return 0.0
	var number := float(value)
	return maxf(0.0, number) if is_finite(number) else 0.0


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
