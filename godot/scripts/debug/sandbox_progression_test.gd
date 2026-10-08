extends SceneTree

const Progression = preload("res://scripts/city/sandbox_progression.gd")

var _failures := 0


func _initialize() -> void:
	_test_mode_unlock_feedback_uses_existing_rules()
	_test_owned_modes_are_not_relocked_after_spending()
	_test_optional_goals_measure_access_health_and_balance()
	_test_missing_and_malformed_metrics_are_safe()
	if _failures == 0:
		print("SandboxProgression: PASS")
		quit(0)
	else:
		push_error("SandboxProgression: %d failure(s)" % _failures)
		quit(1)


func _test_mode_unlock_feedback_uses_existing_rules() -> void:
	var metrics := {
		"resident_count": 12500,
		"public_treasury": 5000.0,
		"unlocked_modes": {"bus": true},
	}
	var result := Progression.evaluate(metrics)
	var tram: Dictionary = result["mode_unlocks"]["tram"]
	_expect(tram.get("status") == "locked", "tram is locked until its existing thresholds are met")
	_expect(int(tram["population"]["remaining"]) == 12500, "tram reports its remaining resident requirement")
	_expect(is_equal_approx(float(tram["treasury"]["remaining"]), 11000.0), "tram reports its remaining treasury requirement")
	_expect(str(tram.get("feedback", "")).contains("12,500") and str(tram.get("feedback", "")).contains("$11,000"), "tram feedback names both unmet requirements")
	_expect(result["next_objective"].get("id") == "tram", "the next objective points to the first unowned mode")

	var ready := Progression.evaluate({
		"resident_count": 25000,
		"public_treasury": 16000.0,
		"unlocked_modes": {"bus": true},
	})
	_expect(ready["mode_unlocks"]["tram"].get("status") == "ready", "tram reports ready at the existing threshold")
	_expect(bool(ready["next_objective"].get("ready_to_unlock", false)), "a ready unlock is surfaced as the next action")
	_expect(not bool(ready["next_objective"].get("complete", true)), "an available but unpurchased mode is not marked complete")
	var licence_only := Progression.evaluate({
		"resident_count": 25000,
		"public_treasury": 16000.0,
		"unlocked_modes": {"bus": true},
		"minimum_startup_capital_by_mode": {"tram": 80000.0},
	})
	_expect(licence_only["mode_unlocks"]["tram"].get("status") == "locked", "progression waits for funds to licence and build a minimal line")
	_expect(float(licence_only["mode_unlocks"]["tram"]["treasury"]["target"]) == 80000.0, "progression exposes the full minimum startup capital target")
	_expect(str(licence_only["mode_unlocks"]["tram"].get("feedback", "")).contains("64,000"), "progression reports the remaining startup capital")
	var metro_ready := Progression.evaluate({"resident_count": 80000, "public_treasury": 150000.0})
	_expect(metro_ready["mode_unlocks"]["metro"].get("status") == "ready", "metro readiness follows its existing population and treasury thresholds")


func _test_owned_modes_are_not_relocked_after_spending() -> void:
	var result := Progression.evaluate({
		"resident_count": 25000,
		"public_treasury": 100.0,
		"unlocked_modes": {"bus": true, "tram": true},
	})
	_expect(result["mode_unlocks"]["tram"].get("status") == "owned", "an already-owned mode stays available after its unlock cost is spent")
	_expect(result["next_objective"].get("id") == "metro", "progression advances to metro after tram is owned")


func _test_optional_goals_measure_access_health_and_balance() -> void:
	var input := {
		"resident_count": 80000,
		"public_treasury": 150000.0,
		"unlocked_modes": {"bus": true, "tram": true, "metro": true},
		"reachable_transit_od_pairs": 2,
		"total_od_pairs": 8,
		"healthcare_coverage": 0.95,
		"healthcare_data_available": true,
		"lifetime_revenue": 12000.0,
		"lifetime_operating_costs": 10000.0,
	}
	var snapshot := input.duplicate(true)
	var result := Progression.evaluate(input)
	var goals: Array = result["goals"]
	var access: Dictionary = _goal_by_id(goals, "regional_access")
	var balance: Dictionary = _goal_by_id(goals, "operator_balance")
	var healthcare: Dictionary = _goal_by_id(goals, "healthcare_coverage")
	_expect(access.get("available", false), "regional accessibility is measured when OD pairs exist")
	_expect(bool(access.get("complete", false)), "one quarter accessibility completes the 25% goal")
	_expect(is_equal_approx(float(access.get("progress", 0.0)), 1.0), "the 25% accessibility threshold completes at one quarter")
	_expect(bool(balance.get("complete", false)), "recorded fare revenue covering operating costs completes the finance goal")
	_expect(str(balance.get("feedback", "")).contains("$2,000"), "finance feedback reports the positive operating margin")
	_expect(bool(healthcare.get("complete", false)), "95% healthcare coverage completes the service goal")
	_expect(input == snapshot, "evaluating progression leaves caller metrics unchanged")

	var short_access := Progression.evaluate({
		"unlocked_modes": {"bus": true, "tram": true, "metro": true},
		"reachable_transit_od_pairs": 1,
		"total_od_pairs": 8,
		"lifetime_revenue": 8000.0,
		"lifetime_operating_costs": 10000.0,
		"healthcare_coverage": 0.3,
	})
	var short_access_goals: Array = short_access["goals"]
	_expect(str(short_access["next_objective"].get("id", "")) == "regional_access", "when modes are owned, the next available optional milestone is surfaced")
	_expect(str(_goal_by_id(short_access_goals, "operator_balance").get("feedback", "")).contains("$2,000 below"), "finance feedback explains the shortfall")
	_expect(str(_goal_by_id(short_access_goals, "healthcare_coverage").get("feedback", "")).contains("65 percentage points"), "service feedback reports the remaining coverage")


func _test_missing_and_malformed_metrics_are_safe() -> void:
	var no_data := Progression.evaluate({
		"resident_count": -1,
		"public_treasury": "unknown",
		"healthcare_coverage": -2.0,
		"healthcare_data_available": false,
		"reachable_transit_od_pairs": -3,
		"total_od_pairs": 0,
	})
	var goals: Array = no_data["goals"]
	_expect(not _goal_by_id(goals, "regional_access").get("available", true), "accessibility is unavailable when the region has no modeled trip pairs")
	_expect(not _goal_by_id(goals, "healthcare_coverage").get("available", true), "healthcare is unavailable when its source metric is unavailable")
	_expect(not _goal_by_id(goals, "operator_balance").get("available", true), "the balance objective waits until service has recorded operations")
	_expect(int(no_data["mode_unlocks"]["tram"]["population"]["current"]) == 0, "invalid population inputs are safely clamped")
	_expect(float(no_data["mode_unlocks"]["tram"]["treasury"]["current"]) == 0.0, "invalid treasury inputs are safely clamped")


func _goal_by_id(goals: Array, goal_id: String) -> Dictionary:
	for goal_value in goals:
		if typeof(goal_value) == TYPE_DICTIONARY and str(goal_value.get("id", "")) == goal_id:
			return goal_value
	return {}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("SandboxProgression: %s" % message)
