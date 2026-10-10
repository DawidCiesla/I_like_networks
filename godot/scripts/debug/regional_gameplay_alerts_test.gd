extends SceneTree

const RegionalGameplayAlerts = preload("res://scripts/ui/regional_gameplay_alerts.gd")

var _failures := 0


func _init() -> void:
	_test_worst_road_and_line_alerts()
	_test_healthy_network_has_no_alerts()
	if _failures > 0:
		push_error("REGIONAL GAMEPLAY ALERTS TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL GAMEPLAY ALERTS TEST: PASS")
	quit(0)


func _test_worst_road_and_line_alerts() -> void:
	var city := {
		"roads": [
			{"id": "road-a", "traffic": {"vc_ratio": 0.91, "delay_minutes": 1.2, "flow_vph": 1400.0, "capacity_vph": 1600.0}},
			{"id": "road-b", "traffic": {"vc_ratio": 1.24, "delay_minutes": 4.8, "flow_vph": 2200.0, "capacity_vph": 1800.0}},
		],
	}
	var network := {
		"lines": {
			"line-a": {
				"name": "Airport Bus",
				"operations_health": {
					"status": "congestion_limited",
					"severity": 3,
					"headway_minutes": 14.0,
					"effective_load_ratio": 0.72,
					"traffic_delay_factor": 1.8,
					"recommended_action": "use_priority_or_separate_right_of_way",
				},
			},
		},
	}
	var alerts := RegionalGameplayAlerts.collect_alerts(city, network)
	_expect(alerts.size() == 2, "fixture produces one road and one line alert")
	if alerts.size() >= 2:
		_expect(str(alerts[0].get("id", "")) == "road:road-b", "highest V/C road becomes the road alert")
		_expect(str(alerts[0].get("selection", "")) == "regional_road:road-b", "road alert targets the existing road inspector")
		_expect(str(alerts[1].get("id", "")) == "line:line-a", "line-health issue becomes an actionable line alert")
		_expect(str(alerts[1].get("selection", "")) == "free_line:line-a", "line alert targets the existing custom-line inspector")


func _test_healthy_network_has_no_alerts() -> void:
	var city := {"roads": [{"id": "road-a", "traffic": {"vc_ratio": 0.55, "delay_minutes": 0.1}}]}
	var network := {
		"lines": {
			"line-a": {
				"operations_health": {"status": "healthy", "severity": 0},
			},
		},
	}
	_expect(RegionalGameplayAlerts.collect_alerts(city, network).is_empty(), "healthy road and line network stays quiet")


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional gameplay alerts: %s" % message)
