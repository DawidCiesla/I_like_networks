extends RefCounted
class_name RoadRouter

const EPSILON := 0.000001

static func snap_to_road(
	city: Dictionary,
	point: Vector2,
	built_only: bool = false,
	max_distance: float = INF
) -> Dictionary:
	var node_lookup := _node_lookup(city)
	var road_lookup := _road_lookup(city)
	var best: Dictionary = {}

	for edge_value in city.get("graph_edges", []):
		var edge: Dictionary = edge_value
		var road: Dictionary = road_lookup.get(str(edge.get("roadId", "")), {})
		if road.is_empty():
			continue
		if built_only and str(road.get("status", "")) != "built":
			continue

		var a_id := str(edge.get("a", ""))
		var b_id := str(edge.get("b", ""))
		if not node_lookup.has(a_id) or not node_lookup.has(b_id):
			continue

		var a: Vector2 = node_lookup[a_id]
		var b: Vector2 = node_lookup[b_id]
		var candidate := _closest_point_on_segment(point, a, b)
		if best.is_empty() or float(candidate["distance"]) < float(best["distance"]):
			best = {
				"valid": true,
				"point": candidate["point"],
				"x": (candidate["point"] as Vector2).x,
				"y": (candidate["point"] as Vector2).y,
				"distance": candidate["distance"],
				"t": candidate["t"],
				"edge_id": str(edge.get("id", "")),
				"road_id": str(edge.get("roadId", "")),
				"road_class": str(edge.get("class", road.get("class", "local"))),
				"a": a_id,
				"b": b_id,
				"edge_length": a.distance_to(b),
			}

	if best.is_empty():
		return {}
	if float(best["distance"]) > max_distance:
		return {}
	return best

static func route_between_points(
	city: Dictionary,
	start_point: Vector2,
	end_point: Vector2,
	built_only: bool = false,
	prefer_major_roads: bool = false,
	max_snap_distance: float = INF
) -> Dictionary:
	var start_snap := snap_to_road(city, start_point, built_only, max_snap_distance)
	var end_snap := snap_to_road(city, end_point, built_only, max_snap_distance)
	if start_snap.is_empty() or end_snap.is_empty():
		return _failed_route("snap_failed")
	return route_between_snaps(
		city,
		start_snap,
		end_snap,
		built_only,
		prefer_major_roads
	)

static func route_between_snaps(
	city: Dictionary,
	start_snap: Dictionary,
	end_snap: Dictionary,
	built_only: bool = false,
	prefer_major_roads: bool = false
) -> Dictionary:
	if start_snap.is_empty() or end_snap.is_empty():
		return _failed_route("invalid_snap")

	var node_lookup := _node_lookup(city)
	var road_lookup := _road_lookup(city)
	var adjacency: Dictionary = {}
	var edge_lookup: Dictionary = {}

	for node_id_value in node_lookup.keys():
		adjacency[str(node_id_value)] = []

	for edge_value in city.get("graph_edges", []):
		var edge: Dictionary = edge_value
		var edge_id := str(edge.get("id", ""))
		var road_id := str(edge.get("roadId", ""))
		var road: Dictionary = road_lookup.get(road_id, {})
		if road.is_empty():
			continue
		if built_only and str(road.get("status", "")) != "built":
			continue

		var a_id := str(edge.get("a", ""))
		var b_id := str(edge.get("b", ""))
		if not node_lookup.has(a_id) or not node_lookup.has(b_id):
			continue

		var a: Vector2 = node_lookup[a_id]
		var b: Vector2 = node_lookup[b_id]
		var length := a.distance_to(b)
		if length <= EPSILON:
			continue

		var road_class := str(edge.get("class", road.get("class", "local")))
		var weight := _road_weight(road_class) if prefer_major_roads else 1.0
		_add_connection(
			adjacency,
			a_id,
			b_id,
			length,
			length * weight,
			edge_id,
			road_id
		)
		_add_connection(
			adjacency,
			b_id,
			a_id,
			length,
			length * weight,
			edge_id,
			road_id
		)
		edge_lookup[edge_id] = edge

	var start_edge_id := str(start_snap.get("edge_id", ""))
	var end_edge_id := str(end_snap.get("edge_id", ""))
	if not edge_lookup.has(start_edge_id):
		return _failed_route("start_edge_unavailable")
	if not edge_lookup.has(end_edge_id):
		return _failed_route("end_edge_unavailable")

	var start_id := "__route_start"
	var end_id := "__route_end"
	adjacency[start_id] = []
	adjacency[end_id] = []

	if not _attach_virtual_snap(
		adjacency,
		start_id,
		start_snap,
		prefer_major_roads
	):
		return _failed_route("start_edge_unavailable")
	if not _attach_virtual_snap(
		adjacency,
		end_id,
		end_snap,
		prefer_major_roads
	):
		return _failed_route("end_edge_unavailable")

	if str(start_snap.get("edge_id", "")) == str(end_snap.get("edge_id", "")):
		var direct_length := absf(
			float(start_snap.get("t", 0.0)) - float(end_snap.get("t", 0.0))
		) * float(start_snap.get("edge_length", 0.0))
		var direct_weight := (
			_road_weight(str(start_snap.get("road_class", "local")))
			if prefer_major_roads
			else 1.0
		)
		_add_connection(
			adjacency,
			start_id,
			end_id,
			direct_length,
			direct_length * direct_weight,
			str(start_snap.get("edge_id", "")),
			str(start_snap.get("road_id", ""))
		)
		_add_connection(
			adjacency,
			end_id,
			start_id,
			direct_length,
			direct_length * direct_weight,
			str(start_snap.get("edge_id", "")),
			str(start_snap.get("road_id", ""))
		)

	var search := _dijkstra(adjacency, start_id, end_id)
	if not bool(search.get("success", false)):
		return _failed_route("no_path")

	var path_ids: Array[String] = search["path"]
	var previous: Dictionary = search["previous"]
	var virtual_positions := {
		start_id: _snap_point(start_snap),
		end_id: _snap_point(end_snap),
	}
	var points: Array[Vector2] = []
	for node_id in path_ids:
		var point: Vector2
		if virtual_positions.has(node_id):
			point = virtual_positions[node_id]
		elif node_lookup.has(node_id):
			point = node_lookup[node_id]
		else:
			continue
		if points.is_empty() or points.back().distance_to(point) > EPSILON:
			points.append(point)

	var route_edges: Array[Dictionary] = []
	var road_ids: Array[String] = []
	var total_length := 0.0
	for index in range(1, path_ids.size()):
		var node_id := path_ids[index]
		var step: Dictionary = previous.get(node_id, {})
		if step.is_empty():
			continue
		var road_id := str(step.get("road_id", ""))
		var edge_id := str(step.get("edge_id", ""))
		var length := float(step.get("length", 0.0))
		total_length += length
		route_edges.append({
			"edge_id": edge_id,
			"road_id": road_id,
			"length": length,
			"from": str(step.get("from", "")),
			"to": node_id,
		})
		if not road_id.is_empty() and not road_ids.has(road_id):
			road_ids.append(road_id)

	return {
		"success": true,
		"reason": "",
		"points": points,
		"length": total_length,
		"cost": float(search.get("cost", total_length)),
		"node_path": path_ids,
		"edge_path": route_edges,
		"road_ids": road_ids,
		"start_snap": start_snap.duplicate(true),
		"end_snap": end_snap.duplicate(true),
	}

static func _attach_virtual_snap(
	adjacency: Dictionary,
	virtual_id: String,
	snap: Dictionary,
	prefer_major_roads: bool
) -> bool:
	var a_id := str(snap.get("a", ""))
	var b_id := str(snap.get("b", ""))
	if not adjacency.has(a_id) or not adjacency.has(b_id):
		return false

	var edge_length := float(snap.get("edge_length", 0.0))
	var t := clampf(float(snap.get("t", 0.0)), 0.0, 1.0)
	var to_a := edge_length * t
	var to_b := edge_length * (1.0 - t)
	var edge_id := str(snap.get("edge_id", ""))
	var road_id := str(snap.get("road_id", ""))
	var weight := (
		_road_weight(str(snap.get("road_class", "local")))
		if prefer_major_roads
		else 1.0
	)

	_add_connection(adjacency, virtual_id, a_id, to_a, to_a * weight, edge_id, road_id)
	_add_connection(adjacency, a_id, virtual_id, to_a, to_a * weight, edge_id, road_id)
	_add_connection(adjacency, virtual_id, b_id, to_b, to_b * weight, edge_id, road_id)
	_add_connection(adjacency, b_id, virtual_id, to_b, to_b * weight, edge_id, road_id)
	return true

static func _dijkstra(
	adjacency: Dictionary,
	start_id: String,
	end_id: String
) -> Dictionary:
	var distance: Dictionary = {}
	var previous: Dictionary = {}
	var open: Array[String] = []

	for node_id_value in adjacency.keys():
		var node_id := str(node_id_value)
		distance[node_id] = INF
		open.append(node_id)
	distance[start_id] = 0.0

	while not open.is_empty():
		var best_index := -1
		var current_id := ""
		var current_cost := INF
		for index in range(open.size()):
			var candidate_id := open[index]
			var candidate_cost := float(distance.get(candidate_id, INF))
			if candidate_cost < current_cost:
				current_cost = candidate_cost
				current_id = candidate_id
				best_index = index

		if best_index < 0 or current_cost == INF:
			break
		open.remove_at(best_index)
		if current_id == end_id:
			break

		for connection_value in adjacency.get(current_id, []):
			var connection: Dictionary = connection_value
			var neighbor := str(connection.get("to", ""))
			if not distance.has(neighbor):
				continue
			var alternate := current_cost + float(connection.get("cost", 0.0))
			if alternate + EPSILON >= float(distance[neighbor]):
				continue
			distance[neighbor] = alternate
			previous[neighbor] = {
				"from": current_id,
				"edge_id": str(connection.get("edge_id", "")),
				"road_id": str(connection.get("road_id", "")),
				"length": float(connection.get("length", 0.0)),
			}

	if not previous.has(end_id) and start_id != end_id:
		return {"success": false}

	var reverse_path: Array[String] = [end_id]
	var cursor := end_id
	while cursor != start_id:
		if not previous.has(cursor):
			return {"success": false}
		cursor = str(previous[cursor].get("from", ""))
		reverse_path.append(cursor)
	reverse_path.reverse()

	return {
		"success": true,
		"path": reverse_path,
		"previous": previous,
		"cost": float(distance.get(end_id, 0.0)),
	}

static func _add_connection(
	adjacency: Dictionary,
	from_id: String,
	to_id: String,
	length: float,
	cost: float,
	edge_id: String,
	road_id: String
) -> void:
	if not adjacency.has(from_id):
		adjacency[from_id] = []
	var connections: Array = adjacency[from_id]
	connections.append({
		"to": to_id,
		"length": maxf(0.0, length),
		"cost": maxf(0.0, cost),
		"edge_id": edge_id,
		"road_id": road_id,
	})
	adjacency[from_id] = connections

static func _road_weight(road_class: String) -> float:
	match road_class:
		"arterial":
			return 0.92
		"collector":
			return 0.98
		"local":
			return 1.06
		"service":
			return 1.16
		_:
			return 1.0

static func _node_lookup(city: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for node_value in city.get("nodes", []):
		var node: Dictionary = node_value
		result[str(node.get("id", ""))] = Vector2(
			float(node.get("x", 0.0)),
			float(node.get("y", 0.0))
		)
	return result

static func _road_lookup(city: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		result[str(road.get("id", ""))] = road
	return result

static func _closest_point_on_segment(
	point: Vector2,
	a: Vector2,
	b: Vector2
) -> Dictionary:
	var ab := b - a
	var length_squared := ab.length_squared()
	if length_squared <= EPSILON:
		return {
			"point": a,
			"t": 0.0,
			"distance": point.distance_to(a),
		}

	var t := clampf((point - a).dot(ab) / length_squared, 0.0, 1.0)
	var projection := a + ab * t
	return {
		"point": projection,
		"t": t,
		"distance": point.distance_to(projection),
	}

static func _snap_point(snap: Dictionary) -> Vector2:
	if snap.has("point") and snap["point"] is Vector2:
		return snap["point"]
	return Vector2(
		float(snap.get("x", 0.0)),
		float(snap.get("y", 0.0))
	)

static func _failed_route(reason: String) -> Dictionary:
	return {
		"success": false,
		"reason": reason,
		"points": [],
		"length": 0.0,
		"cost": INF,
		"node_path": [],
		"edge_path": [],
		"road_ids": [],
	}
