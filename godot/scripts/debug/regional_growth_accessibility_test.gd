extends SceneTree

const RegionalGrowthSystem = preload("res://scripts/city/regional_growth_system.gd")

class GrowthStore:
	extends Node
	var city: Dictionary = {}
	var transit_network: Dictionary = {}


var _failures := 0


func _init() -> void:
	_test_missing_snapshot_preserves_legacy_pressure()
	_test_high_accessibility_increases_growth_pressure()
	_test_low_accessibility_can_reduce_proxy_optimism()
	if _failures > 0:
		push_error("REGIONAL GROWTH ACCESSIBILITY TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL GROWTH ACCESSIBILITY TEST: PASS")
	quit(0)


func _test_missing_snapshot_preserves_legacy_pressure() -> void:
	var store := _store()
	var settlement: Dictionary = store.city["regional_settlements"][0]
	var components := RegionalGrowthSystem._growth_pressure_components(store, settlement)
	var expected := 0.07 + 0.30 + 1000.0 / 50000.0
	_expect(str(components.get("source", "")) == "legacy_proxy", "missing accessibility snapshot keeps legacy source")
	_expect(is_equal_approx(float(components.get("legacy_mobility_pressure", 0.0)), 0.30), "legacy player-link contribution remains unchanged")
	_expect(is_equal_approx(float(components.get("pressure", 0.0)), expected), "fallback growth pressure is numerically identical to the old formula")
	store.free()


func _test_high_accessibility_increases_growth_pressure() -> void:
	var store := _store()
	store.city["regional_accessibility"] = {
		"settlements": {
			"s": {"available": true, "score": 0.90},
		},
	}
	var settlement: Dictionary = store.city["regional_settlements"][0]
	var components := RegionalGrowthSystem._growth_pressure_components(store, settlement)
	_expect(str(components.get("source", "")) == "blended_real_accessibility", "available real metrics switch growth to blended source")
	_expect(is_equal_approx(float(components.get("accessibility_score", 0.0)), 0.90), "growth consumes canonical accessibility score")
	_expect(float(components.get("real_mobility_pressure", 0.0)) > float(components.get("legacy_mobility_pressure", 0.0)), "excellent actual mobility can outperform a simple road-count proxy")
	_expect(float(components.get("pressure", 0.0)) > 0.58, "strong real access can cross the organic expansion pressure threshold")
	store.free()


func _test_low_accessibility_can_reduce_proxy_optimism() -> void:
	var store := _store()
	store.city["regional_accessibility"] = {
		"settlements": {
			"s": {"available": true, "score": 0.20},
		},
	}
	var settlement: Dictionary = store.city["regional_settlements"][0]
	var components := RegionalGrowthSystem._growth_pressure_components(store, settlement)
	_expect(float(components.get("real_mobility_pressure", 1.0)) < float(components.get("legacy_mobility_pressure", 0.0)), "poor real travel outcomes reduce optimism from merely having a player road")
	_expect(float(components.get("mobility_pressure", 0.0)) < float(components.get("legacy_mobility_pressure", 0.0)), "55 percent blend already lets poor access slow development")
	_expect(float(components.get("pressure", 1.0)) < 0.58, "poor access keeps the same settlement below expansion pressure")
	store.free()


func _store() -> GrowthStore:
	var store := GrowthStore.new()
	store.city = {
		"regional_settlements": [{
			"id": "s",
			"position": Vector2.ZERO,
			"population": 1000,
			"built_up_radius_m": 400.0,
		}],
		"roads": [{
			"id": "player-link",
			"a": "s",
			"b": "outside",
			"source": "player",
			"status": "built",
			"class": "collector",
			"points": [Vector2.ZERO, Vector2(900.0, 0.0)],
		}],
	}
	store.transit_network = {}
	return store


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional growth accessibility: %s" % message)
