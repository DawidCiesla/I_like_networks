extends SceneTree

const Progression = preload("res://scripts/city/sandbox_progression.gd")

var _failures := 0


func _initialize() -> void:
	_test_mode_unlock_rules_are_preserved()
	_test_beginning_chain_uses_real_gameplay_metrics()
	_test_mid_and_late_chain_order()
	_test_accessibility_availability_and_input_immutability()
	if _failures == 0:
		print("SandboxProgression: PASS")
		quit(0)
	else:
		push_error("SandboxProgression: %d failure(s)" % _failures)
		quit(1)


func _test_mode_unlock_rules_are_preserved() -> void:
	var locked := Progression.evaluate({
		"resident_count": 12500,
		"public_treasury": 5000.0,
		"unlocked_modes": {"bus": true},
	})
	var tram: Dictionary = locked["mode_unlocks"]["tram"]
	_expect(tram.get("status") == "locked", "tram stays locked until the existing thresholds are met")
	_expect(int(tram["population"]["remaining"]) == 12500, "tram reports the remaining population requirement")
	_expect(is_equal_approx(float(tram["treasury"]["remaining"]), 11000.0), "tram reports the remaining treasury requirement")
	_expect(str(tram.get("feedback", "")).contains("12500") and str(tram.get("feedback", "")).contains("$11000"), "tram feedback names both unmet requirements")

	var ready_metrics := _early_complete_metrics()
	ready_metrics["resident_count"] = 25000
	ready_metrics["public_treasury"] = 16000.0
	var ready := Progression.evaluate(ready_metrics)
	_expect(ready["mode_unlocks"]["tram"].get("status") == "ready", "tram is ready at the existing threshold")
	_expect(str(ready["next_objective"].get("id", "")) == "unlock_tram", "the tram unlock becomes the next milestone only after earlier gameplay goals")
	_expect(not bool(ready["next_objective"].get("complete", true)), "a ready but unowned tram mode is not marked complete")

	ready_metrics["minimum_startup_capital_by_mode"] = {"tram": 80000.0}
	var startup_limited := Progression.evaluate(ready_metrics)
	_expect(startup_limited["mode_unlocks"]["tram"].get("status") == "locked", "minimum startup capital can keep tram locked")
	_expect(is_equal_approx(float(startup_limited["mode_unlocks"]["tram"]["treasury"]["target"]), 80000.0), "progression exposes the full minimum startup capital target")
	_expect(str(startup_limited["mode_unlocks"]["tram"].get("feedback", "")).contains("$64000"), "progression reports remaining startup capital")

	var owned_metrics := _early_complete_metrics()
	owned_metrics["resident_count"] = 25000
	owned_metrics["public_treasury"] = 100.0
	owned_metrics["unlocked_modes"] = {"bus": true, "tram": true}
	var owned := Progression.evaluate(owned_metrics)
	_expect(owned["mode_unlocks"]["tram"].get("status") == "owned", "an already-owned tram mode is not relocked after spending")


func _test_beginning_chain_uses_real_gameplay_metrics() -> void:
	var metrics := _base_metrics()
	var result := Progression.evaluate(metrics)
	_expect(_next_id(result) == "first_connection", "the sandbox starts by asking for a player road connection")

	metrics["player_built_road_count"] = 1
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "first_depot", "a completed road advances to the depot milestone")

	metrics["depot_built"] = true
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "first_line", "a built depot advances to the first custom line")

	metrics["custom_active_line_count"] = 1
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "first_vehicle", "an active line advances to a real in-service vehicle milestone")

	metrics["active_custom_fleet"] = 1
	metrics["lifetime_passengers"] = 40.0
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "passengers_100", "the first vehicle advances to the 100-passenger milestone")
	_expect(is_equal_approx(float(_goal_by_id(result["goals"], "passengers_100").get("progress", 0.0)), 0.4), "passenger progress is deterministic against the 100-passenger target")

	metrics["lifetime_passengers"] = 100.0
	metrics["served_settlement_count"] = 2
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "serve_three_settlements", "100 passengers advances to serving three settlements")

	metrics["served_settlement_count"] = 3
	metrics["transit_share"] = 0.05
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "transit_share_10", "three served settlements advance to the 10 percent transit-share goal")
	_expect(is_equal_approx(float(_goal_by_id(result["goals"], "transit_share_10").get("progress", 0.0)), 0.5), "transit-share progress reflects the live share")

	metrics["transit_share"] = 0.10
	metrics["current_net_per_minute"] = -2.0
	metrics["current_revenue_per_minute"] = 4.0
	metrics["current_opex_per_minute"] = 6.0
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "positive_operations", "the player must reach positive live operating cashflow before strategic growth")
	_expect(not bool(_goal_by_id(result["goals"], "positive_operations").get("complete", true)), "historic revenue cannot hide a current operating loss")

	metrics["current_net_per_minute"] = 1.0
	metrics["current_revenue_per_minute"] = 7.0
	metrics["current_opex_per_minute"] = 6.0
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "resolve_congestion", "positive operations advance to resolving the first congestion problem")

	metrics["resolved_first_congestion"] = true
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "population_25k", "resolving congestion advances to the first population milestone")


func _test_mid_and_late_chain_order() -> void:
	var metrics := _early_complete_metrics()
	metrics["resident_count"] = 25000
	metrics["public_treasury"] = 200000.0

	var result := Progression.evaluate(metrics)
	_expect(_next_id(result) == "unlock_tram", "25k residents reveal the tram unlock milestone")

	metrics["unlocked_modes"] = {"bus": true, "tram": true}
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "serve_high_demand", "owning tram advances to serving a high-demand corridor")

	metrics["high_demand_corridor_served"] = true
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "first_tram", "high-demand service advances to the first tram line")

	metrics["active_tram_line_count"] = 1
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "severe_congestion", "the first tram line advances to the severe-congestion milestone")

	metrics["had_severe_congestion"] = true
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "first_bypass", "severe congestion reveals the traffic-driven bypass milestone")

	metrics["first_bypass_built"] = true
	metrics["average_mobility_accessibility"] = 0.50
	metrics["mobility_accessibility_available"] = true
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "regional_accessibility", "a completed bypass advances to the real accessibility target")
	_expect(is_equal_approx(float(_goal_by_id(result["goals"], "regional_accessibility").get("progress", 0.0)), 0.50 / 0.65), "accessibility progress uses the 65/100 target")

	metrics["average_mobility_accessibility"] = 0.65
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "population_80k", "65/100 accessibility advances to the 80k population milestone")

	metrics["resident_count"] = 80000
	result = Progression.evaluate(metrics)
	_expect(_next_id(result) == "unlock_metro", "80k residents reveal the metro unlock milestone")

	metrics["unlocked_modes"] = {"bus": true, "tram": true, "metro": true}
	result = Progression.evaluate(metrics)
	_expect((result["next_objective"] as Dictionary).is_empty(), "the chain is complete after metro is owned")


func _test_accessibility_availability_and_input_immutability() -> void:
	var metrics := _early_complete_metrics()
	metrics["resident_count"] = 80000
	metrics["public_treasury"] = 200000.0
	metrics["unlocked_modes"] = {"bus": true, "tram": true}
	metrics["high_demand_corridor_served"] = true
	metrics["active_tram_line_count"] = 1
	metrics["had_severe_congestion"] = true
	metrics["first_bypass_built"] = true
	metrics["average_mobility_accessibility"] = 0.0
	metrics["mobility_accessibility_available"] = false
	var before := metrics.duplicate(true)
	var result := Progression.evaluate(metrics)
	var accessibility := _goal_by_id(result["goals"], "regional_accessibility")
	_expect(not bool(accessibility.get("available", true)), "accessibility remains unavailable until the runtime has a real snapshot")
	_expect(_next_id(result) == "unlock_metro", "an unavailable diagnostic does not block a later measurable milestone on an old save")
	_expect(metrics == before, "evaluating progression never mutates caller metrics")


func _base_metrics() -> Dictionary:
	return {
		"resident_count": 10000,
		"public_treasury": 25000.0,
		"unlocked_modes": {"bus": true},
		"player_built_road_count": 0,
		"depot_built": false,
		"custom_active_line_count": 0,
		"active_custom_fleet": 0,
		"lifetime_passengers": 0.0,
		"served_settlement_count": 0,
		"transit_share": 0.0,
		"current_cashflow_available": true,
		"current_net_per_minute": 0.0,
		"current_revenue_per_minute": 0.0,
		"current_opex_per_minute": 0.0,
		"resolved_first_congestion": false,
		"high_demand_corridor_served": false,
		"active_tram_line_count": 0,
		"had_severe_congestion": false,
		"first_bypass_built": false,
		"average_mobility_accessibility": 0.0,
		"mobility_accessibility_available": false,
	}


func _early_complete_metrics() -> Dictionary:
	var metrics := _base_metrics()
	metrics["player_built_road_count"] = 1
	metrics["depot_built"] = true
	metrics["custom_active_line_count"] = 1
	metrics["active_custom_fleet"] = 1
	metrics["lifetime_passengers"] = 100.0
	metrics["served_settlement_count"] = 3
	metrics["transit_share"] = 0.10
	metrics["current_net_per_minute"] = 1.0
	metrics["current_revenue_per_minute"] = 7.0
	metrics["current_opex_per_minute"] = 6.0
	metrics["resolved_first_congestion"] = true
	return metrics


func _next_id(result: Dictionary) -> String:
	var value: Variant = result.get("next_objective", {})
	return str((value as Dictionary).get("id", "")) if typeof(value) == TYPE_DICTIONARY else ""


func _goal_by_id(goals: Array, goal_id: String) -> Dictionary:
	for goal_value in goals:
		if typeof(goal_value) == TYPE_DICTIONARY and str((goal_value as Dictionary).get("id", "")) == goal_id:
			return goal_value
	return {}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("SandboxProgression: %s" % message)
