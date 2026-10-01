extends RefCounted
class_name RoadTopology

const EPSILON := 0.000001
const NODE_KEY_SCALE := 10.0

static func road_half_width(road_class: String) -> float:
	match road_class:
		"arterial":
			return 21.0
		"collector":
			return 15.0
		"service":
			return 10.0
		_:
			return 12.0

static func polyline_length(points: Array) -> float:
	var total := 0.0
	for index in range(points.size() - 1):
		total += _to_vec(points[index]).distance_to(_to_vec(points[index + 1]))
	return total

static func closest_point_on_segment(point: Vector2, a: Vector2, b: Vector2) -> Dictionary:
	var ab := b - a
	var length_squared := ab.length_squared()
	if length_squared <= EPSILON:
		return {
			"point": a,
			"t": 0.0,
			"distance": point.distance_to(a),
		}

	var t := clamp((point - a).dot(ab) / length_squared, 0.0, 1.0)
	var projection := a + ab * t
	return {
		"point": projection,
		"t": t,
		"distance": point.distance_to(projection),
	}

static func closest_point_on_road(point: Vector2, road: Dictionary) -> Dictionary:
	var best := {}
	var points: Array = road.get("points", [])

	for segment_index in range(points.size() - 1):
		var candidate := closest_point_on_segment(
			point,
			_to_vec(points[segment_index]),
			_to_vec(points[segment_index + 1])
		)
		if best.is_empty() or float(candidate["distance"]) < float(best["distance"]):
			best = candidate.duplicate(true)
			best["road_id"] = str(road.get("id", ""))
			best["segment_index"] = segment_index

	return best

static func segment_intersection(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Dictionary:
	var r := b - a
	var s := d - c
	var denominator := _cross(r, s)
	if abs(denominator) <= EPSILON:
		return {}

	var qp := c - a
	var t := _cross(qp, s) / denominator
	var u := _cross(qp, r) / denominator

	if t < -EPSILON or t > 1.0 + EPSILON or u < -EPSILON or u > 1.0 + EPSILON:
		return {}

	return {
		"point": a + r * clamp(t, 0.0, 1.0),
		"t": clamp(t, 0.0, 1.0),
		"u": clamp(u, 0.0, 1.0),
	}

static func segment_distance(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> float:
	if not segment_intersection(a, b, c, d).is_empty():
		return 0.0

	return min(
		closest_point_on_segment(a, c, d)["distance"],
		min(
			closest_point_on_segment(b, c, d)["distance"],
			min(
				closest_point_on_segment(c, a, b)["distance"],
				closest_point_on_segment(d, a, b)["distance"]
			)
		)
	)

static func has_parallel_overlap(candidate: Dictionary, roads: Array, clearance: float = 10.0) -> bool:
	var points: Array = candidate.get("points", [])
	for road in roads:
		if str(road.get("id", "")) in candidate.get("parentRoadIds", []):
			continue
		var other_points: Array = road.get("points", [])
		for first_index in range(points.size() - 1):
			var a := _to_vec(points[first_index])
			var b := _to_vec(points[first_index + 1])
			var first_direction := (b - a).normalized()
			for second_index in range(other_points.size() - 1):
				var c := _to_vec(other_points[second_index])
				var d := _to_vec(other_points[second_index + 1])
				var second_direction := (d - c).normalized()
				var dot := abs(first_direction.dot(second_direction))
				if dot < 0.94:
					continue
				var minimum := (
					road_half_width(str(candidate.get("class", "local")))
					+ road_half_width(str(road.get("class", "local")))
					+ clearance
				)
				if segment_distance(a, b, c, d) < minimum:
					return true
	return false

static func compile_graph(roads: Array) -> Dictionary:
	var segment_splits: Dictionary = {}

	for road_index in range(roads.size()):
		var road: Dictionary = roads[road_index]
		var points: Array = road.get("points", [])
		for segment_index in range(points.size() - 1):
			var key := _segment_key(road_index, segment_index)
			segment_splits[key] = [
				{"t": 0.0, "point": _to_vec(points[segment_index])},
				{"t": 1.0, "point": _to_vec(points[segment_index + 1])},
			]

	for first_road_index in range(roads.size()):
		var first: Dictionary = roads[first_road_index]
		var first_points: Array = first.get("points", [])
		for second_road_index in range(first_road_index + 1, roads.size()):
			var second: Dictionary = roads[second_road_index]
			var second_points: Array = second.get("points", [])

			for first_segment in range(first_points.size() - 1):
				var a := _to_vec(first_points[first_segment])
				var b := _to_vec(first_points[first_segment + 1])

				for second_segment in range(second_points.size() - 1):
					var c := _to_vec(second_points[second_segment])
					var d := _to_vec(second_points[second_segment + 1])
					var hit := segment_intersection(a, b, c, d)
					if hit.is_empty():
						continue

					_append_split(
						segment_splits[_segment_key(first_road_index, first_segment)],
						float(hit["t"]),
						hit["point"]
					)
					_append_split(
						segment_splits[_segment_key(second_road_index, second_segment)],
						float(hit["u"]),
						hit["point"]
					)

	var nodes: Array = []
	var node_lookup: Dictionary = {}
	var node_roads: Dictionary = {}
	var graph_edges: Array = []
	var edge_serial := 1

	for road_index in range(roads.size()):
		var road: Dictionary = roads[road_index]
		var points: Array = road.get("points", [])
		for segment_index in range(points.size() - 1):
			var splits: Array = segment_splits[_segment_key(road_index, segment_index)]
			splits.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))

			for split in splits:
				var node_id := _get_or_create_node(nodes, node_lookup, split["point"])
				if not node_roads.has(node_id):
					node_roads[node_id] = []
				if not node_roads[node_id].has(str(road["id"])):
					node_roads[node_id].append(str(road["id"]))

			for split_index in range(splits.size() - 1):
				var first_point: Vector2 = splits[split_index]["point"]
				var second_point: Vector2 = splits[split_index + 1]["point"]
				if first_point.distance_to(second_point) <= 0.5:
					continue
				var a_id := _get_or_create_node(nodes, node_lookup, first_point)
				var b_id := _get_or_create_node(nodes, node_lookup, second_point)
				graph_edges.append({
					"id": "edge-%d" % edge_serial,
					"a": a_id,
					"b": b_id,
					"roadId": road["id"],
					"class": road.get("class", "local"),
					"length": first_point.distance_to(second_point),
				})
				edge_serial += 1

	var junctions: Array = []
	for node in nodes:
		var road_ids: Array = node_roads.get(str(node["id"]), [])
		node["roadIds"] = road_ids
		if road_ids.size() >= 2:
			junctions.append({
				"id": "junction-%s" % str(node["id"]),
				"nodeId": node["id"],
				"x": node["x"],
				"y": node["y"],
				"roadIds": road_ids.duplicate(),
			})

	return {
		"nodes": nodes,
		"graphEdges": graph_edges,
		"junctions": junctions,
	}

static func _append_split(splits: Array, t: float, point: Vector2) -> void:
	for existing in splits:
		if abs(float(existing["t"]) - t) <= 0.0001:
			return
	splits.append({"t": t, "point": point})

static func _get_or_create_node(
	nodes: Array,
	lookup: Dictionary,
	point: Vector2
) -> String:
	var key := "%d:%d" % [
		roundi(point.x * NODE_KEY_SCALE),
		roundi(point.y * NODE_KEY_SCALE),
	]
	if lookup.has(key):
		return str(lookup[key])

	var node_id := "node-%d" % (nodes.size() + 1)
	nodes.append({
		"id": node_id,
		"x": point.x,
		"y": point.y,
		"roadIds": [],
	})
	lookup[key] = node_id
	return node_id

static func _segment_key(road_index: int, segment_index: int) -> String:
	return "%d:%d" % [road_index, segment_index]

static func _cross(a: Vector2, b: Vector2) -> float:
	return a.x * b.y - a.y * b.x

static func _to_vec(value) -> Vector2:
	if value is Vector2:
		return value
	return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
