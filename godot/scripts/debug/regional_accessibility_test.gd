extends SceneTree

const RegionalAccessibility = preload("res://scripts/city/regional_accessibility.gd")

var _failures := 0


func _init() -> void:
	_test_good_access_scores_above_poor_access()
	_test_congestion_reduces_reliability()
	_test_missing_metrics_stay_explicit()
	if _failures > 0:
		push_error("REGIONAL ACCESSIBILITY TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL ACCESSIBILITY TEST: PASS")
	quit(0)


func _test_good_access_scores_above_poor_access() -> void:
	var city := _city()
	var metrics := {
		"districts": {
			"good": {
				"average_commute_minutes": 18.0,
				"unserved_share": 0.02,
				"transit_share": 0.32,
				"car_share": 0.66,
			},
			"poor": {
				"average_commute_minutes": 49.0,
				"unserved_share": 0.24,
				"transit_share": 0.03,
				"car_share": 0.73,
			},
		},
	}
	var scores := RegionalAccessibility.evaluate(city, metrics)
	var good: Dictionary = scores.get("good", {})
	var poor: Dictionary = scores.get("poor", {})
	_expect(bool(good.get("available", false)), "district transport metrics produce an available score")
	_expect(float(good.get("score", 0.0)) > float(poor.get("score", 1.0)), "short commutes, service, and useful transit score above poor access")
	_expect(float(good.get("score", 0.0)) > 0.75, "strong access produces a high normalized score")
	_expect(float(poor.get("score", 1.0)) < 0.55, "poor access remains visibly below the development-friendly range")


func _test_congestion_reduces_reliability() -> void:
	var city := _city()
	var metrics := {
		"districts": {
			"good": {
				"average_commute_minutes": 25.0,
				"unserved_share": 0.05,
				"transit_share": 0.15,
				"car_share": 0.80,
			},
			"poor": {
				"average_commute_minutes": 25.0,
				"unserved_share": 0.05,
				"transit_share": 0.15,
				"car_share": 0.80,
			},
		},
	}
	var scores := RegionalAccessibility.evaluate(city, metrics)
	var uncongested: Dictionary = scores.get("good", {})
	var congested: Dictionary = scores.get("poor", {})
	_expect(float(uncongested.get("road_reliability_score", 0.0)) > float(congested.get("road_reliability_score", 1.0)), "local V/C feeds a separate road reliability component")
	_expect(float(uncongested.get("score", 0.0)) > float(congested.get("score", 1.0)), "otherwise equal settlement loses accessibility when its corridor is over capacity")
	_expect(float(congested.get("local_max_vc_ratio", 0.0)) > 1.0, "diagnostics expose the severe local V/C value")


func _test_missing_metrics_stay_explicit() -> void:
	var result := RegionalAccessibility.evaluate(_city(), {"districts": {}})
	for settlement_id in ["good", "poor"]:
		var row: Dictionary = result.get(settlement_id, {})
		_expect(not bool(row.get("available", true)), "missing resident metrics do not fabricate accessibility for %s" % settlement_id)
		_expect(str(row.get("reason", "")) == "transport_metrics_unavailable", "missing-data reason remains explicit")


func _city() -> Dictionary:
	return {
		"regional_settlements": [
			{"id": "good", "position": Vector2(0.0, 0.0), "built_up_radius_m": 420.0},
			{"id": "poor", "position": Vector2(4000.0, 0.0), "built_up_radius_m": 420.0},
		],
		"roads": [
			{
				"id": "good-road",
				"a": "good",
				"b": "outside-a",
				"status": "built",
				"points": [Vector2(0.0, 0.0), Vector2(900.0, 0.0)],
				"traffic": {"vc_ratio": 0.52, "delay_minutes": 0.2},
			},
			{
				"id": "poor-road",
				"a": "poor",
				"b": "outside-b",
				"status": "built",
				"points": [Vector2(4000.0, 0.0), Vector2(4900.0, 0.0)],
				"traffic": {"vc_ratio": 1.28, "delay_minutes": 5.8},
			},
		],
	}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional accessibility: %s" % message)
