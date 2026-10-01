extends Node

signal state_changed
signal city_changed
signal selection_changed(selection: String)
signal toast_requested(message: String)
signal route_editor_changed

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const CityRuntime = preload("res://scripts/city/city_runtime.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")
const TransitPlanner = preload("res://scripts/transport/transit_planner.gd")
const RoadRouter = preload("res://scripts/transport/road_router.gd")
const BrowserSaveImporter = preload("res://scripts/persistence/browser_save_importer.gd")

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
var transit_network: Dictionary = {}
var route_editor: Dictionary = {}

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
	route_editor = _empty_route_editor()

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
	transit_network = {}
	CityRuntime.sync_with_transport(self)
	transit_network = TransitNetwork.create_legacy_bridge(
		city,
		lines,
		stations
	)

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

func transit_stop(stop_id: String) -> Dictionary:
	var stops: Dictionary = transit_network.get("stops", {})
	return stops.get(stop_id, {}).duplicate(true)

func transit_line(line_id: String) -> Dictionary:
	var network_lines: Dictionary = transit_network.get("lines", {})
	return network_lines.get(line_id, {}).duplicate(true)

func snap_transit_point(
	point: Vector2,
	built_only: bool = true,
	max_distance: float = 90.0
) -> Dictionary:
	return RoadRouter.snap_to_road(city, point, built_only, max_distance)

func preview_transit_route(
	start_point: Vector2,
	end_point: Vector2,
	built_only: bool = true,
	prefer_major_roads: bool = true,
	max_snap_distance: float = 90.0
) -> Dictionary:
	return RoadRouter.route_between_points(
		city,
		start_point,
		end_point,
		built_only,
		prefer_major_roads,
		max_snap_distance
	)

func _empty_route_editor() -> Dictionary:
	return {
		"active": false,
		"mode": "",
		"line_id": "",
		"draft_points": [],
		"selected_index": -1,
		"hover_point": null,
		"hover_valid": false,
		"preview_route": {},
		"estimated_cost": 0,
	}

func route_editor_active() -> bool:
	return bool(route_editor.get("active", false))

func route_editor_points() -> Array[Vector2]:
	var result: Array[Vector2] = []
	for raw_value in route_editor.get("draft_points", []):
		if raw_value is Vector2:
			result.append(raw_value)
		elif typeof(raw_value) == TYPE_DICTIONARY:
			var raw: Dictionary = raw_value
			result.append(Vector2(
				float(raw.get("x", 0.0)),
				float(raw.get("y", 0.0))
			))
	return result

func can_begin_free_line() -> bool:
	return bool(depot.get("built", false)) and _has_free_garage_slot()

func begin_free_line_editor() -> bool:
	if not can_begin_free_line():
		_request_toast("Build the depot and keep one garage slot free.")
		return false
	route_editor = _empty_route_editor()
	route_editor["active"] = true
	route_editor["mode"] = "new"
	route_editor["estimated_cost"] = free_line_build_cost([])
	set_selection("route_editor")
	route_editor_changed.emit()
	state_changed.emit()
	return true

func begin_edit_line_editor(line_id: String) -> bool:
	var line := transit_line(line_id)
	if line.is_empty() or str(line.get("source", "")) != "custom":
		return false
	route_editor = _empty_route_editor()
	route_editor["active"] = true
	route_editor["mode"] = "edit"
	route_editor["line_id"] = line_id
	var points: Array[Vector2] = []
	for stop_id in TransitNetwork.line_stop_ids(transit_network, line_id):
		points.append(TransitNetwork.stop_position(transit_network, stop_id))
	route_editor["draft_points"] = points
	route_editor["estimated_cost"] = free_line_edit_cost(points)
	set_selection("route_editor")
	route_editor_changed.emit()
	state_changed.emit()
	return true

func cancel_route_editor() -> void:
	if not route_editor_active():
		return
	route_editor = _empty_route_editor()
	set_selection("")
	route_editor_changed.emit()
	state_changed.emit()

func set_route_editor_hover(
	point: Vector2,
	valid: bool,
	preview_route: Dictionary = {}
) -> void:
	if not route_editor_active():
		return
	route_editor["hover_point"] = point
	route_editor["hover_valid"] = valid
	route_editor["preview_route"] = preview_route
	route_editor_changed.emit()

func clear_route_editor_hover() -> void:
	if not route_editor_active():
		return
	route_editor["hover_point"] = null
	route_editor["hover_valid"] = false
	route_editor["preview_route"] = {}
	route_editor_changed.emit()

func show_route_editor_message(message: String) -> void:
	_request_toast(message)

func route_editor_select_stop(index: int) -> void:
	if not route_editor_active():
		return
	var points := route_editor_points()
	route_editor["selected_index"] = index if index >= 0 and index < points.size() else -1
	route_editor_changed.emit()
	state_changed.emit()

func route_editor_add_point(point: Vector2, insert_after: int = -1) -> bool:
	if not route_editor_active():
		return false
	var snap := snap_transit_point(point, true, 110.0)
	if snap.is_empty():
		_request_toast("Stops must be placed on a built road.")
		return false
	var snapped: Vector2 = snap["point"]
	var points := route_editor_points()
	if points.size() >= TransitNetwork.MAX_CUSTOM_STOPS:
		_request_toast("This line already has the maximum number of stops.")
		return false
	for existing in points:
		if existing.distance_to(snapped) < TransitNetwork.MIN_STOP_SPACING:
			_request_toast("Stops are too close together.")
			return false
	if insert_after >= 0 and insert_after < points.size() - 1:
		points.insert(insert_after + 1, snapped)
	else:
		points.append(snapped)
	route_editor["draft_points"] = points
	route_editor["selected_index"] = -1
	_update_route_editor_cost()
	route_editor_changed.emit()
	state_changed.emit()
	return true

func route_editor_move_selected(point: Vector2) -> bool:
	if not route_editor_active():
		return false
	var selected_index := int(route_editor.get("selected_index", -1))
	var points := route_editor_points()
	if selected_index < 0 or selected_index >= points.size():
		return false
	var snap := snap_transit_point(point, true, 110.0)
	if snap.is_empty():
		_request_toast("Stops must be placed on a built road.")
		return false
	var snapped: Vector2 = snap["point"]
	for index in range(points.size()):
		if index == selected_index:
			continue
		if points[index].distance_to(snapped) < TransitNetwork.MIN_STOP_SPACING:
			_request_toast("Stops are too close together.")
			return false
	points[selected_index] = snapped
	route_editor["draft_points"] = points
	route_editor["selected_index"] = -1
	_update_route_editor_cost()
	route_editor_changed.emit()
	state_changed.emit()
	return true

func route_editor_remove_selected() -> bool:
	if not route_editor_active():
		return false
	var points := route_editor_points()
	var selected_index := int(route_editor.get("selected_index", -1))
	if selected_index < 0 or selected_index >= points.size():
		return false
	points.remove_at(selected_index)
	route_editor["draft_points"] = points
	route_editor["selected_index"] = -1
	_update_route_editor_cost()
	route_editor_changed.emit()
	state_changed.emit()
	return true

func route_editor_undo_last() -> bool:
	if not route_editor_active():
		return false
	var points := route_editor_points()
	if points.is_empty():
		return false
	points.pop_back()
	route_editor["draft_points"] = points
	route_editor["selected_index"] = -1
	_update_route_editor_cost()
	route_editor_changed.emit()
	state_changed.emit()
	return true

func free_line_build_cost(points: Array[Vector2]) -> int:
	var route_length := _draft_route_length(points)
	return roundi(
		float(Data.ECONOMY["free_line_base_cost"])
		+ float(points.size()) * float(Data.ECONOMY["free_stop_cost"])
		+ route_length * float(Data.ECONOMY["free_route_cost_per_world_unit"])
	)

func free_line_edit_cost(points: Array[Vector2]) -> int:
	return roundi(
		float(Data.ECONOMY["free_line_edit_base_cost"])
		+ _draft_route_length(points) * float(Data.ECONOMY["free_route_cost_per_world_unit"]) * 0.12
	)

func _draft_route_length(points: Array[Vector2]) -> float:
	var total := 0.0
	for index in range(points.size() - 1):
		var route := preview_transit_route(points[index], points[index + 1], true, true, 115.0)
		if not bool(route.get("success", false)):
			return 0.0
		total += float(route.get("length", 0.0))
	return total

func _update_route_editor_cost() -> void:
	var points := route_editor_points()
	route_editor["estimated_cost"] = (
		free_line_build_cost(points)
		if str(route_editor.get("mode", "")) == "new"
		else free_line_edit_cost(points)
	)

func commit_route_editor() -> bool:
	if not route_editor_active():
		return false
	var points := route_editor_points()
	if points.size() < 2:
		_request_toast("A line needs at least two stops.")
		return false

	var mode := str(route_editor.get("mode", ""))
	var cost := (
		free_line_build_cost(points)
		if mode == "new"
		else free_line_edit_cost(points)
	)
	if money < float(cost):
		_request_toast("Not enough money.")
		return false

	if mode == "new":
		if not can_begin_free_line():
			_request_toast("No free garage slot for the starter bus.")
			return false
		var serial := int(transit_network.get("next_line_serial", 1))
		var palette_index := (serial - 1) % Data.FREE_LINE_COLORS.size()
		var color: Color = Data.FREE_LINE_COLORS[palette_index]
		var created := TransitNetwork.create_custom_line(
			transit_network,
			city,
			points,
			color
		)
		if not bool(created.get("success", false)):
			_request_toast(_route_editor_failure_message(str(created.get("reason", ""))))
			return false
		var line_id := str(created.get("line_id", ""))
		_ensure_custom_line_runtime(line_id)
		money -= float(cost)
		_request_toast("New bus line opened.")
		route_editor = _empty_route_editor()
		_commit_change()
		set_selection("free_line:%s" % line_id)
		route_editor_changed.emit()
		return true

	var line_id := str(route_editor.get("line_id", ""))
	var updated := TransitNetwork.update_custom_line_points(
		transit_network,
		city,
		line_id,
		points
	)
	if not bool(updated.get("success", false)):
		_request_toast(_route_editor_failure_message(str(updated.get("reason", ""))))
		return false
	_ensure_custom_line_runtime(line_id)
	money -= float(cost)
	_request_toast("Line updated.")
	route_editor = _empty_route_editor()
	_commit_change()
	set_selection("free_line:%s" % line_id)
	route_editor_changed.emit()
	return true

func _route_editor_failure_message(reason: String) -> String:
	match reason:
		"stops_too_close":
			return "Stops are too close together."
		"segment_unroutable":
			return "The road network cannot connect those stops."
		"stop_not_on_built_road":
			return "A stop is not on a built road."
		"too_many_stops":
			return "Too many stops on one line."
		_:
			return "This line cannot be built here."

func _sync_transit_network_bridge() -> void:
	transit_network = TransitNetwork.ensure_legacy_bridge(
		transit_network,
		city,
		lines,
		stations
	)

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
		var index: int = Data.STATION_IDS[line_key].find(station_id)
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
		var index: int = Data.STATION_IDS[line_key].find(station_id)
		if index >= 0 and index < int(line["stop_count"]):
			result.append(line_key)
	return result

func station_waiting_passengers(station_id: String) -> float:
	var total := 0.0
	for line_key in Data.LINE_KEYS:
		var line: Dictionary = lines[line_key]
		if not bool(line["built"]):
			continue
		var stop_index: int = Data.STATION_IDS[line_key].find(station_id)
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
	var segment_count: int = maxi(0, int(line["stop_count"]) - 1)
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
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		var line := transit_line(line_id)
		total += int(line.get("fleet_count", 0))
	return total

func vehicle_purchase_cost() -> int:
	var built_lines := 0
	for line_key in Data.LINE_KEYS:
		if bool(lines[line_key]["built"]):
			built_lines += 1
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		var custom_line := transit_line(line_id)
		if str(custom_line.get("status", "")) == "active":
			built_lines += 1
	var purchased: int = maxi(0, garage_used() - built_lines)
	return roundi(
		float(Data.ECONOMY["bus_base_cost"])
		* pow(float(Data.ECONOMY["bus_cost_growth"]), purchased)
	)

func custom_line_stop_count(line_id: String) -> int:
	return TransitNetwork.line_stop_ids(transit_network, line_id).size()

func custom_line_route_length_km(line_id: String) -> float:
	var line := transit_line(line_id)
	return float(line.get("route_length_world", 0.0)) / float(Data.WORLD_UNITS_PER_KM)

func custom_line_demand(line_id: String) -> float:
	var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
	if stop_ids.size() < 2:
		return 0.0
	var total := 0.0
	for stop_id in stop_ids:
		var stats := TransitNetwork.catchment_stats(transit_network, city, stop_id)
		total += float(stats.get("demand_ppm", 0.0))
	return total

func custom_line_cycle_minutes(line_id: String) -> float:
	var line := transit_line(line_id)
	var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
	if stop_ids.size() < 2:
		return 0.0
	var driving := custom_line_route_length_km(line_id) / float(Data.BUS["speed_kph"]) * 60.0 * 2.0
	var dwell := 0.0
	for stop_index in range(stop_ids.size()):
		var visits := 1 if stop_index == 0 or stop_index == stop_ids.size() - 1 else 2
		dwell += _custom_stop_dwell_minutes(line_id, stop_index, false) * float(visits)
	return driving + dwell + float(Data.BUS["turnaround_minutes"])

func custom_line_headway_minutes(line_id: String) -> float:
	var line := transit_line(line_id)
	var fleet := int(line.get("fleet_count", 0))
	if fleet <= 0:
		return INF
	return custom_line_cycle_minutes(line_id) / float(fleet)

func custom_line_waiting_passengers(line_id: String) -> float:
	var line := transit_line(line_id)
	var matrix: Array = line.get("waiting_by_stop", [])
	var stop_count := TransitNetwork.line_stop_ids(transit_network, line_id).size()
	var total := 0.0
	for origin in range(mini(matrix.size(), stop_count)):
		var row: Array = matrix[origin]
		for destination in range(mini(row.size(), stop_count)):
			total += maxf(0.0, float(row[destination]))
	return total

func custom_stop_waiting_passengers(stop_id: String) -> float:
	var total := 0.0
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
		var index := stop_ids.find(stop_id)
		if index < 0:
			continue
		var line := transit_line(line_id)
		var matrix: Array = line.get("waiting_by_stop", [])
		if index >= matrix.size():
			continue
		var row: Array = matrix[index]
		for value in row:
			total += maxf(0.0, float(value))
	return total

func transit_journey(from_stop_id: String, to_stop_id: String) -> Dictionary:
	return TransitPlanner.find_journey(transit_network, from_stop_id, to_stop_id)

func custom_stop_catchment(stop_id: String) -> Dictionary:
	return TransitNetwork.catchment_stats(transit_network, city, stop_id)

func custom_stop_upgrade_cost(stop_id: String) -> int:
	var stop := transit_stop(stop_id)
	var level := clampi(int(stop.get("level", 0)), 0, int(Data.STATION_UPGRADE["max_level"]))
	return roundi(
		float(Data.STATION_UPGRADE["base_cost"])
		* pow(float(Data.STATION_UPGRADE["cost_growth"]), level)
	)

func upgrade_custom_stop(stop_id: String) -> bool:
	var stops: Dictionary = transit_network.get("stops", {})
	if not stops.has(stop_id):
		return false
	var stop: Dictionary = stops[stop_id]
	if str(stop.get("source", "")) != "custom":
		return false
	var level := int(stop.get("level", 0))
	if level >= int(Data.STATION_UPGRADE["max_level"]):
		_request_toast("This stop is already a Hub.")
		return false
	var cost := custom_stop_upgrade_cost(stop_id)
	if money < float(cost):
		_request_toast("Not enough money.")
		return false
	money -= float(cost)
	stop["level"] = level + 1
	stops[stop_id] = stop
	transit_network["stops"] = stops
	_request_toast("%s upgraded." % str(stop.get("name", "Stop")))
	_commit_change()
	return true

func next_stop_cost(line_key: String) -> int:
	var line: Dictionary = lines[line_key]
	var base_cost: float = 0.0
	var growth: float = 1.0
	var included_stops: int = 1

	match line_key:
		"line1":
			base_cost = float(Data.ECONOMY["line1_stop_base_cost"])
			growth = float(Data.ECONOMY["line1_stop_cost_growth"])
			included_stops = 1
		"line2":
			base_cost = float(Data.ECONOMY["line2_stop_base_cost"])
			growth = float(Data.ECONOMY["line2_stop_cost_growth"])
			included_stops = 2
		"line3":
			base_cost = float(Data.ECONOMY["line3_stop_base_cost"])
			growth = float(Data.ECONOMY["line3_stop_cost_growth"])
			included_stops = 2
		"line4":
			base_cost = float(Data.ECONOMY["line4_stop_base_cost"])
			growth = float(Data.ECONOMY["line4_stop_cost_growth"])
			included_stops = 2
		_:
			return 0

	var purchased: int = maxi(
		0,
		int(line["stop_count"]) - included_stops
	)
	return roundi(base_cost * pow(growth, purchased))

func can_build_depot() -> bool:
	return (
		not bool(depot["built"])
		and bool(lines["line1"].get("built", false))
		and int(lines["line1"]["stop_count"]) >= 2
	)

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

func _ensure_custom_line_runtime(line_id: String) -> void:
	var network_lines: Dictionary = transit_network.get("lines", {})
	if not network_lines.has(line_id):
		return
	var line: Dictionary = network_lines[line_id]
	if str(line.get("source", "")) != "custom":
		return

	var stop_count := TransitNetwork.line_stop_ids(transit_network, line_id).size()
	var old_matrix: Array = line.get("waiting_by_stop", [])
	var matrix := _create_waiting_matrix(stop_count)
	for row_index in range(mini(stop_count, old_matrix.size())):
		var source_row: Array = old_matrix[row_index]
		var target_row: Array = matrix[row_index]
		for column in range(mini(stop_count, source_row.size())):
			target_row[column] = maxf(0.0, float(source_row[column]))
		matrix[row_index] = target_row
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
	if not line.has("queue_passengers"):
		line["queue_passengers"] = 0.0

	var vehicles: Array = line["vehicles"]
	for vehicle_index in range(vehicles.size()):
		var vehicle: Dictionary = vehicles[vehicle_index]
		var old_onboard: Array = vehicle.get("onboard_by_destination", [])
		var next_onboard: Array = []
		next_onboard.resize(stop_count)
		next_onboard.fill(0.0)
		for destination in range(mini(stop_count, old_onboard.size())):
			next_onboard[destination] = maxf(0.0, float(old_onboard[destination]))
		vehicle["onboard_by_destination"] = next_onboard
		var current := clampi(
			int(vehicle.get("current_stop_index", 0)),
			0,
			maxi(0, stop_count - 1)
		)
		var next := clampi(
			int(vehicle.get("next_stop_index", mini(1, stop_count - 1))),
			0,
			maxi(0, stop_count - 1)
		)
		vehicle["current_stop_index"] = current
		vehicle["next_stop_index"] = next
		var onboard_total := 0.0
		for value in next_onboard:
			onboard_total += maxf(0.0, float(value))
		vehicle["onboard_passengers"] = onboard_total
		vehicles[vehicle_index] = vehicle

	var target_fleet := maxi(0, int(line.get("fleet_count", 0)))
	if stop_count >= 2 and target_fleet <= 0:
		target_fleet = 1
	line["vehicles"] = vehicles
	line["fleet_count"] = vehicles.size()
	network_lines[line_id] = line
	transit_network["lines"] = network_lines

	while vehicles.size() < target_fleet:
		_add_custom_vehicle_to_line(line_id)
		network_lines = transit_network.get("lines", {})
		line = network_lines[line_id]
		vehicles = line.get("vehicles", [])
	while vehicles.size() > target_fleet and not vehicles.is_empty():
		vehicles.pop_back()
	line["vehicles"] = vehicles
	line["fleet_count"] = vehicles.size()
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	_update_custom_queue(line_id)

func _create_custom_vehicle(line_id: String) -> Dictionary:
	var network_lines: Dictionary = transit_network.get("lines", {})
	var line: Dictionary = network_lines[line_id]
	var stop_count := TransitNetwork.line_stop_ids(transit_network, line_id).size()
	var vehicle_id := int(line.get("next_vehicle_id", 1))
	line["next_vehicle_id"] = vehicle_id + 1
	network_lines[line_id] = line
	transit_network["lines"] = network_lines

	var onboard: Array = []
	onboard.resize(stop_count)
	onboard.fill(0.0)
	var dwell := _custom_stop_dwell_minutes(line_id, 0, true)
	return {
		"id": vehicle_id,
		"current_stop_index": 0,
		"next_stop_index": mini(1, stop_count - 1),
		"direction": 1,
		"phase": "dwell",
		"phase_minutes_remaining": dwell,
		"phase_duration_minutes": dwell,
		"onboard_by_destination": onboard,
		"onboard_passengers": 0.0,
	}

func _add_custom_vehicle_to_line(line_id: String) -> Dictionary:
	var network_lines: Dictionary = transit_network.get("lines", {})
	if not network_lines.has(line_id):
		return {}
	var line: Dictionary = network_lines[line_id]
	var vehicle := _create_custom_vehicle(line_id)
	network_lines = transit_network.get("lines", {})
	line = network_lines[line_id]
	var vehicles: Array = line.get("vehicles", [])
	vehicles.append(vehicle)
	line["vehicles"] = vehicles
	line["fleet_count"] = vehicles.size()
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	return vehicle

func add_bus_to_transit_line(line_id: String) -> bool:
	var line := transit_line(line_id)
	if line.is_empty() or str(line.get("source", "")) != "custom":
		return false
	if not bool(depot.get("built", false)):
		return false
	if garage_used() >= int(depot.get("garage_slots", 0)):
		_request_toast("Garage is full.")
		return false
	if int(line.get("fleet_count", 0)) >= int(Data.ECONOMY["max_vehicles_per_line"]):
		return false
	var cost := vehicle_purchase_cost()
	if money < float(cost):
		_request_toast("Not enough money.")
		return false

	money -= float(cost)
	_add_custom_vehicle_to_line(line_id)
	_request_toast("Bus added to %s." % str(line.get("name", "line")))
	_commit_change()
	return true

func delete_custom_line(line_id: String) -> bool:
	var line := transit_line(line_id)
	if line.is_empty() or str(line.get("source", "")) != "custom":
		return false
	if not TransitNetwork.remove_custom_line(transit_network, line_id):
		return false
	_request_toast("Line removed.")
	_commit_change()
	set_selection("")
	return true

func _custom_stop_dwell_minutes(
	line_id: String,
	stop_index: int,
	include_turnaround: bool
) -> float:
	var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
	if stop_index < 0 or stop_index >= stop_ids.size():
		return float(Data.BUS["dwell_minutes"])
	var stop := transit_stop(stop_ids[stop_index])
	var level := clampi(int(stop.get("level", 0)), 0, int(Data.STATION_UPGRADE["max_level"]))
	var reduction := float(Data.STATION_UPGRADE["dwell_reduction"][level])
	var result := maxf(0.12, float(Data.BUS["dwell_minutes"]) - reduction)
	if include_turnaround and (stop_index == 0 or stop_index == stop_ids.size() - 1):
		result += float(Data.BUS["turnaround_minutes"]) / 2.0
	return result

func _custom_segment_travel_minutes(
	line_id: String,
	from_stop: int,
	to_stop: int
) -> float:
	var line := transit_line(line_id)
	var segments: Array = line.get("route_segments", [])
	var segment_index := mini(from_stop, to_stop)
	if segment_index < 0 or segment_index >= segments.size():
		return 0.1
	var segment: Dictionary = segments[segment_index]
	var length_km := float(segment.get("length_world", 0.0)) / float(Data.WORLD_UNITS_PER_KM)
	return maxf(0.05, length_km / float(Data.BUS["speed_kph"]) * 60.0)

func _custom_generate_passengers(line_id: String, delta_minutes: float) -> void:
	var network_lines: Dictionary = transit_network.get("lines", {})
	var line: Dictionary = network_lines.get(line_id, {})
	var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
	var stop_count := stop_ids.size()
	if stop_count < 2:
		return

	var matrix: Array = line.get("waiting_by_stop", [])
	var abandoned := 0.0
	for origin in range(stop_count):
		var stats := TransitNetwork.catchment_stats(
			transit_network,
			city,
			stop_ids[origin]
		)
		var stop := transit_stop(stop_ids[origin])
		var interchange_bonus := 1.0 + maxf(
			0.0,
			float(stop.get("served_line_ids", []).size() - 1) * 0.10
		)
		var demand := float(stats.get("demand_ppm", 0.0)) * interchange_bonus
		var per_destination := demand / float(maxi(1, stop_count - 1))
		var row: Array = matrix[origin]
		for destination in range(stop_count):
			if destination == origin:
				continue
			row[destination] = float(row[destination]) + per_destination * delta_minutes

		var level := clampi(int(stop.get("level", 0)), 0, int(Data.STATION_UPGRADE["max_level"]))
		var capacity := float(Data.STATION_UPGRADE["waiting_capacity"][level])
		var waiting := 0.0
		for value in row:
			waiting += maxf(0.0, float(value))
		if waiting > capacity:
			var keep_ratio := capacity / waiting
			abandoned += waiting - capacity
			for destination in range(row.size()):
				row[destination] = float(row[destination]) * keep_ratio
		matrix[origin] = row

	line["waiting_by_stop"] = matrix
	line["current_abandonment_ppm"] = (
		abandoned / delta_minutes if delta_minutes > 0.0 else 0.0
	)
	line["total_abandoned_passengers"] = float(
		line.get("total_abandoned_passengers", 0.0)
	) + abandoned
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	_update_custom_queue(line_id)

func _custom_emit_passenger_event(
	line_id: String,
	event_type: String,
	stop_index: int,
	vehicle_id: int,
	count: float,
	fare: float = 0.0
) -> void:
	if count <= 0.0:
		return
	var network_lines: Dictionary = transit_network.get("lines", {})
	var line: Dictionary = network_lines[line_id]
	line["event_serial"] = int(line.get("event_serial", 0)) + 1
	var event := {
		"serial": int(line["event_serial"]),
		"type": event_type,
		"stop_index": stop_index,
		"vehicle_id": vehicle_id,
		"count": count,
		"fare": fare,
	}
	line["last_passenger_event"] = event
	var events: Array = line.get("passenger_events", [])
	events.append(event)
	while events.size() > 24:
		events.pop_front()
	line["passenger_events"] = events
	network_lines[line_id] = line
	transit_network["lines"] = network_lines

func _custom_unload_at_stop(
	line_id: String,
	vehicle: Dictionary,
	stop_index: int
) -> float:
	var onboard: Array = vehicle.get("onboard_by_destination", [])
	if stop_index < 0 or stop_index >= onboard.size():
		return 0.0
	var alighting := float(onboard[stop_index])
	if alighting <= 0.0:
		return 0.0
	onboard[stop_index] = 0.0
	vehicle["onboard_by_destination"] = onboard
	vehicle["onboard_passengers"] = maxf(
		0.0,
		float(vehicle.get("onboard_passengers", 0.0)) - alighting
	)

	var fare := alighting * float(Data.ECONOMY["fare_per_passenger"])
	money += fare
	stats["lifetime_revenue"] = float(stats["lifetime_revenue"]) + fare
	stats["lifetime_passengers"] = float(stats["lifetime_passengers"]) + alighting
	stats["last_fare_event_value"] = fare
	stats["last_fare_event_serial"] = int(stats["last_fare_event_serial"]) + 1
	stats["last_fare_line"] = line_id
	stats["last_fare_stop_index"] = stop_index

	var network_lines: Dictionary = transit_network.get("lines", {})
	var line: Dictionary = network_lines[line_id]
	line["last_delivered_ppm"] = float(line.get("last_delivered_ppm", 0.0)) + (
		alighting / float(Data.DELIVERY_RATE_WINDOW_MINUTES)
	)
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	_custom_emit_passenger_event(
		line_id,
		"alight",
		stop_index,
		int(vehicle.get("id", 0)),
		alighting,
		fare
	)
	_fare_changed_this_frame = true
	return alighting

func _custom_board_at_stop(line_id: String, vehicle: Dictionary) -> float:
	var network_lines: Dictionary = transit_network.get("lines", {})
	var line: Dictionary = network_lines[line_id]
	var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
	var stop_count := stop_ids.size()
	var stop_index := int(vehicle.get("current_stop_index", 0))
	var available := float(Data.BUS["capacity"]) - float(vehicle.get("onboard_passengers", 0.0))
	if available <= 0.0 or stop_index < 0 or stop_index >= stop_count:
		return 0.0

	var destinations: Array[int] = []
	if int(vehicle.get("direction", 1)) > 0:
		for destination in range(stop_index + 1, stop_count):
			destinations.append(destination)
	else:
		for destination in range(stop_index - 1, -1, -1):
			destinations.append(destination)

	var matrix: Array = line.get("waiting_by_stop", [])
	var row: Array = matrix[stop_index]
	var onboard: Array = vehicle.get("onboard_by_destination", [])
	var boarded := 0.0
	for destination in destinations:
		if available <= 0.0:
			break
		var waiting := float(row[destination])
		if waiting <= 0.0:
			continue
		var take := minf(waiting, available)
		row[destination] = waiting - take
		onboard[destination] = float(onboard[destination]) + take
		vehicle["onboard_passengers"] = float(vehicle.get("onboard_passengers", 0.0)) + take
		boarded += take
		available -= take

	matrix[stop_index] = row
	line["waiting_by_stop"] = matrix
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	vehicle["onboard_by_destination"] = onboard
	_update_custom_queue(line_id)
	_custom_emit_passenger_event(
		line_id,
		"board",
		stop_index,
		int(vehicle.get("id", 0)),
		boarded
	)
	return boarded

func _custom_start_travel(line_id: String, vehicle: Dictionary) -> void:
	var stop_count := TransitNetwork.line_stop_ids(transit_network, line_id).size()
	var current := int(vehicle.get("current_stop_index", 0))
	var direction := int(vehicle.get("direction", 1))
	if current == 0 and direction < 0:
		direction = 1
	if current == stop_count - 1 and direction > 0:
		direction = -1
	vehicle["direction"] = direction
	var next_stop := current + direction
	if next_stop < 0 or next_stop >= stop_count:
		return
	vehicle["next_stop_index"] = next_stop
	vehicle["phase"] = "travel"
	var travel := _custom_segment_travel_minutes(line_id, current, next_stop)
	vehicle["phase_duration_minutes"] = travel
	vehicle["phase_minutes_remaining"] = travel

func _custom_arrive(line_id: String, vehicle: Dictionary) -> void:
	vehicle["current_stop_index"] = int(vehicle.get("next_stop_index", 0))
	var current := int(vehicle["current_stop_index"])
	_custom_unload_at_stop(line_id, vehicle, current)
	var stop_count := TransitNetwork.line_stop_ids(transit_network, line_id).size()
	if current == 0:
		vehicle["direction"] = 1
	elif current == stop_count - 1:
		vehicle["direction"] = -1
	vehicle["phase"] = "dwell"
	var dwell := _custom_stop_dwell_minutes(line_id, current, true)
	vehicle["phase_duration_minutes"] = dwell
	vehicle["phase_minutes_remaining"] = dwell

func _custom_begin_boarding(line_id: String, vehicle: Dictionary) -> void:
	_custom_board_at_stop(line_id, vehicle)
	vehicle["phase"] = "boarding"
	vehicle["phase_duration_minutes"] = float(Data.BOARDING_HOLD_MINUTES)
	vehicle["phase_minutes_remaining"] = float(Data.BOARDING_HOLD_MINUTES)

func _advance_custom_vehicle(
	line_id: String,
	vehicle: Dictionary,
	delta_minutes: float
) -> void:
	var remaining := delta_minutes
	var guard := 0
	while remaining > 0.0 and guard < 8:
		guard += 1
		var phase_remaining := maxf(
			0.0,
			float(vehicle.get("phase_minutes_remaining", 0.0))
		)
		var step := minf(remaining, phase_remaining)
		vehicle["phase_minutes_remaining"] = phase_remaining - step
		remaining -= step
		if float(vehicle["phase_minutes_remaining"]) > 0.000000001:
			break
		match str(vehicle.get("phase", "")):
			"travel":
				_custom_arrive(line_id, vehicle)
			"dwell":
				_custom_begin_boarding(line_id, vehicle)
			_:
				_custom_start_travel(line_id, vehicle)
		if float(vehicle.get("phase_minutes_remaining", 0.0)) <= 0.0 and remaining <= 0.0:
			break

func _simulate_custom_line(line_id: String, delta_minutes: float) -> void:
	_ensure_custom_line_runtime(line_id)
	var network_lines: Dictionary = transit_network.get("lines", {})
	if not network_lines.has(line_id):
		return
	var line: Dictionary = network_lines[line_id]
	if str(line.get("status", "")) != "active":
		return

	var decay := exp(-delta_minutes / float(Data.DELIVERY_RATE_WINDOW_MINUTES))
	line["last_delivered_ppm"] = float(line.get("last_delivered_ppm", 0.0)) * decay
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	_custom_generate_passengers(line_id, delta_minutes)

	network_lines = transit_network.get("lines", {})
	line = network_lines[line_id]
	var vehicles: Array = line.get("vehicles", [])
	for vehicle in vehicles:
		_advance_custom_vehicle(line_id, vehicle, delta_minutes)
	line["vehicles"] = vehicles
	line["fleet_count"] = vehicles.size()
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	_update_custom_queue(line_id)

func _update_custom_queue(line_id: String) -> void:
	var network_lines: Dictionary = transit_network.get("lines", {})
	if not network_lines.has(line_id):
		return
	var line: Dictionary = network_lines[line_id]
	line["queue_passengers"] = custom_line_waiting_passengers(line_id)
	network_lines[line_id] = line
	transit_network["lines"] = network_lines

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

		var take: float = minf(waiting, available_space)
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
		var phase_remaining: float = maxf(0.0, float(vehicle["phase_minutes_remaining"]))
		var step: float = minf(remaining, phase_remaining)
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

	var delta_seconds: float = minf(real_delta_seconds, 0.25) * float(simulation_speed)
	var delta_minutes: float = delta_seconds * float(Data.GAME_MINUTES_PER_REAL_SECOND)
	elapsed_seconds += delta_seconds

	for line_key in Data.LINE_KEYS:
		_simulate_line(line_key, delta_minutes)
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		_simulate_custom_line(line_id, delta_minutes)

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

				var duration: float = maxf(0.000001, float(vehicle["phase_duration_minutes"]))
				var progress: float = clampf(
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

	for line_id in TransitNetwork.custom_line_ids(transit_network):
		var custom_line := transit_line(line_id)
		if str(custom_line.get("status", "")) != "active":
			continue
		var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
		var segments: Array = custom_line.get("route_segments", [])
		for vehicle_value in custom_line.get("vehicles", []):
			var vehicle: Dictionary = vehicle_value
			var current_stop := int(vehicle.get("current_stop_index", 0))
			if current_stop < 0 or current_stop >= stop_ids.size():
				continue
			var point := TransitNetwork.stop_position(
				transit_network,
				stop_ids[current_stop]
			)
			var tangent := Vector2.RIGHT

			if str(vehicle.get("phase", "")) == "travel":
				var next_stop := int(vehicle.get("next_stop_index", current_stop))
				var segment_index := mini(current_stop, next_stop)
				if segment_index >= 0 and segment_index < segments.size():
					var segment: Dictionary = segments[segment_index]
					var route: Array[Vector2] = []
					for raw_value in segment.get("points", []):
						if typeof(raw_value) != TYPE_DICTIONARY:
							continue
						var raw: Dictionary = raw_value
						route.append(Vector2(
							float(raw.get("x", 0.0)),
							float(raw.get("y", 0.0))
						))
					if current_stop > next_stop:
						route.reverse()
					if route.size() >= 2:
						var duration := maxf(
							0.000001,
							float(vehicle.get("phase_duration_minutes", 0.0))
						)
						var progress := clampf(
							1.0 - float(vehicle.get("phase_minutes_remaining", 0.0)) / duration,
							0.0,
							1.0
						)
						var route_point := Layout.point_on_route(
							route,
							Layout.route_length(route) * progress
						)
						point = route_point["position"]
						tangent = route_point["tangent"]
			else:
				var candidate_next := current_stop + (
					1 if int(vehicle.get("direction", 1)) >= 0 else -1
				)
				var segment_index := mini(current_stop, candidate_next)
				if (
					candidate_next >= 0
					and candidate_next < stop_ids.size()
					and segment_index >= 0
					and segment_index < segments.size()
				):
					var segment: Dictionary = segments[segment_index]
					var route: Array[Vector2] = []
					for raw_value in segment.get("points", []):
						if typeof(raw_value) != TYPE_DICTIONARY:
							continue
						var raw: Dictionary = raw_value
						route.append(Vector2(
							float(raw.get("x", 0.0)),
							float(raw.get("y", 0.0))
						))
					if current_stop > candidate_next:
						route.reverse()
					if route.size() >= 2:
						tangent = (route[1] - route[0]).normalized()

			result.append({
				"key": "%s:%d" % [line_id, int(vehicle.get("id", 0))],
				"line_key": line_id,
				"position": point,
				"tangent": tangent,
				"onboard": float(vehicle.get("onboard_passengers", 0.0)),
			})

	return result

func _commit_change() -> void:
	var city_did_change := CityRuntime.sync_with_transport(self)
	_sync_transit_network_bridge()
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		_ensure_custom_line_runtime(line_id)
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
		"transit_network": transit_network,
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

	_apply_payload(parsed)

func import_browser_save(path: String) -> bool:
	var payload := BrowserSaveImporter.import_file(path)
	if payload.is_empty():
		_request_toast("Browser save import failed.")
		return false

	_apply_payload(payload)
	if not suppress_persistence:
		save_game()

	_request_toast("Browser save imported into Godot.")
	return true

func _apply_payload(parsed: Dictionary) -> void:
	money = float(parsed.get("money", money))
	elapsed_seconds = float(parsed.get("elapsed_seconds", 0.0))
	simulation_speed = int(parsed.get("simulation_speed", 1))
	city_seed = int(parsed.get("city_seed", Data.DEFAULT_CITY_SEED))
	lines = parsed.get("lines", lines)
	stations = parsed.get("stations", stations)
	depot = parsed.get("depot", depot)
	stats = parsed.get("stats", stats)
	city = parsed.get("city", CityRuntime.create_initial_city(city_seed))
	transit_network = parsed.get("transit_network", {})
	CityRuntime.ensure_city(self)

	for line_key in Data.LINE_KEYS:
		if not lines.has(line_key):
			lines[line_key] = _new_line_state(line_key)
		_ensure_line_runtime(line_key)

	for station_id in Data.all_station_ids():
		if not stations.has(station_id):
			stations[station_id] = {"level": 0}

	CityRuntime.sync_with_transport(self)
	_sync_transit_network_bridge()
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		_ensure_custom_line_runtime(line_id)
	route_editor = _empty_route_editor()
	state_changed.emit()
	city_changed.emit()
	selection_changed.emit(selected)
	route_editor_changed.emit()

func clear_save_and_reset() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	reset_state(true)
	CityRuntime.sync_with_transport(self)
	city_changed.emit()
	save_game()
