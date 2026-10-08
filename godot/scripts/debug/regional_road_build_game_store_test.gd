extends SceneTree

const GameStoreScript = preload("res://scripts/core/game_store.gd")

var _failures := 0


func _initialize() -> void:
	var store = GameStoreScript.new()
	store.suppress_persistence = true
	store.reset_state(false)
	_test_historic_regional_network_is_already_built(store)
	store.free()
	if _failures == 0:
		print("Regional historic-road GameStore tests: PASS")
		quit(0)
	else:
		push_error("Regional historic-road GameStore tests: %d failure(s)" % _failures)
		quit(1)


func _test_historic_regional_network_is_already_built(store) -> void:
	var regional_road_count := 0
	var sample_road_id := ""
	for road_value in store.city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("source", "")) != "regional-existing":
			continue
		regional_road_count += 1
		if sample_road_id.is_empty():
			sample_road_id = str(road.get("id", ""))
		_expect(str(road.get("status", "")) == "built", "historic regional roads are built before gameplay starts")
		_expect(is_equal_approx(float(road.get("constructionProgress", 0.0)), 1.0), "historic roads have complete construction progress")

	_expect(regional_road_count > 0, "fresh regional map contains an existing historic road network")
	if sample_road_id.is_empty():
		return

	var funds_before := float(store.money)
	var status: Dictionary = store.regional_road_build_status(sample_road_id)
	_expect(not bool(status.get("available", false)), "an already-existing road is not offered as a new construction project")
	_expect(not store.build_regional_road(sample_road_id), "an already-existing historic road cannot be purchased again")
	_expect(is_equal_approx(float(store.money), funds_before), "rejecting an already-built historic road does not charge the player")


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional historic-road GameStore: %s" % description)
