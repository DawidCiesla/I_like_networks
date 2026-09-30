extends Node

signal state_changed
signal selection_changed(selection: String)
signal toast_requested(message: String)

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")

const SAVE_PATH := "user://save_godot_v1.json"

var money: float = 0.0
var elapsed_seconds: float = 0.0
var simulation_speed: int = 1
var city_seed: int = Data.DEFAULT_CITY_SEED
var selected: String = ""

var lines: Dictionary = {}
var stations: Dictionary = {}
var depot: Dictionary = {}
var stats: Dictionary = {}
var _fare_timers: Dictionary = {}
var _autosave_timer := 0.0

func _ready() -> void:
	reset_state(false)
	load_game()

func reset_state(emit_signal: bool = true) -> void:
	money = Data.ECONOMY.starting_money
	elapsed_seconds = 0.0
	simulation_speed = 1
	city_seed = Data.DEFAULT_CITY_SEED
	selected = ""

	lines = {}
	for line_key in Data.LINE_KEYS:
		lines[line_key] = {
			"built": false,
			"stop_count": 1 if line_key == "line1" else 0,
			"fleet_count": 0,
		}
	lines["line1"].built = false

	stations = {}
	for station_id in Data.all_station_ids():
		stations[station_id] = {"level": 0}

	depot = {
		"built": false,
		"garage_slots": 4,
		"level": 0,
	}

	stats = {
		"lifetime_revenue": 0.0,
		"lifetime_passengers": 0.0,
		"last_fare": 0.0,
	}

	_fare_timers = {}
	for line_key in Data.LINE_KEYS:
		_fare_timers[line_key] = 0.0

	if emit_signal:
		state_changed.emit()
		selection_changed.emit(selected)

func _process(delta: float) -> void:
	if simulation_speed <= 0:
		return

	var scaled_delta := delta * float(simulation_speed)
	elapsed_seconds += scaled_delta
	_simulate_fares(scaled_delta)

	_autosave_timer += delta
	if _autosave_timer >= 12.0:
		_autosave_timer = 0.0
		save_game()

func set_speed(speed: int) -> void:
	if speed not in [0, 1, 2, 4]:
		return
	simulation_speed = speed
	state_changed.emit()

func set_selection(value: String) -> void:
	selected = value
	selection_changed.emit(selected)

func station_level(station_id: String) -> int:
	return int(stations.get(station_id, {"level": 0}).level)

func station_tier(station_id: String) -> String:
	return Data.STATION_UPGRADE.tier_names[station_level(station_id)]

func station_upgrade_cost(station_id: String) -> int:
	var level := station_level(station_id)
	return roundi(
		Data.STATION_UPGRADE.base_cost
		* pow(Data.STATION_UPGRADE.cost_growth, level)
	)

func station_capacity(station_id: String) -> int:
	return Data.STATION_UPGRADE.waiting_capacity[station_level(station_id)]

func station_is_built(station_id: String) -> bool:
	if station_id == "old-town":
		return true
	for line_key in Data.LINE_KEYS:
		var index := Data.STATION_IDS[line_key].find(station_id)
		if index < 0:
			continue
		var line: Dictionary = lines[line_key]
		if line_key == "line1":
			if index < int(line.stop_count):
				return true
		elif bool(line.built) and index < int(line.stop_count):
			return true
	return false

func station_served_lines(station_id: String) -> Array[String]:
	var result: Array[String] = []
	for line_key in Data.LINE_KEYS:
		var line: Dictionary = lines[line_key]
		if not bool(line.built):
			continue
		var index := Data.STATION_IDS[line_key].find(station_id)
		if index >= 0 and index < int(line.stop_count):
			result.append(line_key)
	return result

func stop_demand(line_key: String, stop_index: int) -> float:
	var line: Dictionary = lines[line_key]
	var station_id: String = Data.STATION_IDS[line_key][stop_index]
	return (
		float(Data.LINE_CONFIG[line_key].demand_per_stop_ppm)
		+ float(Data.STATION_UPGRADE.demand_bonus[station_level(station_id)])
	)

func line_demand(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	if not bool(line.built) or int(line.stop_count) < 2:
		return 0.0
	var total := 0.0
	for stop_index in range(int(line.stop_count)):
		total += stop_demand(line_key, stop_index)
	return total

func line_route_length_km(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	var segment_count := max(0, int(line.stop_count) - 1)
	var lengths: Array = Data.LINE_CONFIG[line_key].segment_lengths_km
	var total := 0.0
	for index in range(segment_count):
		total += float(lengths[index])
	return total

func line_cycle_minutes(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	if not bool(line.built) or int(line.stop_count) < 2:
		return 0.0

	var driving := line_route_length_km(line_key) / float(Data.BUS.speed_kph) * 60.0 * 2.0
	var dwell := 0.0
	for stop_index in range(int(line.stop_count)):
		var station_id: String = Data.STATION_IDS[line_key][stop_index]
		var reduction := float(Data.STATION_UPGRADE.dwell_reduction[station_level(station_id)])
		var base_dwell: float = max(0.12, float(Data.BUS.dwell_minutes) - reduction)
		var visits := 1 if stop_index == 0 or stop_index == int(line.stop_count) - 1 else 2
		dwell += base_dwell * visits
	return driving + dwell + float(Data.BUS.turnaround_minutes)

func line_headway_minutes(line_key: String) -> float:
	var fleet := int(lines[line_key].fleet_count)
	if fleet <= 0:
		return INF
	return line_cycle_minutes(line_key) / float(fleet)

func line_capacity_ppm(line_key: String) -> float:
	var headway := line_headway_minutes(line_key)
	if not is_finite(headway) or headway <= 0.0:
		return 0.0
	return float(Data.BUS.capacity) / headway

func line_is_stable(line_key: String) -> bool:
	return bool(lines[line_key].built) and line_capacity_ppm(line_key) >= line_demand(line_key)

func garage_used() -> int:
	var total := 0
	for line_key in Data.LINE_KEYS:
		total += int(lines[line_key].fleet_count)
	return total

func vehicle_purchase_cost() -> int:
	var built_lines := 0
	for line_key in Data.LINE_KEYS:
		if bool(lines[line_key].built):
			built_lines += 1
	var purchased := max(0, garage_used() - built_lines)
	return roundi(Data.ECONOMY.bus_base_cost * pow(Data.ECONOMY.bus_cost_growth, purchased))

func next_stop_cost(line_key: String) -> int:
	var line: Dictionary = lines[line_key]
	var config := {
		"line1": [Data.ECONOMY.line1_stop_base_cost, Data.ECONOMY.line1_stop_cost_growth, 1],
		"line2": [Data.ECONOMY.line2_stop_base_cost, Data.ECONOMY.line2_stop_cost_growth, 2],
		"line3": [Data.ECONOMY.line3_stop_base_cost, Data.ECONOMY.line3_stop_cost_growth, 2],
		"line4": [Data.ECONOMY.line4_stop_base_cost, Data.ECONOMY.line4_stop_cost_growth, 2],
	}[line_key]
	var purchased := max(0, int(line.stop_count) - int(config[2]))
	return roundi(float(config[0]) * pow(float(config[1]), purchased))

func can_build_depot() -> bool:
	return not bool(depot.built) and int(lines.line1.stop_count) >= 3

func _has_free_garage_slot() -> bool:
	return garage_used() < int(depot.garage_slots)

func can_unlock_line(line_key: String) -> bool:
	if line_key == "line1":
		return true
	var previous_index := Data.LINE_KEYS.find(line_key) - 1
	if previous_index < 0:
		return false
	var previous_key: String = Data.LINE_KEYS[previous_index]
	var previous_line: Dictionary = lines[previous_key]
	return (
		not bool(lines[line_key].built)
		and bool(depot.built)
		and int(previous_line.stop_count) >= int(Data.LINE_CONFIG[previous_key].max_stops)
		and line_is_stable(previous_key)
		and _has_free_garage_slot()
	)

func line_build_cost(line_key: String) -> int:
	match line_key:
		"line2":
			return int(Data.ECONOMY.line2_build_cost)
		"line3":
			return int(Data.ECONOMY.line3_build_cost)
		"line4":
			return int(Data.ECONOMY.line4_build_cost)
		_:
			return 0

func build_next_stop(line_key: String) -> bool:
	if not lines.has(line_key):
		return false
	var line: Dictionary = lines[line_key]
	if line_key != "line1" and not bool(line.built):
		return false
	var max_stops := int(Data.LINE_CONFIG[line_key].max_stops)
	if int(line.stop_count) >= max_stops:
		return false

	var cost := next_stop_cost(line_key)
	if money < cost:
		_request_toast("Not enough money.")
		return false

	money -= cost
	line.stop_count = int(line.stop_count) + 1
	if line_key == "line1" and int(line.stop_count) == 2:
		line.built = true
		line.fleet_count = 1
		_request_toast("Bus Line 1 opened with one starter bus.")

	lines[line_key] = line
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
	line.built = true
	line.stop_count = 2
	line.fleet_count = 1
	lines[line_key] = line
	_request_toast("Bus Line %d opened." % Data.line_number(line_key))
	_commit_change()
	return true

func build_depot() -> bool:
	if not can_build_depot():
		return false
	if money < float(Data.ECONOMY.depot_build_cost):
		_request_toast("Not enough money.")
		return false
	money -= float(Data.ECONOMY.depot_build_cost)
	depot.built = true
	_request_toast("Bus Depot opened.")
	_commit_change()
	return true

func add_bus(line_key: String) -> bool:
	if not bool(depot.built) or not bool(lines[line_key].built):
		return false
	if garage_used() >= int(depot.garage_slots):
		_request_toast("Garage is full.")
		return false
	if int(lines[line_key].fleet_count) >= int(Data.ECONOMY.max_vehicles_per_line):
		return false

	var cost := vehicle_purchase_cost()
	if money < cost:
		_request_toast("Not enough money.")
		return false

	money -= cost
	var line: Dictionary = lines[line_key]
	line.fleet_count = int(line.fleet_count) + 1
	lines[line_key] = line
	_request_toast("Bus added to Line %d." % Data.line_number(line_key))
	_commit_change()
	return true

func upgrade_depot() -> bool:
	if not bool(depot.built):
		return false
	var cost := roundi(
		float(Data.ECONOMY.depot_upgrade_base_cost)
		* pow(float(Data.ECONOMY.depot_upgrade_cost_growth), int(depot.level))
	)
	if money < cost:
		_request_toast("Not enough money.")
		return false
	money -= cost
	depot.level = int(depot.level) + 1
	depot.garage_slots = int(depot.garage_slots) + int(Data.ECONOMY.depot_upgrade_slots)
	_commit_change()
	return true

func upgrade_station(station_id: String) -> bool:
	if not station_is_built(station_id):
		return false
	var level := station_level(station_id)
	if level >= int(Data.STATION_UPGRADE.max_level):
		_request_toast("This station is already a Hub.")
		return false
	var cost := station_upgrade_cost(station_id)
	if money < cost:
		_request_toast("Not enough money.")
		return false
	money -= cost
	stations[station_id].level = level + 1
	_request_toast("%s upgraded to %s." % [Data.station_name(station_id), station_tier(station_id)])
	_commit_change()
	return true

func _simulate_fares(real_delta: float) -> void:
	var game_minutes := real_delta * float(Data.GAME_MINUTES_PER_REAL_SECOND)
	var changed := false

	for line_key in Data.LINE_KEYS:
		var line: Dictionary = lines[line_key]
		if not bool(line.built) or int(line.fleet_count) <= 0:
			continue

		var headway := line_headway_minutes(line_key)
		if not is_finite(headway) or headway <= 0.0:
			continue

		_fare_timers[line_key] = float(_fare_timers[line_key]) + game_minutes
		while float(_fare_timers[line_key]) >= headway:
			_fare_timers[line_key] = float(_fare_timers[line_key]) - headway
			var delivered := min(
				float(Data.BUS.capacity),
				line_demand(line_key) * headway
			)
			var passenger_count := max(1, floori(delivered))
			var fare := float(passenger_count) * float(Data.ECONOMY.fare_per_passenger)
			money += fare
			stats.lifetime_revenue = float(stats.lifetime_revenue) + fare
			stats.lifetime_passengers = float(stats.lifetime_passengers) + passenger_count
			stats.last_fare = fare
			changed = true

	if changed:
		state_changed.emit()

func line_built_route(line_key: String) -> Array[Vector2]:
	return Layout.built_route(line_key, int(lines[line_key].stop_count))

func line_future_segment(line_key: String) -> Array[Vector2]:
	return Layout.future_segment(line_key, int(lines[line_key].stop_count))

func bus_visuals() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for line_key in Data.LINE_KEYS:
		var line: Dictionary = lines[line_key]
		if not bool(line.built) or int(line.fleet_count) <= 0:
			continue
		var route := line_built_route(line_key)
		var length := Layout.route_length(route)
		if length <= 0.0:
			continue

		for bus_index in range(int(line.fleet_count)):
			var phase := (
				elapsed_seconds * 8.0
				+ float(bus_index) * length / float(max(1, int(line.fleet_count)))
			)
			var cycle_distance := length * 2.0
			var wrapped := fposmod(phase, cycle_distance)
			var distance := wrapped if wrapped <= length else cycle_distance - wrapped
			var point := Layout.point_on_route(route, distance)
			result.append({
				"key": "%s:%d" % [line_key, bus_index],
				"line_key": line_key,
				"position": point.position,
				"tangent": point.tangent if wrapped <= length else -point.tangent,
			})
	return result

func _commit_change() -> void:
	save_game()
	state_changed.emit()

func _request_toast(message: String) -> void:
	toast_requested.emit(message)

func save_game() -> void:
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

	for line_key in Data.LINE_KEYS:
		if not lines.has(line_key):
			lines[line_key] = {
				"built": false,
				"stop_count": 1 if line_key == "line1" else 0,
				"fleet_count": 0,
			}
	for station_id in Data.all_station_ids():
		if not stations.has(station_id):
			stations[station_id] = {"level": 0}

	state_changed.emit()

func clear_save_and_reset() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	reset_state(true)
	save_game()
