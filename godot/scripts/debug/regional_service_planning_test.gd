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
	_test_traffic_cycle_drives_required_fleet()
	_test_target_persists_and_replans()
	_test_pending_retirement_is_cancelled_before_purchase()
	_test_impossible_target_reports_fleet_cap()
	if _failures > 0:
		push_error("REGIONAL SERVICE PLANNING TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL SERVICE PLANNING TEST: PASS")
	quit(0)


func _test_traffic_cycle_drives_required_fleet() -> void:
	var store := _store(2, 42.0)
	var plan := RegionalServicePlanning.service_plan(store, "line-a")
	_expect(bool(plan.get("available", false)), "active custom line exposes a service plan")
	_expect(is_equal_approx(float(plan.get("target_headway_minutes", 0.0)), 15.0), "bus defaults to a 15 minute target")
	_expect(int(plan.get("required_fleet", 0)) == 3, "42 minute congested cycle requires three buses for a 15 minute target")
	_expect(int(plan.get("fleet_gap", 0)) == 1, "service plan exposes one missing vehicle")
	_expect(str(plan.get("status", "")) == "increase_service", "missing fleet is classified as an increase-service action")
	store.free()


func _test_target_persists_and_replans() -> void:
	var store := _store(3, 42.0)
	_expect(RegionalServicePlanning.set_target_headway(store, "line-a", 10.0), "player can set a valid target headway")
	var line: Dictionary = store.transit_network["lines"]["line-a"]
	_expect(is_equal_approx(float(line.get("target_headway_minutes", 0.0)), 10.0), "target is stored on the line for saves")
	_expect(store.save_count == 1, "changing the service target persists the game")
	var plan := RegionalServicePlanning.service_plan(store, "line-a")
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
