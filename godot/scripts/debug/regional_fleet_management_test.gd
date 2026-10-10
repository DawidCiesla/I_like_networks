extends SceneTree

const RegionalFleetManagement = preload("res://scripts/simulation/regional_fleet_management.gd")

class FleetStore:
	extends Node
	var transit_network: Dictionary = {}


var _failures := 0


func _init() -> void:
	_test_schedule_prefers_safe_candidate()
	_test_retirement_waits_for_empty_terminal()
	_test_minimum_service_fleet_is_preserved()
	_test_cancel_retirement()
	if _failures > 0:
		push_error("REGIONAL FLEET MANAGEMENT TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL FLEET MANAGEMENT TEST: PASS")
	quit(0)


func _test_schedule_prefers_safe_candidate() -> void:
	var store := _store()
	_expect(RegionalFleetManagement.schedule_retirement(store, "line-a"), "a multi-vehicle custom line can schedule one retirement")
	var line := _line(store)
	var flagged_ids: Array[int] = []
	for vehicle_value in line.get("vehicles", []):
		var vehicle: Dictionary = vehicle_value
		if bool(vehicle.get("retire_at_terminal", false)):
			flagged_ids.append(int(vehicle.get("id", -1)))
	_expect(flagged_ids == [2], "scheduler prefers the empty non-travelling vehicle over loaded/in-motion vehicles")
	_expect(int(line.get("pending_retirements", 0)) == 1, "line exposes pending retirement count")
	store.free()


func _test_retirement_waits_for_empty_terminal() -> void:
	var store := _store()
	RegionalFleetManagement.schedule_retirement(store, "line-a")
	var line := _line(store)
	var vehicles: Array = line.get("vehicles", [])
	for index in range(vehicles.size()):
		var vehicle: Dictionary = vehicles[index]
		if int(vehicle.get("id", 0)) == 2:
			vehicle["current_stop_index"] = 1
			vehicles[index] = vehicle
	line["vehicles"] = vehicles
	_set_line(store, line)
	_expect(RegionalFleetManagement.process_retirements(store) == 0, "scheduled vehicle is not removed from an intermediate stop")
	_expect(int(_line(store).get("fleet_count", 0)) == 3, "fleet remains intact until the scheduled vehicle reaches a terminus")

	line = _line(store)
	vehicles = line.get("vehicles", [])
	for index in range(vehicles.size()):
		var vehicle: Dictionary = vehicles[index]
		if int(vehicle.get("id", 0)) == 2:
			vehicle["current_stop_index"] = 2
			vehicle["phase"] = "dwell"
			vehicle["onboard_passengers"] = 0.0
			vehicles[index] = vehicle
	line["vehicles"] = vehicles
	_set_line(store, line)
	_expect(RegionalFleetManagement.process_retirements(store) == 1, "empty scheduled vehicle retires at the terminal")
	_expect(int(_line(store).get("fleet_count", 0)) == 2, "retirement reduces actual fleet count and garage usage source data")
	_expect(int(_line(store).get("pending_retirements", -1)) == 0, "completed retirement clears pending count")
	store.free()


func _test_minimum_service_fleet_is_preserved() -> void:
	var store := _store()
	var line := _line(store)
	line["vehicles"] = [line["vehicles"][0]]
	line["fleet_count"] = 1
	_set_line(store, line)
	var status := RegionalFleetManagement.retirement_status(store, "line-a")
	_expect(not bool(status.get("available", true)), "last service vehicle cannot be scheduled for retirement")
	_expect(str(status.get("reason", "")) == "minimum_service_fleet", "minimum fleet rejection has an actionable reason")
	_expect(not RegionalFleetManagement.schedule_retirement(store, "line-a"), "scheduler refuses to reduce an active line to zero vehicles")
	store.free()


func _test_cancel_retirement() -> void:
	var store := _store()
	RegionalFleetManagement.schedule_retirement(store, "line-a")
	_expect(RegionalFleetManagement.cancel_retirements(store, "line-a"), "pending retirements can be cancelled")
	_expect(RegionalFleetManagement.pending_retirements(_line(store)) == 0, "cancel clears all retirement flags")
	_expect(not RegionalFleetManagement.cancel_retirements(store, "line-a"), "cancelling again is a no-op")
	store.free()


func _store() -> FleetStore:
	var store := FleetStore.new()
	store.transit_network = {
		"stops": {
			"s0": {"id": "s0", "status": "built"},
			"s1": {"id": "s1", "status": "built"},
			"s2": {"id": "s2", "status": "built"},
		},
		"lines": {
			"line-a": {
				"id": "line-a",
				"source": "custom",
				"status": "active",
				"stop_ids": ["s0", "s1", "s2"],
				"fleet_count": 3,
				"vehicles": [
					{"id": 1, "phase": "travel", "current_stop_index": 0, "onboard_passengers": 0.0},
					{"id": 2, "phase": "dwell", "current_stop_index": 0, "onboard_passengers": 0.0},
					{"id": 3, "phase": "dwell", "current_stop_index": 1, "onboard_passengers": 14.0},
				],
			},
		},
	}
	return store


func _line(store: FleetStore) -> Dictionary:
	return store.transit_network.get("lines", {}).get("line-a", {}).duplicate(true)


func _set_line(store: FleetStore, line: Dictionary) -> void:
	var lines: Dictionary = store.transit_network.get("lines", {})
	lines["line-a"] = line
	store.transit_network["lines"] = lines


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional fleet management: %s" % message)
