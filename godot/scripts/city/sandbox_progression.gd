extends RefCounted
class_name SandboxProgression

## Pure-data sandbox progression. The runtime supplies canonical simulation
## metrics; this module only turns them into an ordered, measurable milestone
## chain and infrastructure-readiness diagnostics.

const TransitModes = preload("res://scripts/transport/transit_modes.gd")

const NEXT_MODE_ORDER := ["tram", "metro"]
const PASSENGER_TARGET := 100.0
const SERVED_SETTLEMENT_TARGET := 3.0
const TRANSIT_SHARE_TARGET := 0.10
const MID_POPULATION_TARGET := 25000.0
const LATE_POPULATION_TARGET := 80000.0
const ACCESSIBILITY_TARGET := 0.65
const EPSILON := 0.000001


static func evaluate(metrics: Dictionary) -> Dictionary:
	var population := maxi(0, int(metrics.get("resident_count", 0)))
	var treasury := float(metrics.get("public_treasury", 0.0))
	var unlocked_modes: Variant = metrics.get("unlocked_modes", {"bus": true})
	var startup_capital_by_mode: Variant = metrics.get("minimum_startup_capital_by_mode", {})
	var mode_unlocks: Dictionary = {}
	for mode in NEXT_MODE_ORDER:
		var startup_capital := 0.0
		if typeof(startup_capital_by_mode) == TYPE_DICTIONARY:
			startup_capital = maxf(0.0, float((startup_capital_by_mode as Dictionary).get(mode, 0.0)))
		mode_unlocks[mode] = _mode_unlock(mode, population, treasury, unlocked_modes, startup_capital)

	var goals: Array = [
		_count_goal("first_connection", "Connect two places", "player_built_road_count", metrics, 1.0, "Build one player-funded road connection."),
		_bool_goal("first_depot", "Build a depot", "depot_built", metrics, "Place the first operating depot."),
		_count_goal("first_line", "Create the first line", "custom_active_line_count", metrics, 1.0, "Create an active custom passenger line."),
		_count_goal("first_vehicle", "Put the first vehicle in service", "active_custom_fleet", metrics, 1.0, "Operate at least one vehicle on a custom line."),
		_count_goal("passengers_100", "Carry 100 passengers", "lifetime_passengers", metrics, PASSENGER_TARGET, "Let the network carry 100 passengers."),
		_count_goal("serve_three_settlements", "Serve 3 settlements", "served_settlement_count", metrics, SERVED_SETTLEMENT_TARGET, "Extend useful transit service to three settlements."),
		_ratio_goal("transit_share_10", "Reach 10% transit share", "transit_share", metrics, TRANSIT_SHARE_TARGET, "Make transit competitive enough to reach 10% mode share."),
		_positive_goal("positive_operations", "Reach positive operating cashflow", "current_net_per_minute", metrics, "Bring current fare revenue above operating costs."),
		_bool_goal("resolve_congestion", "Resolve the first congestion problem", "resolved_first_congestion", metrics, "Let a corridor become congested, then reduce its peak V/C below the recovery threshold."),
		_count_goal("population_25k", "Grow to 25,000 residents", "resident_count", metrics, MID_POPULATION_TARGET, "Grow the region to 25,000 residents."),
		_owned_mode_goal("unlock_tram", "Unlock tram", "tram", mode_unlocks),
		_bool_goal("serve_high_demand", "Serve a high-demand corridor", "high_demand_corridor_served", metrics, "Operate useful capacity on a corridor with sustained passenger demand."),
		_count_goal("first_tram", "Build the first tram line", "active_tram_line_count", metrics, 1.0, "Open an active custom tram line."),
		_bool_goal("severe_congestion", "Encounter severe corridor congestion", "had_severe_congestion", metrics, "Regional growth should eventually create a corridor above the severe V/C threshold."),
		_bool_goal("first_bypass", "Build the first bypass", "first_bypass_built", metrics, "Approve and complete a traffic-driven regional relief corridor."),
		_ratio_goal("regional_accessibility", "Raise regional accessibility", "average_mobility_accessibility", metrics, ACCESSIBILITY_TARGET, "Reduce travel time, unserved trips and congestion until accessibility reaches 65/100."),
		_count_goal("population_80k", "Grow to 80,000 residents", "resident_count", metrics, LATE_POPULATION_TARGET, "Grow the regional population to 80,000 residents."),
		_owned_mode_goal("unlock_metro", "Unlock metro", "metro", mode_unlocks),
	]
	return {
		"mode_unlocks": mode_unlocks,
		"goals": goals,
		"next_objective": _next_goal(goals),
	}


static func _count_goal(id: String, label: String, metric: String, metrics: Dictionary, target: float, guidance: String) -> Dictionary:
	var available := metrics.has(metric)
	var value := maxf(0.0, float(metrics.get(metric, 0.0)))
	var complete := available and value + EPSILON >= target
	return _goal(id, label, metric, available, complete, value, target, clampf(value / maxf(EPSILON, target), 0.0, 1.0), _feedback(complete, label, guidance))


static func _ratio_goal(id: String, label: String, metric: String, metrics: Dictionary, target: float, guidance: String) -> Dictionary:
	var available := metrics.has(metric)
	if metric == "average_mobility_accessibility":
		available = bool(metrics.get("mobility_accessibility_available", available))
	var value := clampf(float(metrics.get(metric, 0.0)), 0.0, 1.0)
	var complete := available and value + EPSILON >= target
	return _goal(id, label, metric, available, complete, value, target, clampf(value / target, 0.0, 1.0), _feedback(complete, label, guidance))


static func _positive_goal(id: String, label: String, metric: String, metrics: Dictionary, guidance: String) -> Dictionary:
	var available := bool(metrics.get("current_cashflow_available", metrics.has(metric)))
	var value := float(metrics.get(metric, 0.0))
	var complete := available and value > EPSILON
	var progress := 1.0 if complete else 0.0
	if available and not complete:
		var revenue := maxf(0.0, float(metrics.get("current_revenue_per_minute", 0.0)))
		var cost := maxf(0.0, float(metrics.get("current_opex_per_minute", 0.0)))
		progress = clampf(revenue / cost, 0.0, 1.0) if cost > EPSILON else 0.0
	return _goal(id, label, metric, available, complete, value, 0.0, progress, _feedback(complete, label, guidance))


static func _bool_goal(id: String, label: String, metric: String, metrics: Dictionary, guidance: String) -> Dictionary:
	var available := metrics.has(metric)
	var complete := available and bool(metrics.get(metric, false))
	return _goal(id, label, metric, available, complete, 1.0 if complete else 0.0, 1.0, 1.0 if complete else 0.0, _feedback(complete, label, guidance))


static func _owned_mode_goal(id: String, label: String, mode: String, mode_unlocks: Dictionary) -> Dictionary:
	var unlock_value: Variant = mode_unlocks.get(mode, {})
	var unlock: Dictionary = unlock_value if typeof(unlock_value) == TYPE_DICTIONARY else {}
	var owned := bool(unlock.get("owned", false))
	var feedback := "%s complete." % label if owned else str(unlock.get("feedback", "Meet the infrastructure requirements first."))
	return _goal(id, label, "mode_%s" % mode, not unlock.is_empty(), owned, 1.0 if owned else 0.0, 1.0, 1.0 if owned else 0.0, feedback)


static func _goal(id: String, label: String, metric: String, available: bool, complete: bool, value: float, target: float, progress: float, feedback: String) -> Dictionary:
	return {
		"id": id,
		"label": label,
		"metric": metric,
		"available": available,
		"complete": complete,
		"value": value,
		"target": target,
		"progress": clampf(progress, 0.0, 1.0),
		"feedback": feedback,
	}


static func _feedback(complete: bool, label: String, guidance: String) -> String:
	return "%s complete." % label if complete else guidance


static func _next_goal(goals: Array) -> Dictionary:
	for goal_value in goals:
		if typeof(goal_value) != TYPE_DICTIONARY:
			continue
		var goal: Dictionary = goal_value
		if bool(goal.get("available", false)) and not bool(goal.get("complete", false)):
			var result := goal.duplicate(true)
			result["kind"] = "milestone"
			return result
	return {}


static func _mode_unlock(mode: String, population: int, treasury: float, unlocked_modes: Variant, minimum_startup_capital: float) -> Dictionary:
	var eligibility := TransitModes.unlock_status(mode, population, treasury, minimum_startup_capital)
	var owned := false
	if typeof(unlocked_modes) == TYPE_DICTIONARY:
		owned = bool((unlocked_modes as Dictionary).get(mode, mode == "bus"))
	var ready := bool(eligibility.get("unlocked", false))
	var population_remaining := maxi(0, int(eligibility.get("population_remaining", 0)))
	var funds_remaining := maxf(0.0, float(eligibility.get("funds_remaining", 0.0)))
	var unmet: Array[String] = []
	if population_remaining > 0:
		unmet.append("%d more residents" % population_remaining)
	if funds_remaining > EPSILON:
		unmet.append("$%d more startup capital" % roundi(funds_remaining))
	var feedback := "%s service is available." % mode.capitalize() if owned else ("%s is ready to unlock." % mode.capitalize() if ready else "%s needs %s." % [mode.capitalize(), " and ".join(unmet)])
	return {
		"id": mode,
		"label": mode.capitalize(),
		"status": "owned" if owned else ("ready" if ready else "locked"),
		"owned": owned,
		"available": owned or ready,
		"requirements_met": ready,
		"population": {"current": population, "target": int(eligibility.get("population_required", 0)), "remaining": population_remaining, "met": population_remaining == 0},
		"treasury": {"current": treasury, "target": float(eligibility.get("unlock_cost", 0.0)), "remaining": funds_remaining, "met": funds_remaining <= EPSILON},
		"feedback": feedback,
	}
