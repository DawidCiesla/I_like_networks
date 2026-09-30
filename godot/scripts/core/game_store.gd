extends Node

signal state_changed
signal city_changed
signal selection_changed(selection: String)
signal toast_requested(message: String)

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const CityRuntime = preload("res://scripts/city/city_runtime.gd")

const SAVE_PATH := "user://save_godot_v2.json"

var money: float = 0.0
var elapsed_seconds: float = 0.0
var simulation_speed: int = 1
var city_seed: int = Data.DEFAULT_CITY_SEED
var selected: String = ""

var lines: Dictionary = {}
var stations: Dictionary = {}
var depot: Dictionary = {}
var stats: Dictionary = {}
var city: Dictionary = {}

var _autosave_timer := 0.0
var _fare_changed_this_frame := false
var suppress_persistence := false

func _ready() -> void:
	reset_state(false)
	load_game()

func _process(delta: float) -> void:
	if simulation_speed > 0:
		_fare_changed_this_frame = false
		var city_did_change := _advance_simulation(delta)
		if _fare_changed_this_frame:
			state_changed.emit()
		if city_did_change:
			city_changed.emit()

	_autosave_timer += delta
	if _autosave_timer >= 12.0:
		_autosave_timer = 0.0
		if not suppress_persistence:
			save_game()

func _create_waiting_matrix(max_stops: int) -> Array:
	var result: Array = []
	for _index in range(max_stops):
		var row: Array = []
		row.resize(max_stops)
		row.fill(0.0)
		result.append(row)
	return result

func _new_line_state(line_key: String) -> Dictionary:
	var max_stops := int(Data.LINE_CONFIG[line_key]["max_stops"])
	return {
		"built": false,
		"stop_count": 1 if line_key == "line1" else 0,
		"fleet_count": 0,
		"demand_per_stop_ppm": float(Data.LINE_CONFIG[line_key]["demand_per_stop_ppm"]),
		"waiting_by_stop": _create_waiting_matrix(max_stops),
		"queue_passengers": 0.0,
		"current_abandonment_ppm": 0.0,
		"total_abandoned_passengers": 0.0,
		"last_delivered_ppm": 0.0,
		"vehicles": [],
		"next_vehicle_id": 1,
		"event_serial": 0,
		"last_passenger_event": null,
		"passenger_events": [],
	}

func reset_state(emit_signal: bool = true) -> void:
	money = float(Data.ECONOMY["starting_money"])
	elapsed_seconds = 0.0
	simulation_speed = 1
	city_seed = Data.DEFAULT_CITY_SEED
	selected = ""

	lines = {}
	for line_key in Data.LINE_KEYS:
		lines[line_key] = _new_line_state(line_key)

	stations = {}
	for station_id in Data.all_station_ids():
		stations[station_id] = {"level": 0}

	depot = {
		"built": false,
		"garage_slots": 4,
		"level": 0,
	}

	city = CityRuntime.create_initial_city(city_seed)

	stats = {
		"lifetime_revenue": 0.0,
		"lifetime_passengers": 0.0,
		"last_fare_event_value": 0.0,
		"last_fare_event_serial": 0,
		"last_fare_line": "",
		"last_fare_stop_index": -1,
	}

	if emit_signal:
		state_changed.emit()
		selection_changed.emit(selected)

func set_speed(speed: int) -> void:
	if speed not in [0, 1, 2, 4]:
		return
	simulation_speed = speed
	state_changed.emit()

func set_selection(value: String) -> void:
	selected = value
	selection_changed.emit(selected)

func station_level(station_id: String) -> int:
	var station: Dictionary = stations.get(station_id, {"level": 0})
	return int(station.get("level", 0))

func station_tier(station_id: String) -> String:
	return str(Data.STATION_UPGRADE["tier_names"][station_level(station_id)])

func station_upgrade_cost(station_id: String) -> int:
	var level := station_level(station_id)
	return roundi(
		float(Data.STATION_UPGRADE["base_cost"])
		* pow(float(Data.STATION_UPGRADE["cost_growth"]), level)
	)

func station_capacity(station_id: String) -> int:
	return int(Data.STATION_UPGRADE["waiting_capacity"][station_level(station_id)])

func station_is_built(station_id: String) -> bool:
	if station_id == "old-town":
		return true

	for line_key in Data.LINE_KEYS:
		var index := Data.STATION_IDS[line_key].find(station_id)
		if index < 0:
			continue

		var line: Dictionary = lines[line_key]
		if line_key == "line1":
			if index < int(line["stop_count"]):
				return true
		elif bool(line["built"]) and index < int(line["stop_count"]):
			return true

	return false

func station_served_lines(station_id: String) -> Array[String]:
	var result: Array[String] = []
	for line_key in Data.LINE_KEYS:
		var line: Dictionary = lines[line_key]
		if not bool(line["built"]):
			continue
		var index := Data.STATION_IDS[line_key].find(station_id)
		if index >= 0 and index < int(line["stop_count"]):
			result.append(line_key)
	return result

func station_waiting_passengers(station_id: String) -> float:
	var total := 0.0
	for line_key in Data.LINE_KEYS:
		var line: Dictionary = lines[line_key]
		if not bool(line["built"]):
			continue
		var stop_index := Data.STATION_IDS[line_key].find(station_id)
		if stop_index >= 0 and stop_index < int(line["stop_count"]):
			total += stop_waiting_passengers(line_key, stop_index)
	return total

func stop_demand(line_key: String, stop_index: int) -> float:
	var line: Dictionary = lines[line_key]
	var station_id: String = Data.STATION_IDS[line_key][stop_index]
	return (
		float(line["demand_per_stop_ppm"])
		+ float(Data.STATION_UPGRADE["demand_bonus"][station_level(station_id)])
	)

func line_demand(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	if not bool(line["built"]) or int(line["stop_count"]) < 2:
		return 0.0
	var total := 0.0
	for stop_index in range(int(line["stop_count"])):
		total += stop_demand(line_key, stop_index)
	return total

func line_route_length_km(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	var segment_count := max(0, int(line["stop_count"]) - 1)
	var lengths: Array = Data.LINE_CONFIG[line_key]["segment_lengths_km"]
	var total := 0.0
	for index in range(segment_count):
		total += float(lengths[index])
	return total

func _base_stop_dwell_minutes(line_key: String, stop_index: int) -> float:
	var station_id: String = Data.STATION_IDS[line_key][stop_index]
	var reduction := float(Data.STATION_UPGRADE["dwell_reduction"][station_level(station_id)])
	return max(0.12, float(Data.BUS["dwell_minutes"]) - reduction)

func _stop_dwell_minutes(line_key: String, stop_index: int) -> float:
	var line: Dictionary = lines[line_key]
	var is_endpoint := stop_index == 0 or stop_index == int(line["stop_count"]) - 1
	return (
		_base_stop_dwell_minutes(line_key, stop_index)
		+ (float(Data.BUS["turnaround_minutes"]) / 2.0 if is_endpoint else 0.0)
	)

func _segment_travel_minutes(line_key: String, from_stop: int, to_stop: int) -> float:
	var segment_index := mini(from_stop, to_stop)
	var lengths: Array = Data.LINE_CONFIG[line_key]["segment_lengths_km"]
	var length_km := float(lengths[segment_index])
	return length_km / float(Data.BUS["speed_kph"]) * 60.0

func line_cycle_minutes(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	if not bool(line["built"]) or int(line["stop_count"]) < 2:
		return 0.0

	var driving := line_route_length_km(line_key) / float(Data.BUS["speed_kph"]) * 60.0 * 2.0
	var dwell := 0.0

	for stop_index in range(int(line["stop_count"])):
		var visits := 1 if stop_index == 0 or stop_index == int(line["stop_count"]) - 1 else 2
		dwell += _base_stop_dwell_minutes(line_key, stop_index) * float(visits)

	return driving + dwell + float(Data.BUS["turnaround_minutes"])

func line_headway_minutes(line_key: String) -> float:
	var fleet := int(lines[line_key]["fleet_count"])
	if fleet <= 0:
		return INF
	return line_cycle_minutes(line_key) / float(fleet)

func line_capacity_ppm(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	var fleet := int(line["fleet_count"])
	if not bool(line["built"]) or fleet <= 0:
		return 0.0
	var cycle := line_cycle_minutes(line_key)
	if cycle <= 0.0:
		return 0.0
	return float(Data.BUS["capacity"]) * float(fleet) * 2.0 / cycle

func line_is_stable(line_key: String) -> bool:
	return bool(lines[line_key]["built"]) and line_capacity_ppm(line_key) >= line_demand(line_key)

func stop_waiting_passengers(line_key: String, stop_index: int) -> float:
	var line: Dictionary = lines[line_key]
	var matrix: Array = line["waiting_by_stop"]
	if stop_index < 0 or stop_index >= matrix.size():
		return 0.0

	var row: Array = matrix[stop_index]
	var total := 0.0
	for destination in range(mini(row.size(), int(line["stop_count"]))):
		total += max(0.0, float(row[destination]))
	return total

func line_waiting_passengers(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	var total := 0.0
	for stop_index in range(int(line["stop_count"])):
		total += stop_waiting_passengers(line_key, stop_index)
	return total

func line_onboard_passengers(line_key: String) -> float:
	var total := 0.0
	var line: Dictionary = lines[line_key]
	for vehicle in line["vehicles"]:
		total += float(vehicle.get("onboard_passengers", 0.0))
	return total

func garage_used() -> int:
	var total := 0
	for line_key in Data.LINE_KEYS:
		total += int(lines[line_key]["fleet_count"])
	return total

func vehicle_purchase_cost() -> int:
	var built_lines := 0
	for line_key in Data.LINE_KEYS:
		if bool(lines[line_key]["built"]):
			built_lines += 1
	var purchased := max(0, garage_used() - built_lines)
	return roundi(
		float(Data.ECONOMY["bus_base_cost"])
		* pow(float(Data.ECONOMY["bus_cost_growth"]), purchased)
	)

func next_stop_cost(line_key: String) -> int:
	var line: Dictionary = lines[line_key]
	var config := {
		"line1": [Data.ECONOMY["line1_stop_base_cost"], Data.ECONOMY["line1_stop_cost_growth"], 1],
		"line2": [Data.ECONOMY["line2_stop_base_cost"], Data.ECONOMY["line2_stop_cost_growth"], 2],
		"line3": [Data.ECONOMY["line3_stop_base_cost"], Data.ECONOMY["line3_stop_cost_growth"], 2],
		"line4": [Data.ECONOMY["line4_stop_base_cost"], Data.ECONOMY["line4_stop_cost_growth"], 2],
	}[line_key]
	var purchased := max(0, int(line["stop_count"]) - int(config[2]))
	return roundi(float(config[0]) * pow(float(config[1]), purchased))

func can_build_depot() -> bool:
	return not bool(depot["built"]) and int(lines["line1"]["stop_count"]) >= 3

func _has_free_garage_slot() -> bool:
	return garage_used() < int(depot["garage_slots"])

func can_unlock_line(line_key: String) -> bool:
	if line_key == "line1":
		return true
	var previous_index := Data.LINE_KEYS.find(line_key) - 1
	if previous_index < 0:
		return false
	var previous_key: String = Data.LINE_KEYS[previous_index]
	var previous_line: Dictionary = lines[previous_key]
	return (
		not bool(lines[line_key]["built"])
		and bool(depot["built"])
		and int(previous_line["stop_count"]) >= int(Data.LINE_CONFIG[previous_key]["max_stops"])
		and line_is_stable(previous_key)
		and _has_free_garage_slot()
	)

func line_build_cost(line_key: String) -> int:
	match line_key:
		"line2":
			return int(Data.ECONOMY["line2_build_cost"])
		"line3":
			return int(Data.ECONOMY["line3_build_cost"])
		"line4":
			return int(Data.ECONOMY["line4_build_cost"])
		_:
			return 0

func _create_vehicle(line_key: String) -> Dictionary:
	var line: Dictionary = lines[line_key]
	var max_stops := int(Data.LINE_CONFIG[line_key]["max_stops"])
	var vehicle_id := int(line["next_vehicle_id"])
	line["next_vehicle_id"] = vehicle_id + 1

	var onboard: Array = []
	onboard.resize(max_stops)
	onboard.fill(0.0)

	var dwell := _stop_dwell_minutes(line_key, 0)
	return {
		"id": vehicle_id,
		"current_stop_index": 0,
		"next_stop_index": mini(1, int(line["stop_count"]) - 1),
		"direction": 1,
		"phase": "dwell",
		"phase_minutes_remaining": dwell,
		"phase_duration_minutes": dwell,
		"onboard_by_destination": onboard,
		"onboard_passengers": 0.0,
	}

func _initialize_line_service(line_key: String, fleet_count: int = 1) -> void:
	var line: Dictionary = lines[line_key]
	line["built"] = true
	line["vehicles"] = []
	line["fleet_count"] = 0
	line["next_vehicle_id"] = 1
	lines[line_key] = line

	for _index in range(fleet_count):
		_add_vehicle_to_line_state(line_key)

func _add_vehicle_to_line_state(line_key: String) -> Dictionary:
	var line: Dictionary = lines[line_key]
	var vehicle := _create_vehicle(line_key)
	var vehicles: Array = line["vehicles"]
	vehicles.append(vehicle)
	line["vehicles"] = vehicles
	line["fleet_count"] = vehicles.size()
	lines[line_key] = line
	return vehicle

func _ensure_line_runtime(line_key: String) -> void:
	var line: Dictionary = lines[line_key]
	var max_stops := int(Data.LINE_CONFIG[line_key]["max_stops"])

	if not line.has("waiting_by_stop"):
		line["waiting_by_stop"] = _create_waiting_matrix(max_stops)

	var matrix: Array = line["waiting_by_stop"]
	while matrix.size() < max_stops:
		var row: Array = []
		row.resize(max_stops)
		row.fill(0.0)
		matrix.append(row)

	for row_index in range(max_stops):
		var source_row: Array = matrix[row_index] if row_index < matrix.size() else []
		var next_row: Array = []
		next_row.resize(max_stops)
		next_row.fill(0.0)
		for column in range(mini(max_stops, source_row.size())):
			next_row[column] = max(0.0, float(source_row[column]))
		matrix[row_index] = next_row

	line["waiting_by_stop"] = matrix
	if not line.has("vehicles"):
		line["vehicles"] = []
	if not line.has("next_vehicle_id"):
		line["next_vehicle_id"] = 1
	if not line.has("event_serial"):
		line["event_serial"] = 0
	if not line.has("passenger_events"):
		line["passenger_events"] = []
	if not line.has("last_passenger_event"):
		line["last_passenger_event"] = null
	if not line.has("current_abandonment_ppm"):
		line["current_abandonment_ppm"] = 0.0
	if not line.has("total_abandoned_passengers"):
		line["total_abandoned_passengers"] = 0.0
	if not line.has("last_delivered_ppm"):
		line["last_delivered_ppm"] = 0.0

	var vehicles: Array = line["vehicles"]
	if bool(line["built"]) and vehicles.is_empty():
		var target_fleet := maxi(1, int(line.get("fleet_count", 1)))
		line["fleet_count"] = 0
		lines[line_key] = line
		for _index in range(target_fleet):
			_add_vehicle_to_line_state(line_key)
		line = lines[line_key]
	else:
		line["fleet_count"] = vehicles.size()

	lines[line_key] = line
	line["queue_passengers"] = line_waiting_passengers(line_key)

func build_next_stop(line_key: String) -> bool:
	if not lines.has(line_key):
		return false

	var line: Dictionary = lines[line_key]
	if line_key != "line1" and not bool(line["built"]):
		return false

	var max_stops := int(Data.LINE_CONFIG[line_key]["max_stops"])
	if int(line["stop_count"]) >= max_stops:
		return false

	var cost := next_stop_cost(line_key)
	if money < cost:
		_request_toast("Not enough money.")
		return false

	money -= cost
	line["stop_count"] = int(line["stop_count"]) + 1
	lines[line_key] = line

	if line_key == "line1" and int(line["stop_count"]) == 2:
		_initialize_line_service("line1", 1)
		_request_toast("Bus Line 1 opened with one starter bus.")

	_commit_change()
	return true

func build_line(line_key: String) -> bool:
	if line_key == "line1" or not can_unlock_line(line_key):
		return false

	var cost := line_build_cost(line_key)
	if money < cost:
		_request_toast("Not enough money.")
		return false

	money -= cost
	var line: Dictionary = lines[line_key]
	line["stop_count"] = 2
	lines[line_key] = line
	_initialize_line_service(line_key, 1)

	_request_toast("Bus Line %d opened." % Data.line_number(line_key))
	_commit_change()
	return true

func build_depot() -> bool:
	if not can_build_depot():
		return false
	if money < float(Data.ECONOMY["depot_build_cost"]):
		_request_toast("Not enough money.")
		return false

	money -= float(Data.ECONOMY["depot_build_cost"])
	depot["built"] = true
	_request_toast("Bus Depot opened.")
	_commit_change()
	return true

func add_bus(line_key: String) -> bool:
	if not bool(depot["built"]) or not bool(lines[line_key]["built"]):
		return false
	if garage_used() >= int(depot["garage_slots"]):
		_request_toast("Garage is full.")
		return false
	if int(lines[line_key]["fleet_count"]) >= int(Data.ECONOMY["max_vehicles_per_line"]):
		return false

	var cost := vehicle_purchase_cost()
	if money < cost:
		_request_toast("Not enough money.")
		return false

	money -= cost
	_add_vehicle_to_line_state(line_key)
	_request_toast("Bus added to Line %d." % Data.line_number(line_key))
	_commit_change()
	return true

func upgrade_depot() -> bool:
	if not bool(depot["built"]):
		return false

	var cost := roundi(
		float(Data.ECONOMY["depot_upgrade_base_cost"])
		* pow(float(Data.ECONOMY["depot_upgrade_cost_growth"]), int(depot["level"]))
	)
	if money < cost:
		_request_toast("Not enough money.")
		return false

	money -= cost
	depot["level"] = int(depot["level"]) + 1
	depot["garage_slots"] = int(depot["garage_slots"]) + int(Data.ECONOMY["depot_upgrade_slots"])
	_commit_change()
	return true

func upgrade_station(station_id: String) -> bool:
	if not station_is_built(station_id):
		return false

	var level := station_level(station_id)
	if level >= int(Data.STATION_UPGRADE["max_level"]):
		_request_toast("This station is already a Hub.")
		return false

	var cost := station_upgrade_cost(station_id)
	if money < cost:
		_request_toast("Not enough money.")
		return false

	money -= cost
	stations[station_id]["level"] = level + 1
	_request_toast("%s upgraded to %s." % [Data.station_name(station_id), station_tier(station_id)])
	_commit_change()
	return true

func _generate_passengers(line_key: String, delta_minutes: float) -> void:
	var line: Dictionary = lines[line_key]
	if not bool(line["built"]) or int(line["stop_count"]) < 2:
		line["current_abandonment_ppm"] = 0.0
		return

	var abandoned := 0.0
	var matrix: Array = line["waiting_by_stop"]
	var stop_count := int(line["stop_count"])

	for origin in range(stop_count):
		var per_destination_rate := stop_demand(line_key, origin) / float(maxi(1, stop_count - 1))
		var row: Array = matrix[origin]

		for destination in range(stop_count):
			if origin == destination:
				continue
			row[destination] = float(row[destination]) + per_destination_rate * delta_minutes

		matrix[origin] = row
		var waiting := stop_waiting_passengers(line_key, origin)
		var station_id: String = Data.STATION_IDS[line_key][origin]
		var waiting_capacity := float(station_capacity(station_id))

		if waiting > waiting_capacity:
			var keep_ratio := waiting_capacity / waiting
			var excess := waiting - waiting_capacity
			abandoned += excess

			row = matrix[origin]
			for destination in range(stop_count):
				row[destination] = float(row[destination]) * keep_ratio
			matrix[origin] = row

	line["waiting_by_stop"] = matrix
	line["current_abandonment_ppm"] = abandoned / delta_minutes if delta_minutes > 0.0 else 0.0
	line["total_abandoned_passengers"] = float(line["total_abandoned_passengers"]) + abandoned
	lines[line_key] = line
	line["queue_passengers"] = line_waiting_passengers(line_key)

func _emit_passenger_event(
	line_key: String,
	event_type: String,
	stop_index: int,
	vehicle_id: int,
	count: float,
	fare: float = 0.0
) -> void:
	if count <= 0.0:
		return

	var line: Dictionary = lines[line_key]
	line["event_serial"] = int(line["event_serial"]) + 1
	var event := {
		"serial": int(line["event_serial"]),
		"type": event_type,
		"stop_index": stop_index,
		"vehicle_id": vehicle_id,
		"count": count,
		"fare": fare,
	}
	line["last_passenger_event"] = event

	var events: Array = line["passenger_events"]
	events.append(event)
	while events.size() > 24:
		events.pop_front()
	line["passenger_events"] = events
	lines[line_key] = line

func _unload_at_stop(line_key: String, vehicle: Dictionary, stop_index: int) -> float:
	var onboard: Array = vehicle["onboard_by_destination"]
	var alighting := float(onboard[stop_index])
	if alighting <= 0.0:
		return 0.0

	onboard[stop_index] = 0.0
	vehicle["onboard_by_destination"] = onboard
	vehicle["onboard_passengers"] = max(0.0, float(vehicle["onboard_passengers"]) - alighting)

	var fare := alighting * float(Data.ECONOMY["fare_per_passenger"])
	money += fare
	stats["lifetime_revenue"] = float(stats["lifetime_revenue"]) + fare
	stats["lifetime_passengers"] = float(stats["lifetime_passengers"]) + alighting
	stats["last_fare_event_value"] = fare
	stats["last_fare_event_serial"] = int(stats["last_fare_event_serial"]) + 1
	stats["last_fare_line"] = line_key
	stats["last_fare_stop_index"] = stop_index

	var line: Dictionary = lines[line_key]
	line["last_delivered_ppm"] = float(line["last_delivered_ppm"]) + alighting / float(Data.DELIVERY_RATE_WINDOW_MINUTES)
	lines[line_key] = line

	_emit_passenger_event(line_key, "alight", stop_index, int(vehicle["id"]), alighting, fare)
	_fare_changed_this_frame = true
	return alighting

func _board_at_stop(line_key: String, vehicle: Dictionary) -> float:
	var line: Dictionary = lines[line_key]
	var stop_index := int(vehicle["current_stop_index"])
	var available_space := float(Data.BUS["capacity"]) - float(vehicle["onboard_passengers"])
	if available_space <= 0.0:
		return 0.0

	var destinations: Array[int] = []
	if int(vehicle["direction"]) > 0:
		for destination in range(stop_index + 1, int(line["stop_count"])):
			destinations.append(destination)
	else:
		for destination in range(stop_index - 1, -1, -1):
			destinations.append(destination)

	var boarded := 0.0
	var matrix: Array = line["waiting_by_stop"]
	var onboard: Array = vehicle["onboard_by_destination"]
	var row: Array = matrix[stop_index]

	for destination in destinations:
		if available_space <= 0.0:
			break

		var waiting := float(row[destination])
		if waiting <= 0.0:
			continue

		var take := min(waiting, available_space)
		row[destination] = waiting - take
		onboard[destination] = float(onboard[destination]) + take
		vehicle["onboard_passengers"] = float(vehicle["onboard_passengers"]) + take
		boarded += take
		available_space -= take

	matrix[stop_index] = row
	line["waiting_by_stop"] = matrix
	lines[line_key] = line
	vehicle["onboard_by_destination"] = onboard
	line["queue_passengers"] = line_waiting_passengers(line_key)

	_emit_passenger_event(line_key, "board", stop_index, int(vehicle["id"]), boarded, 0.0)
	return boarded

func _begin_boarding(line_key: String, vehicle: Dictionary) -> void:
	_board_at_stop(line_key, vehicle)
	vehicle["phase"] = "boarding"
	vehicle["phase_duration_minutes"] = float(Data.BOARDING_HOLD_MINUTES)
	vehicle["phase_minutes_remaining"] = float(Data.BOARDING_HOLD_MINUTES)

func _start_travel(line_key: String, vehicle: Dictionary) -> void:
	var line: Dictionary = lines[line_key]
	var current := int(vehicle["current_stop_index"])
	var direction := int(vehicle["direction"])

	if current == 0 and direction < 0:
		direction = 1
	if current == int(line["stop_count"]) - 1 and direction > 0:
		direction = -1
	vehicle["direction"] = direction

	var next_stop := current + direction
	if next_stop < 0 or next_stop >= int(line["stop_count"]):
		return

	vehicle["next_stop_index"] = next_stop
	vehicle["phase"] = "travel"
	var travel := _segment_travel_minutes(line_key, current, next_stop)
	vehicle["phase_duration_minutes"] = travel
	vehicle["phase_minutes_remaining"] = travel

func _arrive_at_stop(line_key: String, vehicle: Dictionary) -> void:
	vehicle["current_stop_index"] = int(vehicle["next_stop_index"])
	_unload_at_stop(line_key, vehicle, int(vehicle["current_stop_index"]))

	var line: Dictionary = lines[line_key]
	if int(vehicle["current_stop_index"]) == 0:
		vehicle["direction"] = 1
	elif int(vehicle["current_stop_index"]) == int(line["stop_count"]) - 1:
		vehicle["direction"] = -1

	vehicle["phase"] = "dwell"
	var dwell := _stop_dwell_minutes(line_key, int(vehicle["current_stop_index"]))
	vehicle["phase_duration_minutes"] = dwell
	vehicle["phase_minutes_remaining"] = dwell

func _advance_vehicle(line_key: String, vehicle: Dictionary, delta_minutes: float) -> void:
	var remaining := delta_minutes
	var guard := 0

	while remaining > 0.0 and guard < 8:
		guard += 1
		var phase_remaining := max(0.0, float(vehicle["phase_minutes_remaining"]))
		var step := min(remaining, phase_remaining)
		vehicle["phase_minutes_remaining"] = float(vehicle["phase_minutes_remaining"]) - step
		remaining -= step

		if float(vehicle["phase_minutes_remaining"]) > 0.000000001:
			break

		match str(vehicle["phase"]):
			"travel":
				_arrive_at_stop(line_key, vehicle)
			"dwell":
				_begin_boarding(line_key, vehicle)
			_:
				_start_travel(line_key, vehicle)

		if float(vehicle["phase_minutes_remaining"]) <= 0.0 and remaining <= 0.0:
			break

func _simulate_line(line_key: String, delta_minutes: float) -> void:
	_ensure_line_runtime(line_key)
	var line: Dictionary = lines[line_key]

	if not bool(line["built"]):
		line["queue_passengers"] = 0.0
		line["current_abandonment_ppm"] = 0.0
		line["last_delivered_ppm"] = 0.0
		lines[line_key] = line
		return

	var decay := exp(-delta_minutes / float(Data.DELIVERY_RATE_WINDOW_MINUTES))
	line["last_delivered_ppm"] = float(line["last_delivered_ppm"]) * decay
	lines[line_key] = line

	_generate_passengers(line_key, delta_minutes)

	line = lines[line_key]
	var vehicles: Array = line["vehicles"]
	for vehicle in vehicles:
		_advance_vehicle(line_key, vehicle, delta_minutes)
	line["vehicles"] = vehicles
	lines[line_key] = line
	line["queue_passengers"] = line_waiting_passengers(line_key)

func _advance_simulation(real_delta_seconds: float) -> bool:
	if real_delta_seconds <= 0.0 or simulation_speed <= 0:
		return false

	var delta_seconds := min(real_delta_seconds, 0.25) * float(simulation_speed)
	var delta_minutes := delta_seconds * float(Data.GAME_MINUTES_PER_REAL_SECOND)
	elapsed_seconds += delta_seconds

	for line_key in Data.LINE_KEYS:
		_simulate_line(line_key, delta_minutes)

	return CityRuntime.advance(self, delta_seconds)

func bus_visuals() -> Array[Dictionary]:
	var result: Array[Dictionary] = []

	for line_key in Data.LINE_KEYS:
		var line: Dictionary = lines[line_key]
		if not bool(line["built"]):
			continue

		for vehicle in line["vehicles"]:
			var current_stop := int(vehicle["current_stop_index"])
			var point := Layout.stop_position(line_key, current_stop)
			var tangent := Vector2.RIGHT

			if str(vehicle["phase"]) == "travel":
				var next_stop := int(vehicle["next_stop_index"])
				var segment_index := mini(current_stop, next_stop)
				var route := Layout.segment_points(line_key, segment_index)
				if current_stop > next_stop:
					route.reverse()

				var duration := max(0.000001, float(vehicle["phase_duration_minutes"]))
				var progress := clamp(
					1.0 - float(vehicle["phase_minutes_remaining"]) / duration,
					0.0,
					1.0
				)
				var route_point := Layout.point_on_route(route, Layout.route_length(route) * progress)
				point = route_point["position"]
				tangent = route_point["tangent"]
			else:
				var candidate_next := current_stop + (1 if int(vehicle["direction"]) >= 0 else -1)
				if candidate_next >= 0 and candidate_next < int(line["stop_count"]):
					var segment_index := mini(current_stop, candidate_next)
					var segment := Layout.segment_points(line_key, segment_index)
					if current_stop > candidate_next:
						segment.reverse()
					if segment.size() >= 2:
						tangent = (segment[1] - segment[0]).normalized()

			result.append({
				"key": "%s:%d" % [line_key, int(vehicle["id"])],
				"line_key": line_key,
				"position": point,
				"tangent": tangent,
				"onboard": float(vehicle["onboard_passengers"]),
			})

	return result

func _commit_change() -> void:
	var city_did_change := CityRuntime.sync_with_transport(self)
	if not suppress_persistence:
		save_game()
	state_changed.emit()
	if city_did_change:
		city_changed.emit()

func _request_toast(message: String) -> void:
	toast_requested.emit(message)

func save_game() -> void:
	if suppress_persistence:
		return

	var payload := {
		"version": Data.GAME_VERSION,
		"money": money,
		"elapsed_seconds": elapsed_seconds,
		"simulation_speed": simulation_speed,
		"city_seed": city_seed,
		"lines": lines,
		"stations": stations,
		"depot": depot,
		"stats": stats,
		"city": city,
	}

	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(payload))

func load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		state_changed.emit()
		return

	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if not file:
		return

	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	if int(parsed.get("version", 0)) != Data.GAME_VERSION:
		return

	money = float(parsed.get("money", money))
	elapsed_seconds = float(parsed.get("elapsed_seconds", 0.0))
	simulation_speed = int(parsed.get("simulation_speed", 1))
	city_seed = int(parsed.get("city_seed", Data.DEFAULT_CITY_SEED))
	lines = parsed.get("lines", lines)
	stations = parsed.get("stations", stations)
	depot = parsed.get("depot", depot)
	stats = parsed.get("stats", stats)
	city = parsed.get("city", CityRuntime.create_initial_city(city_seed))
	CityRuntime.ensure_city(self)

	for line_key in Data.LINE_KEYS:
		if not lines.has(line_key):
			lines[line_key] = _new_line_state(line_key)
		_ensure_line_runtime(line_key)

	for station_id in Data.all_station_ids():
		if not stations.has(station_id):
			stations[station_id] = {"level": 0}

	CityRuntime.sync_with_transport(self)
	state_changed.emit()
	city_changed.emit()

func clear_save_and_reset() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	reset_state(true)
	CityRuntime.sync_with_transport(self)
	city_changed.emit()
	save_game()
