extends RefCounted
class_name TransitPlanner

const TransitNetwork = preload("res://scripts/transport/transit_network.gd")
const TransitModes = preload("res://scripts/transport/transit_modes.gd")
const Data = preload("res://scripts/core/game_data.gd")

const EPSILON := 0.000001
const DEFAULT_TRANSFER_PENALTY := 180.0
const WALK_SPEED_METERS_PER_MINUTE := 72.0
const WALK_TRANSFER_OVERHEAD_MINUTES := 3.0
const MAX_EXPECTED_WAIT_MINUTES := 30.0
const CAPACITY_PENALTY_MINUTES := 42.0


static func build_graph(
	network: Dictionary,
	transfer_radius: float = TransitNetwork.TRANSFER_WALK_RADIUS,
	walk_speed: float = WALK_SPEED_METERS_PER_MINUTE
) -> Dictionary:
	var adjacency: Dictionary = {}
	var stops: Dictionary = network.get("stops", {})
	for stop_id_value in stops.keys():
		adjacency[str(stop_id_value)] = []

	var lines: Dictionary = network.get("lines", {})
	for line_id_value in lines.keys():
		var line_id := str(line_id_value)
		var line: Dictionary = lines[line_id]
		if str(line.get("status", "")) != "active" or int(line.get("fleet_count", 0)) <= 0:
			continue
		var mode := str(line.get("mode", "bus"))
		var profile := TransitModes.profile(mode)
		if profile.is_empty():
			continue
		var speed_kph := maxf(1.0, float(profile.get("speed_kph", 18.0)))
		var expected_wait := minf(
			MAX_EXPECTED_WAIT_MINUTES,
			maxf(0.0, _line_headway_minutes(network, line_id, line, profile) * 0.5)
		)
		var capacity_penalty := CAPACITY_PENALTY_MINUTES * clampf(
			float(line.get("crowding_ratio", 0.0)),
			0.0,
			1.0
		)
		var stop_ids := TransitNetwork.line_stop_ids(network, line_id)
		var segments: Array = line.get("route_segments", [])
		for index in range(stop_ids.size() - 1):
			var length := 0.0
			if index < segments.size() and segments[index] is Dictionary:
				var segment: Dictionary = segments[index]
				length = float(segment.get("length_world", 0.0))
			if length <= EPSILON:
				var a := TransitNetwork.stop_position(network, stop_ids[index])
				var b := TransitNetwork.stop_position(network, stop_ids[index + 1])
				length = a.distance_to(b)
			var ride_minutes := length / float(Data.WORLD_UNITS_PER_KM) / speed_kph * 60.0
			_add_edge(
				adjacency,
				stop_ids[index],
				stop_ids[index + 1],
				length,
				"ride",
				line_id,
				ride_minutes,
				expected_wait,
				capacity_penalty
			)
			_add_edge(
				adjacency,
				stop_ids[index + 1],
				stop_ids[index],
				length,
				"ride",
				line_id,
				ride_minutes,
				expected_wait,
				capacity_penalty
			)

	var built_ids: Array[String] = []
	for stop_id_value in stops.keys():
		var stop_id := str(stop_id_value)
		var stop: Dictionary = stops[stop_id]
		if str(stop.get("status", "")) == "built":
			built_ids.append(stop_id)

	for i in range(built_ids.size()):
		for j in range(i + 1, built_ids.size()):
			var a_id := built_ids[i]
			var b_id := built_ids[j]
			var a := TransitNetwork.stop_position(network, a_id)
			var b := TransitNetwork.stop_position(network, b_id)
			var distance := a.distance_to(b)
			if distance <= transfer_radius:
				var walk_minutes := distance / maxf(1.0, walk_speed) + WALK_TRANSFER_OVERHEAD_MINUTES
				_add_edge(
					adjacency,
					a_id,
					b_id,
					distance + DEFAULT_TRANSFER_PENALTY,
					"walk",
					"",
					walk_minutes
				)
				_add_edge(
					adjacency,
					b_id,
					a_id,
					distance + DEFAULT_TRANSFER_PENALTY,
					"walk",
					"",
					walk_minutes
				)

	return adjacency


static func find_journey(
	network: Dictionary,
	from_stop_id: String,
	to_stop_id: String,
	transfer_radius: float = TransitNetwork.TRANSFER_WALK_RADIUS,
	walk_speed: float = WALK_SPEED_METERS_PER_MINUTE
) -> Dictionary:
	var graph := build_graph(network, transfer_radius, walk_speed)
	if not graph.has(from_stop_id) or not graph.has(to_stop_id):
		return {"success": false, "reason": "stop_not_found", "legs": []}
	if from_stop_id == to_stop_id:
		return {
			"success": true,
			"reason": "",
			"cost": 0.0,
			"generalized_time_minutes": 0.0,
			"nodes": [from_stop_id],
			"legs": [],
			"transfers": 0,
		}

	# The active line is part of the search state so headway and crowding are
	# charged once per boarding, not again for each stop on the same line.
	var distance: Dictionary = {}
	var previous: Dictionary = {}
	var stop_by_state: Dictionary = {}
	var line_by_state: Dictionary = {}
	var open: Array[String] = []
	for stop_id_value in graph.keys():
		var state := _route_state(str(stop_id_value), "")
		distance[state] = INF
		stop_by_state[state] = str(stop_id_value)
		line_by_state[state] = ""
		open.append(state)
	var start_state := _route_state(from_stop_id, "")
	distance[start_state] = 0.0
	var destination_state := ""

	while not open.is_empty():
		var best_index := -1
		var current_state := ""
		var current_cost := INF
		for index in range(open.size()):
			var state := open[index]
			var cost := float(distance.get(state, INF))
			if cost < current_cost:
				current_cost = cost
				current_state = state
				best_index = index
		if best_index < 0 or current_cost == INF:
			break
		open.remove_at(best_index)
		var current_stop := str(stop_by_state.get(current_state, ""))
		if current_stop == to_stop_id:
			destination_state = current_state
			break

		for edge_value in graph.get(current_stop, []):
			var edge: Dictionary = edge_value
			var next_stop := str(edge.get("to", ""))
			var mode := str(edge.get("mode", ""))
			var line_id := str(edge.get("line_id", ""))
			var active_line := str(line_by_state.get(current_state, ""))
			var next_line := line_id if mode == "ride" else ""
			var edge_minutes := float(edge.get("time_minutes", 0.0))
			if mode == "ride" and active_line != line_id:
				edge_minutes += float(edge.get("boarding_wait_minutes", 0.0))
				edge_minutes += float(edge.get("capacity_penalty_minutes", 0.0))
			var next_state := _route_state(next_stop, next_line)
			if not distance.has(next_state):
				distance[next_state] = INF
				stop_by_state[next_state] = next_stop
				line_by_state[next_state] = next_line
				open.append(next_state)
			var alternate := current_cost + edge_minutes
			if alternate + EPSILON >= float(distance.get(next_state, INF)):
				continue
			distance[next_state] = alternate
			previous[next_state] = {
				"from_state": current_state,
				"from": current_stop,
				"to": next_stop,
				"mode": mode,
				"line_id": line_id,
				"cost": float(edge.get("cost", 0.0)),
				"time_minutes": edge_minutes,
			}

	if destination_state.is_empty():
		return {"success": false, "reason": "no_journey", "legs": []}

	var nodes: Array[String] = []
	var raw_legs: Array = []
	var cursor := destination_state
	nodes.append(str(stop_by_state.get(cursor, "")))
	while cursor != start_state:
		var step: Dictionary = previous[cursor]
		raw_legs.append({
			"from_stop_id": str(step["from"]),
			"to_stop_id": str(step["to"]),
			"mode": str(step["mode"]),
			"line_id": str(step["line_id"]),
			"cost": float(step["cost"]),
			"time_minutes": float(step["time_minutes"]),
		})
		cursor = str(step.get("from_state", ""))
		nodes.append(str(stop_by_state.get(cursor, "")))
	raw_legs.reverse()
	nodes.reverse()

	var legs := _merge_ride_legs(raw_legs)
	var transfers := 0
	var last_line := ""
	for leg_value in legs:
		var leg: Dictionary = leg_value
		if str(leg.get("mode", "")) != "ride":
			continue
		var line_id := str(leg.get("line_id", ""))
		if not last_line.is_empty() and line_id != last_line:
			transfers += 1
		last_line = line_id

	return {
		"success": true,
		"reason": "",
		# Preserve the existing geometric cost field for callers that use leg
		# distances. The selected path is minimized by generalized time below.
		"cost": _sum_leg_costs(legs),
		"generalized_time_minutes": float(distance.get(destination_state, 0.0)),
		"nodes": nodes,
		"legs": legs,
		"transfers": transfers,
	}


static func _line_headway_minutes(
	network: Dictionary,
	line_id: String,
	line: Dictionary,
	profile: Dictionary
) -> float:
	var fleet := maxi(1, int(line.get("fleet_count", 1)))
	var stop_ids := TransitNetwork.line_stop_ids(network, line_id)
	var speed_kph := maxf(1.0, float(profile.get("speed_kph", 18.0)))
	var route_length := maxf(0.0, float(line.get("route_length_world", 0.0)))
	if route_length <= EPSILON:
		var segments: Array = line.get("route_segments", [])
		for segment_value in segments:
			if segment_value is Dictionary:
				var segment: Dictionary = segment_value
				route_length += maxf(0.0, float(segment.get("length_world", 0.0)))
	if route_length <= EPSILON:
		for index in range(stop_ids.size() - 1):
			route_length += TransitNetwork.stop_position(network, stop_ids[index]).distance_to(
				TransitNetwork.stop_position(network, stop_ids[index + 1])
			)
	if stop_ids.size() < 2 or route_length <= EPSILON:
		return maxf(0.0, float(profile.get("headway_minutes", 10.0)))

	var dwell := 0.0
	var stops: Dictionary = network.get("stops", {})
	for stop_index in range(stop_ids.size()):
		var stop: Dictionary = stops.get(stop_ids[stop_index], {})
		var level := clampi(
			int(stop.get("level", 0)),
			0,
			int(Data.STATION_UPGRADE["max_level"])
		)
		var base_dwell := maxf(
			0.12,
			float(Data.BUS["dwell_minutes"])
				- float(Data.STATION_UPGRADE["dwell_reduction"][level])
		)
		var visits := 1 if stop_index == 0 or stop_index == stop_ids.size() - 1 else 2
		dwell += base_dwell * float(visits)
	var cycle := (
		route_length / float(Data.WORLD_UNITS_PER_KM) / speed_kph * 60.0 * 2.0
		+ dwell
		+ float(Data.BUS["turnaround_minutes"])
	)
	return cycle / float(fleet)


static func _route_state(stop_id: String, line_id: String) -> String:
	return "%s::%s" % [stop_id, line_id]


static func _sum_leg_costs(legs: Array) -> float:
	var result := 0.0
	for leg_value in legs:
		if leg_value is Dictionary:
			var leg: Dictionary = leg_value
			result += float(leg.get("cost", 0.0))
	return result


static func _merge_ride_legs(raw_legs: Array) -> Array:
	var result: Array = []
	for leg_value in raw_legs:
		var leg: Dictionary = leg_value
		if result.is_empty():
			result.append(leg.duplicate(true))
			continue
		var last: Dictionary = result[result.size() - 1]
		if (
			str(last.get("mode", "")) == "ride"
			and str(leg.get("mode", "")) == "ride"
			and str(last.get("line_id", "")) == str(leg.get("line_id", ""))
			and str(last.get("to_stop_id", "")) == str(leg.get("from_stop_id", ""))
		):
			last["to_stop_id"] = leg["to_stop_id"]
			last["cost"] = float(last.get("cost", 0.0)) + float(leg.get("cost", 0.0))
			last["time_minutes"] = float(last.get("time_minutes", 0.0)) + float(leg.get("time_minutes", 0.0))
			result[result.size() - 1] = last
		else:
			result.append(leg.duplicate(true))
	return result


static func _add_edge(
	adjacency: Dictionary,
	from_id: String,
	to_id: String,
	cost: float,
	mode: String,
	line_id: String,
	time_minutes: float,
	boarding_wait_minutes: float = 0.0,
	capacity_penalty_minutes: float = 0.0
) -> void:
	if not adjacency.has(from_id):
		adjacency[from_id] = []
	var edges: Array = adjacency[from_id]
	edges.append({
		"to": to_id,
		"cost": maxf(0.0, cost),
		"mode": mode,
		"line_id": line_id,
		"time_minutes": maxf(0.0, time_minutes),
		"boarding_wait_minutes": maxf(0.0, boarding_wait_minutes),
		"capacity_penalty_minutes": maxf(0.0, capacity_penalty_minutes),
	})
	adjacency[from_id] = edges
