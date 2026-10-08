extends SceneTree

const GameStoreScript = preload("res://scripts/core/game_store.gd")

var failures := 0


func _initialize() -> void:
	var store = GameStoreScript.new()
	store.suppress_persistence = true
	store.reset_state(false)
	_test_facility_construction_changes_coverage_and_health_trend(store)
	_test_player_facility_upkeep_is_charged(store)
	_test_unknown_and_covered_services_are_rejected(store)
	store.free()
	if failures == 0:
		print("Regional service GameStore tests: PASS")
		quit(0)
	else:
		push_error("Regional service GameStore tests: %d failure(s)" % failures)
		quit(1)


func _test_facility_construction_changes_coverage_and_health_trend(store: Node) -> void:
	var settlement: Dictionary = store.city.get("regional_settlements", [])[0]
	var settlement_id := str(settlement.get("id", ""))
	var before: Dictionary = store.resident_health_metrics()
	var before_district: Dictionary = before.get("districts", {}).get(settlement_id, {})
	var initial_coverage := float(before_district.get("healthcare_coverage", 1.0))
	var status: Dictionary = store.regional_service_build_status(settlement_id, "healthcare")
	_expect(initial_coverage < 0.95, "starter clinics leave a visible service capacity gap")
	_expect(bool(status.get("available", false)), "a clinic can be funded from the starter treasury")
	var money_before := float(store.money)
	var capacity_before := (store.city.get("service_buildings", []) as Array).size()
	_expect(store.build_regional_service(settlement_id, "healthcare"), "player can build a clinic in a selected settlement")
	var after: Dictionary = store.resident_health_metrics()
	var after_district: Dictionary = after.get("districts", {}).get(settlement_id, {})
	_expect(float(after_district.get("healthcare_coverage", 0.0)) > initial_coverage, "clinic capacity increases local healthcare coverage")
	_expect(float(after.get("annual_health_trend", -999.0)) > float(before.get("annual_health_trend", 999.0)), "care coverage improves the long-term cohort health trend")
	_expect((store.city.get("service_buildings", []) as Array).size() == capacity_before + 1, "the player facility is saved in city state")
	_expect(is_equal_approx(float(store.money), money_before - float(status.get("cost", 0.0))), "clinic construction deducts its published cost")
	var player_facility: Dictionary = (store.city.get("service_buildings", []) as Array)[-1]
	_expect(str(player_facility.get("source", "")) == "player", "player service records retain ownership provenance")


func _test_player_facility_upkeep_is_charged(store: Node) -> void:
	var costs_before := float(store.stats.get("lifetime_operating_costs", 0.0))
	var treasury_before := float(store.money)
	store._accrue_sandbox_operating_costs(10.0)
	var costs_after := float(store.stats.get("lifetime_operating_costs", 0.0))
	_expect(costs_after > costs_before, "operating public facilities adds to lifetime service costs")
	_expect(float(store.money) < treasury_before, "operating public facilities reduces the treasury")


func _test_unknown_and_covered_services_are_rejected(store: Node) -> void:
	var settlement_id := str(store.city.get("regional_settlements", [])[0].get("id", ""))
	var unknown: Dictionary = store.regional_service_build_status(settlement_id, "spaceship_port")
	_expect(not bool(unknown.get("available", true)), "unknown service types are rejected")
	var covered: Dictionary = store.regional_service_build_status(settlement_id, "healthcare")
	_expect(not bool(covered.get("available", true)), "a fully served district cannot spend on unnecessary duplicate facilities")


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	failures += 1
	push_error("Regional service GameStore: %s" % description)
