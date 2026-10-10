extends SceneTree

const RegionalServicePlanning = preload("res://scripts/simulation/regional_service_planning.gd")

class ServiceStore:
	extends Node
	signal state_changed
	var transit_network: Dictionary = {"lines": {}}
	var fallback_cycle := 0.0
	var save_count := 0
	var purchase_count := 0

	func custom_line_cycle_minutes(_line_id: String) -> float:
		return fallback_cycle

	func save_game() -> void:
		save_count += 1

	func add_vehicle_to_transit_line(line_id: String) -> bool:
		var lines: Dictionary = transit_network.get("lines", {})
		if not lines.has(line_id):
			return false
		var line: Dictionary = lines[line_id]
		var vehicles: Array = line.get("vehicles", [])
		vehicles.append(_vehicle(vehicles.size() + 1))
		line["vehicles"] = vehicles
		line["fleet_count"] = vehicles.size()
		lines[line_id] = line
		transit_network["lines"] = lines
		purchase_count += 1
		return true

	func _vehicle(id: int) -> Dictionary:
		return {
			"id": id,
			"current_stop_index": 0,
			"phase": "dwell",
			"onboard_passengers": 0.0,
		}


var _failures := 0


func _init() -> void:
	_test_default_is_suggestion_not_commitment()
	_test_target_persists_and_replans()
	_test_pending_retirement_is_cancelled_before_purchase()
	_test_impossible_target_reports_fleet_cap()
	_test_target_can_be_cleared()
	if _failures > 0:
		push_error("REGIONAL SERVICE PLANNING TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL SERVICE PLANNING TEST: PASS")
	quit(0)


func _test_default_is_suggestion_not_commitment() -> void:
	var store := _store(2, 42.0)
	var plan := RegionalServicePlanning.service_plan(store, "line-a")
	_expect(bool(plan.get("available", false)), "active custom line exposes a service plan")
	_expect(not bool(plan.get("target_active", true)), "fresh line has no implicit service commitment")
	_expect(is_equal_approx(float(plan.get("suggested_headway_minutes", 0.0)), 15.0), "bus receives a 15 minute planning suggestion")
	_expect(int(plan.get("required_fleet", 0)) == 3, "suggestion still previews the fleet needed for a 42 minute cycle")
	_expect(str(plan.get("status", "")) == "target_not_set", "suggestion does not masquerade as an active target")
	var result := RegionalServicePlanning.apply_one_step(store, "line-a")
	_expect(not bool(result.get("changed", true)), "match-target action does nothing until the player opts in")
	_expect(str(result.get("reason", "")) == "target_not_set", "inactive target failure is explicit")
	_expect(store.purchase_count == 0, "no-target line cannot spend money through match target")
	store.free()


func _test_target_persists_and_replans() -> void:
	var store := _store(3, 42.0)
	_expect(RegionalServicePlanning.set_target_headway(store, "line-a", 10.0), "player can set a valid target headway")
	var line: Dictionary = store.transit_network["lines"]["line-a"]
	_expect(is_equal_approx(float(line.get("target_headway_minutes", 0.0)), 10.0), "target is stored on the line for saves")
	_expect(store.save_count == 1, "changing the service target persists the game")
	var plan := RegionalServicePlanning.service_plan(store, "line-a")
	_expect(bool(plan.get("target_active", false)), "stored target becomes an explicit service commitment")
	_expect(int(plan.get("required_fleet", 0)) == 5, "tighter target recalculates the required fleet")
	_expect(int(plan.get("fleet_gap", 0)) == 2, "replan reports the exact fleet gap")
	store.free()


func _test_pending_retirement_is_cancelled_before_purchase() -> void:
	var store := _store(4, 54.0)
	var line: Dictionary = store.transit_network["lines"]["line-a"]
	var vehicles: Array = line["vehicles"]
	var retiring: Dictionary = vehicles[3]
	retiring["retire_at_terminal"] = true
	vehicles[3] = retiring
	line["vehicles"] = vehicles
	line["target_headway_minutes"] = 15.0
	store.transit_network["lines"]["line-a"] = line
	var before := RegionalServicePlanning.service_plan(store, "line-a")
	_expect(int(before.get("planned_fleet", 0)) == 3, "pending retirement is included in the forward service plan")
	_expect(int(before.get("fleet_gap", 0)) == 1, "retirement would leave the line one vehicle below target")
	var result := RegionalServicePlanning.apply_one_step(store, "line-a")
	_expect(bool(result.get("changed", false)), "match-target step can repair a pending retirement")
	_expect(str(result.get("action", "")) == "cancel_retirement", "cancelling an unnecessary retirement happens before buying another bus")
	_expect(store.purchase_count == 0, "repairing the target does not spend money on a duplicate purchase")
	var after := RegionalServicePlanning.service_plan(store, "line-a")
	_expect(int(after.get("fleet_gap", 99)) == 0, "cancelled retirement restores the target fleet")
	store.free()


func _test_impossible_target_reports_fleet_cap() -> void:
	var store := _store(8, 300.0)
	RegionalServicePlanning.set_target_headway(store, "line-a", 30.0)
	var plan := RegionalServicePlanning.service_plan(store, "line-a")
	_expect(int(plan.get("uncapped_required_fleet", 0)) == 10, "planner keeps the true fleet requirement for diagnostics")
	_expect(int(plan.get("required_fleet", 0)) == 8, "actionable requirement respects the line fleet cap")
	_expect(not bool(plan.get("target_feasible", true)), "unachievable target is explicit rather than silently treated as met")
	store.free()


func _test_target_can_be_cleared() -> void:
	var store := _store(3, 42.0)
	RegionalServicePlanning.set_target_headway(store, "line-a", 10.0)
	_expect(RegionalServicePlanning.clear_target_headway(store, "line-a"), "player can return a line to no-target mode")
	var line: Dictionary = store.transit_network["lines"]["line-a"]
	_expect(not line.has("target_headway_minutes"), "clearing removes the persisted service commitment")
	var plan := RegionalServicePlanning.service_plan(store, "line-a")
	_expect(not bool(plan.get("target_active", true)), "cleared line falls back to suggestion-only planning")
	store.free()


func _store(fleet: int, traffic_cycle: float) -> ServiceStore:
	var store := ServiceStore.new()
	var vehicles: Array = []
	for index in range(fleet):
		vehicles.append(store._vehicle(index + 1))
	store.transit_network = {
		"lines": {
			"line-a": {
				"id": "line-a",
				"source": "custom",
				"status": "active",
				"mode": "bus",
				"fleet_count": fleet,
				"vehicles": vehicles,
				"traffic_effective_cycle_minutes": traffic_cycle,
			},
		},
	}
	store.fallback_cycle = traffic_cycle
	return store


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional service planning: %s" % message)
