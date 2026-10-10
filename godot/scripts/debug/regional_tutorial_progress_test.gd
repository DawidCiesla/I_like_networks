extends SceneTree

const RegionalTutorialProgress = preload("res://scripts/ui/regional_tutorial_progress.gd")

var _failures := 0


func _init() -> void:
	_test_player_road_detection()
	_test_operating_line_detection()
	_test_passenger_target()
	if _failures > 0:
		push_error("REGIONAL TUTORIAL PROGRESS TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL TUTORIAL PROGRESS TEST: PASS")
	quit(0)


func _test_player_road_detection() -> void:
	var city := {
		"roads": [
			{"id": "historic", "source": "regional-existing", "status": "built"},
			{"id": "planned", "source": "player", "status": "planned"},
		],
	}
	_expect(not RegionalTutorialProgress.has_player_road(city), "historic or merely planned roads do not complete the first tutorial step")
	city["roads"].append({"id": "player-built", "source": "player", "status": "built"})
	_expect(RegionalTutorialProgress.has_player_road(city), "completed player-funded road completes the first tutorial step")


func _test_operating_line_detection() -> void:
	var network := {
		"lines": {
			"inactive": {"source": "custom", "status": "active", "fleet_count": 0, "stop_ids": ["a", "b"]},
			"short": {"source": "custom", "status": "active", "fleet_count": 1, "stop_ids": ["a"]},
		},
	}
	_expect(not RegionalTutorialProgress.has_operating_line(network), "line needs both a vehicle and at least two stops")
	network["lines"]["ready"] = {"source": "custom", "status": "active", "fleet_count": 1, "stop_ids": ["a", "b"]}
	_expect(RegionalTutorialProgress.has_operating_line(network), "active custom service with fleet and two stops completes service step")


func _test_passenger_target() -> void:
	_expect(not RegionalTutorialProgress.passenger_target_met({"lifetime_passengers": 24.9}), "tutorial does not complete before measurable passenger target")
	_expect(RegionalTutorialProgress.passenger_target_met({"lifetime_passengers": 25.0}), "25 delivered passengers complete the tutorial")
	var progress := RegionalTutorialProgress.passenger_progress({"lifetime_passengers": 12.5})
	_expect(is_equal_approx(float(progress.get("progress", 0.0)), 0.5), "passenger progress is exposed for the tutorial UI")


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional tutorial progress: %s" % message)
