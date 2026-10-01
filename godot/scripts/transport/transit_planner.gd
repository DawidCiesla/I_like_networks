extends RefCounted
class_name TransitPlanner

const TransitNetwork = preload("res://scripts/transport/transit_network.gd")

const EPSILON := 0.000001
const DEFAULT_TRANSFER_PENALTY := 180.0

static func build_graph(
	network: Dictionary,
	transfer_radius: float = TransitNetwork.TRANSFER_WALK_RADIUS
) -> Dictionary:
	var adjacency: Dictionary = {}
	var stops: Dictionary = network.get("stops", {})
	for stop_id_value in stops.keys():
		adjacency[str(stop_id_value)] = []

	var lines: Dictionary = network.get("lines", {})
	for line_id_value in lines.keys():
		var line_id := str(line_id_value)
		var line: Dictionary = lines[line_id]
		if str(line.get("status", "")) != "active":
			continue
		var stop_ids := TransitNetwork.line_stop_ids(network, line_id)
		var segments: Array = line.get("route_segments", [])
		for index in range(stop_ids.size() - 1):
			var length := 0.0
			if index < segments.size():
				var segment: Dictionary = segments[index]
				length = float(segment.get("length_world", 0.0))
			if length <= EPSILON:
				var a := TransitNetwork.stop_position(network, stop_ids[index])
				var b := TransitNetwork.stop_position(network, stop_ids[index + 1])
				length = a.distance_to(b)
			_add_edge(adjacency, stop_ids[index], stop_ids[index + 1], length, "ride", line_id)
			_add_edge(adjacency, stop_ids[index + 1], stop_ids[index], length, "ride", line_id)

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
				_add_edge(adjacency, a_id, b_id, distance + DEFAULT_TRANSFER_PENALTY, "walk", "")
				_add_edge(adjacency, b_id, a_id, distance + DEFAULT_TRANSFER_PENALTY, "walk", "")

	return adjacency

static func find_journey(
	network: Dictionary,
	from_stop_id: String,
	to_stop_id: String,
	transfer_radius: float = TransitNetwork.TRANSFER_WALK_RADIUS
) -> Dictionary:
	var graph := build_graph(network, transfer_radius)
	if not graph.has(from_stop_id) or not graph.has(to_stop_id):
		return {"success": false, "reason": "stop_not_found", "legs": []}

	var distance: Dictionary = {}
	var previous: Dictionary = {}
	var open: Array[String] = []
	for node_value in graph.keys():
		var node_id := str(node_value)
		distance[node_id] = INF
		open.append(node_id)
	distance[from_stop_id] = 0.0

	while not open.is_empty():
		var best_index := -1
		var current := ""
		var current_cost := INF
		for index in range(open.size()):
			var node_id := open[index]
			var cost := float(distance.get(node_id, INF))
			if cost < current_cost:
				current_cost = cost
				current = node_id
				best_index = index
		if best_index < 0 or current_cost == INF:
			break
		open.remove_at(best_index)
		if current == to_stop_id:
			break

		for edge_value in graph.get(current, []):
			var edge: Dictionary = edge_value
			var next := str(edge.get("to", ""))
			var alternate := current_cost + float(edge.get("cost", 0.0))
			if alternate + EPSILON >= float(distance.get(next, INF)):
				continue
			distance[next] = alternate
			previous[next] = {
				"from": current,
				"mode": str(edge.get("mode", "")),
				"line_id": str(edge.get("line_id", "")),
				"cost": float(edge.get("cost", 0.0)),
			}

	if from_stop_id != to_stop_id and not previous.has(to_stop_id):
		return {"success": false, "reason": "no_journey", "legs": []}

	var nodes: Array[String] = [to_stop_id]
	var cursor := to_stop_id
	while cursor != from_stop_id:
		cursor = str(previous[cursor].get("from", ""))
		nodes.append(cursor)
	nodes.reverse()

	var raw_legs: Array = []
	for index in range(1, nodes.size()):
		var step: Dictionary = previous[nodes[index]]
		raw_legs.append({
			"from_stop_id": nodes[index - 1],
			"to_stop_id": nodes[index],
			"mode": step["mode"],
			"line_id": step["line_id"],
			"cost": step["cost"],
		})

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
		"cost": float(distance.get(to_stop_id, 0.0)),
		"nodes": nodes,
		"legs": legs,
		"transfers": transfers,
	}

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
	line_id: String
) -> void:
	if not adjacency.has(from_id):
		adjacency[from_id] = []
	var edges: Array = adjacency[from_id]
	edges.append({
		"to": to_id,
		"cost": maxf(0.0, cost),
		"mode": mode,
		"line_id": line_id,
	})
	adjacency[from_id] = edges
