extends SceneTree

const GameStoreScript = preload("res://scripts/core/game_store.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")

var failures := 0


func _initialize() -> void:
	var store = GameStoreScript.new()
	store.suppress_persistence = true
	store.city_seed = 814273
	store.reset_state(false)
	store.transit_network = _network_fixture(store)
	store._resident_transport_snapshot_cache.clear()

	store._generate_resident_transport_demand(1.0)
	var lines: Dictionary = store.transit_network.get("lines", {})
	var bus_ratio := float(lines["custom-line-1"].get("crowding_ratio", -1.0))
	var tram_ratio := float(lines["custom-line-2"].get("crowding_ratio", -1.0))
	var metro_ratio := float(lines["custom-line-3"].get("crowding_ratio", -1.0))
	_expect(is_equal_approx(bus_ratio, 0.9 - 1.0 / 24.0), "bus occupancy uses its 40-passenger profile and retains decaying queue pressure")
	_expect(is_equal_approx(tram_ratio, 30.0 / 180.0), "tram occupancy uses its 180-passenger profile")
	_expect(is_equal_approx(metro_ratio, 30.0 / 600.0), "metro occupancy uses its 600-passenger profile")
	for line_id_value in TransitNetwork.custom_line_ids(store.transit_network):
		var ratio := float(store.transit_network["lines"][str(line_id_value)].get("crowding_ratio", -1.0))
		_expect(ratio >= 0.0 and ratio <= 1.0, "%s crowding stays bounded to 0..1" % str(line_id_value))

	var updated_lines: Dictionary = store.transit_network.get("lines", {})
	var overloaded_bus: Dictionary = updated_lines["custom-line-4"]
	var vehicles: Array = overloaded_bus.get("vehicles", [])
	vehicles[0]["onboard_passengers"] = 120.0
	overloaded_bus["vehicles"] = vehicles
	updated_lines["custom-line-4"] = overloaded_bus
	store.transit_network["lines"] = updated_lines
	store._generate_resident_transport_demand(1.0)
	var clamped_ratio := float(store.transit_network["lines"]["custom-line-4"].get("crowding_ratio", -1.0))
	_expect(is_equal_approx(clamped_ratio, 1.0), "vehicle occupancy above profile capacity clamps crowding to 1")

	store.free()
	if failures == 0:
		print("Transit crowding GameStore test: PASS")
		quit(0)
	else:
		push_error("Transit crowding GameStore test: %d failure(s)" % failures)
		quit(1)


func _network_fixture(store) -> Dictionary:
	var stops: Dictionary = {}
	var lines: Dictionary = {}
	var fixture_modes := ["bus", "tram", "metro", "bus"]
	for index in range(fixture_modes.size()):
		var line_id := "custom-line-%d" % (index + 1)
		var first_stop_id := "custom-stop-%d" % (index * 2 + 1)
		var second_stop_id := "custom-stop-%d" % (index * 2 + 2)
		var first_position := Vector2(100000.0 + index * 2000.0, 100000.0)
		var second_position := first_position + Vector2(900.0, 0.0)
		stops[first_stop_id] = _stop(first_stop_id, first_position, line_id)
		stops[second_stop_id] = _stop(second_stop_id, second_position, line_id)
		var prior_queue_pressure := 0.9 if index == 0 else 0.0
		lines[line_id] = {
			"id": line_id,
			"name": "%s test line" % fixture_modes[index],
			"source": "custom",
			"mode": fixture_modes[index],
			"status": "active",
			"stop_ids": [first_stop_id, second_stop_id],
			"planned_stop_ids": [first_stop_id, second_stop_id],
			"route_segments": [{"from_stop_id": first_stop_id, "to_stop_id": second_stop_id, "length_world": 900.0}],
			"route_length_world": 900.0,
			"fleet_count": 1,
			"vehicles": [{
				"id": 1,
				"current_stop_index": 0,
				"next_stop_index": 1,
				"direction": 1,
				"phase": "dwell",
				"phase_minutes_remaining": 5.0,
				"onboard_by_destination": [0.0, 30.0],
				"onboard_passengers": 30.0,
			}],
			"next_vehicle_id": 2,
			"waiting_by_stop": store._create_waiting_matrix(2),
			"queue_passengers": 0.0,
			"crowding_ratio": prior_queue_pressure,
		}
	return {
		"schema_version": 2,
		"source": "free_lines",
		"next_stop_serial": stops.size() + 1,
		"next_line_serial": lines.size() + 1,
		"unlocked_modes": {"bus": true, "tram": true, "metro": true},
		"stops": stops,
		"lines": lines,
	}


func _stop(stop_id: String, position: Vector2, line_id: String) -> Dictionary:
	return {
		"id": stop_id,
		"x": position.x,
		"y": position.y,
		"source": "custom",
		"status": "built",
		"served_line_ids": [line_id],
	}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error("Transit crowding check failed: %s" % message)
