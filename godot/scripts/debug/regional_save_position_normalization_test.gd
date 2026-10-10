extends SceneTree

const CityRuntime = preload("res://scripts/city/city_runtime.gd")

var _failures := 0


func _initialize() -> void:
	_test_saved_vector2_variants()
	_test_regional_settlement_positions_are_normalized()
	if _failures == 0:
		print("Regional save position normalization: PASS")
		quit(0)
	else:
		push_error("Regional save position normalization: %d failure(s)" % _failures)
		quit(1)


func _test_saved_vector2_variants() -> void:
	_expect(CityRuntime._saved_vector2(Vector2(1.5, -2.25)) == Vector2(1.5, -2.25), "keeps native Vector2 values")
	_expect(CityRuntime._saved_vector2({"x": 3.0, "y": 4.5}) == Vector2(3.0, 4.5), "reads dictionary positions")
	_expect(CityRuntime._saved_vector2([5.25, -6.75]) == Vector2(5.25, -6.75), "reads array positions")
	_expect(CityRuntime._saved_vector2("(123.4, -56.7)") == Vector2(123.4, -56.7), "reads Godot JSON Vector2 text")
	_expect(CityRuntime._saved_vector2("Vector2(8.5, 9.25)") == Vector2(8.5, 9.25), "reads explicit Vector2 text")
	_expect(CityRuntime._saved_vector2("invalid", Vector2(7.0, 8.0)) == Vector2(7.0, 8.0), "falls back safely for malformed positions")


func _test_regional_settlement_positions_are_normalized() -> void:
	var city := {
		"world_map_id": "regional-save-regression",
		"regional_settlements": [
			{"id": "a", "position": "(100.0, -200.0)"},
			{"id": "b", "position": {"x": 300.0, "y": 400.0}},
			{"id": "c", "position": [500.0, 600.0]},
			{"id": "d", "position": "bad", "x": 700.0, "y": 800.0},
		],
	}
	CityRuntime._normalize_regional_settlement_positions(city)
	var settlements: Array = city["regional_settlements"]
	for settlement_value in settlements:
		_expect((settlement_value as Dictionary).get("position") is Vector2, "normalizer always leaves regional position typed as Vector2")
	_expect((settlements[0] as Dictionary)["position"] == Vector2(100.0, -200.0), "text position keeps coordinates")
	_expect((settlements[1] as Dictionary)["position"] == Vector2(300.0, 400.0), "dictionary position keeps coordinates")
	_expect((settlements[2] as Dictionary)["position"] == Vector2(500.0, 600.0), "array position keeps coordinates")
	_expect((settlements[3] as Dictionary)["position"] == Vector2(700.0, 800.0), "malformed position falls back to settlement x/y")


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional save position normalization: %s" % message)
