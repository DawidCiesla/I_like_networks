extends SceneTree

const Generator = preload("res://scripts/world/region_plan_generator.gd")

const TEST_SEED := 731945
const TEST_BOUNDS := Rect2(Vector2(-2400.0, -1800.0), Vector2(4800.0, 3600.0))
const COMPACT_BOUNDS := Rect2(Vector2(-600.0, -500.0), Vector2(1200.0, 1000.0))
const NODE_INTERSECTION_TOLERANCE := 0.1


func _initialize() -> void:
	var plan := Generator.generate(TEST_SEED, TEST_BOUNDS)
	var repeated := Generator.generate(TEST_SEED, TEST_BOUNDS)
	var different_seed := Generator.generate(TEST_SEED + 1, TEST_BOUNDS)
	var compact := Generator.generate(TEST_SEED + 7, COMPACT_BOUNDS)
	var compact_repeated := Generator.generate(TEST_SEED + 7, COMPACT_BOUNDS)
	var errors: Array[String] = []
	if not bool(plan.get("valid", false)):
		errors.append("generator returned an invalid plan: %s" % str(plan.get("reason", "unknown")))
	if _signature(plan) != _signature(repeated):
		errors.append("same seed and bounds produced different regional plans")
	if _signature(plan) == _signature(different_seed):
		errors.append("changing the seed did not change the regional plan")
	if _signature(compact) != _signature(compact_repeated):
		errors.append("compact region changed for a repeated seed")
	_validate_plan(plan, errors)
	_validate_plan(compact, errors)
	if not errors.is_empty():
		for error in errors:
			push_error(error)
		quit(1)
		return
	print("RegionPlanGenerator: PASS (%d settlements, %d roads, %d bridges)" % [
		(plan["settlements"] as Array).size(),
		(plan["graph_edges"] as Array).size(),
		int(plan["stats"]["bridge_crossing_count"]),
	])
	print("Local morphology: %d streets, %d parcels, %d building anchors" % [
		(plan["local_streets"] as Array).size(),
		(plan["parcels"] as Array).size(),
		(plan["building_anchors"] as Array).size(),
	])
	quit(0)


func _validate_plan(plan: Dictionary, errors: Array[String]) -> void:
	var bounds: Rect2 = plan.get("bounds", TEST_BOUNDS)
	var settlements: Array = plan.get("settlements", [])
	var externals: Array = plan.get("external_connections", [])
	var nodes: Array = plan.get("graph_nodes", [])
	var edges: Array = plan.get("graph_edges", [])
	var local_streets: Array = plan.get("local_streets", [])
	var parcels: Array = plan.get("parcels", [])
	var buildings: Array = plan.get("building_anchors", [])
	if settlements.size() < 3:
		errors.append("expected at least three settlements")
	if externals.size() != 4:
		errors.append("expected one external connection on each side")
	if edges.size() < nodes.size() - 1:
		errors.append("regional network has too few roads to connect its nodes")
	if local_streets.size() < settlements.size() * 2:
		errors.append("local street network is too sparse to establish settlement morphology")
	if buildings.size() < settlements.size() * 3 or parcels.size() != buildings.size():
		errors.append("settlement building and parcel anchors are missing or unpaired")
	var node_lookup: Dictionary = {}
	for node in nodes:
		node_lookup[str(node["id"])] = node["position"]
		if not _inside_bounds(bounds, node["position"]):
			errors.append("node %s falls outside the requested bounds" % str(node["id"]))
	var adjacency: Dictionary = {}
	for node_id in node_lookup.keys():
		adjacency[node_id] = []
	var edge_ids: Dictionary = {}
	var edge_lookup: Dictionary = {}
	var maximum_route_length := bounds.size.length() * 6.0
	for edge in edges:
		var edge_id := str(edge.get("id", ""))
		if edge_ids.has(edge_id):
			errors.append("duplicate road id %s" % edge_id)
		edge_ids[edge_id] = true
		edge_lookup[edge_id] = edge
		var a := str(edge.get("a", ""))
		var b := str(edge.get("b", ""))
		if not node_lookup.has(a) or not node_lookup.has(b):
			errors.append("road %s refers to a missing graph node" % edge_id)
			continue
		adjacency[a].append(b)
		adjacency[b].append(a)
		var points: Array = edge.get("points", [])
		if points.size() < 2:
			errors.append("road %s has fewer than two path points" % edge_id)
			continue
		if points[0].distance_to(node_lookup[a]) > 0.01 or points.back().distance_to(node_lookup[b]) > 0.01:
			errors.append("road %s does not terminate at its graph nodes" % edge_id)
		for point in points:
			if not _inside_bounds(bounds, point):
				errors.append("road %s leaves the requested bounds" % edge_id)
				break
		if float(edge.get("length", INF)) > maximum_route_length:
			errors.append("road %s exceeds the bounded route-length limit" % edge_id)
	var seen: Dictionary = {}
	var queue: Array[String] = []
	if not nodes.is_empty():
		var first_id := str(nodes[0]["id"])
		seen[first_id] = true
		queue.append(first_id)
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for neighbor in adjacency[current]:
			if seen.has(neighbor):
				continue
			seen[neighbor] = true
			queue.append(neighbor)
	if seen.size() != nodes.size():
		errors.append("regional road graph is not connected")
	var loop_count := 0
	for edge in edges:
		if str(edge.get("role", "")) == "loop":
			loop_count += 1
	if loop_count < 1 or loop_count > 2:
		errors.append("expected one or two deliberate regional road loops")
	_validate_local_morphology(
		bounds, settlements, local_streets, parcels, buildings, node_lookup, edge_lookup, errors
	)


func _validate_local_morphology(
	bounds: Rect2,
	settlements: Array,
	local_streets: Array,
	parcels: Array,
	buildings: Array,
	node_lookup: Dictionary,
	edge_lookup: Dictionary,
	errors: Array[String]
) -> void:
	var settlement_lookup: Dictionary = {}
	var street_counts: Dictionary = {}
	var building_counts: Dictionary = {}
	var parcel_lookup: Dictionary = {}
	var building_ids: Dictionary = {}
	var parcel_ids: Dictionary = {}
	var street_ids: Dictionary = {}
	for settlement in settlements:
		var settlement_id := str(settlement["id"])
		settlement_lookup[settlement_id] = settlement
		street_counts[settlement_id] = 0
		building_counts[settlement_id] = 0
	for street in local_streets:
		var street_id := str(street.get("id", ""))
		var settlement_id := str(street.get("settlement_id", ""))
		if street_ids.has(street_id):
			errors.append("duplicate local street id %s" % street_id)
		street_ids[street_id] = true
		if not settlement_lookup.has(settlement_id):
			errors.append("local street %s has no owning settlement" % street_id)
			continue
		if str(street.get("role", "")) != "local_street" or str(street.get("class", "")) != "local":
			errors.append("local street %s is missing its local road classification" % street_id)
		street_counts[settlement_id] += 1
		if not node_lookup.has(str(street.get("a", ""))) or not node_lookup.has(str(street.get("b", ""))):
			errors.append("local street %s has an invalid graph endpoint" % street_id)
		var expected_prefix := "local-road-%s-" % settlement_id
		if not street_id.begins_with(expected_prefix):
			errors.append("local street %s does not use a settlement-derived persistent id" % street_id)
		var street_points: Array = street.get("points", [])
		for other_id in edge_lookup.keys():
			if str(other_id) == street_id:
				continue
			var other_edge: Dictionary = edge_lookup[other_id]
			var allowed_points: Array[Vector2] = _shared_endpoint_positions(street, other_edge, node_lookup)
			if _paths_cross_away_from_allowed_points(
				street_points,
				other_edge.get("points", []),
				allowed_points
			):
				errors.append("local street %s creates an unmodeled road intersection with %s" % [street_id, str(other_id)])
				break
	for settlement_id in settlement_lookup:
		if int(street_counts.get(settlement_id, 0)) < 2:
			errors.append("settlement %s has fewer than two local streets" % settlement_id)
	for parcel in parcels:
		var parcel_id := str(parcel.get("id", ""))
		if parcel_ids.has(parcel_id):
			errors.append("duplicate parcel id %s" % parcel_id)
		parcel_ids[parcel_id] = true
		parcel_lookup[str(parcel.get("building_id", ""))] = parcel
		var settlement_id := str(parcel.get("settlement_id", ""))
		if not settlement_lookup.has(settlement_id) or not parcel_id.begins_with("parcel-%s-" % settlement_id):
			errors.append("parcel %s has no stable settlement-derived id" % parcel_id)
		if not street_ids.has(str(parcel.get("street_id", ""))):
			errors.append("parcel %s is not attached to a generated local street" % parcel_id)
		if not bounds.has_point(parcel["position"]):
			errors.append("parcel %s falls outside the requested bounds" % parcel_id)
	for building in buildings:
		var building_id := str(building.get("id", ""))
		if building_ids.has(building_id):
			errors.append("duplicate building id %s" % building_id)
		building_ids[building_id] = true
		var settlement_id := str(building.get("settlement_id", ""))
		if not settlement_lookup.has(settlement_id) or not building_id.begins_with("building-%s-" % settlement_id):
			errors.append("building %s has no stable settlement-derived id" % building_id)
		if not parcel_lookup.has(building_id):
			errors.append("building %s has no paired parcel anchor" % building_id)
		if not bounds.has_point(building["position"]):
			errors.append("building %s falls outside the requested bounds" % building_id)
		building_counts[settlement_id] = int(building_counts.get(settlement_id, 0)) + 1
	for settlement_id in settlement_lookup:
		if int(building_counts.get(settlement_id, 0)) < 3:
			errors.append("settlement %s has fewer than three building anchors" % settlement_id)


func _shared_endpoint_positions(
	first: Dictionary,
	second: Dictionary,
	node_lookup: Dictionary
) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var first_nodes := [str(first.get("a", "")), str(first.get("b", ""))]
	var second_nodes := [str(second.get("a", "")), str(second.get("b", ""))]
	for node_id in first_nodes:
		if node_id in second_nodes and node_lookup.has(node_id):
			result.append(node_lookup[node_id])
	return result


func _paths_cross_away_from_allowed_points(
	first: Array,
	second: Array,
	allowed_points: Array[Vector2]
) -> bool:
	for first_index in range(1, first.size()):
		var first_a: Vector2 = first[first_index - 1]
		var first_b: Vector2 = first[first_index]
		for second_index in range(1, second.size()):
			var second_a: Vector2 = second[second_index - 1]
			var second_b: Vector2 = second[second_index]
			for crossing in _intersection_points(first_a, first_b, second_a, second_b):
				var allowed := false
				for allowed_point in allowed_points:
					if crossing.distance_to(allowed_point) <= NODE_INTERSECTION_TOLERANCE:
						allowed = true
						break
				if allowed:
					continue
				return true
	return false


func _intersection_points(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var first_direction := b - a
	var second_direction := d - c
	var denominator := first_direction.cross(second_direction)
	var offset := c - a
	if absf(denominator) > 0.00001:
		var t := offset.cross(second_direction) / denominator
		var u := offset.cross(first_direction) / denominator
		if t >= -0.00001 and t <= 1.00001 and u >= -0.00001 and u <= 1.00001:
			result.append(a + first_direction * clampf(t, 0.0, 1.0))
		return result
	if absf(offset.cross(first_direction)) > 0.001:
		return result
	for point in [a, b, c, d]:
		var candidate: Vector2 = point
		if _point_on_segment(candidate, a, b) and _point_on_segment(candidate, c, d):
			var duplicate := false
			for existing in result:
				if existing.distance_to(candidate) <= 0.001:
					duplicate = true
					break
			if not duplicate:
				result.append(candidate)
	return result


func _point_on_segment(point: Vector2, start: Vector2, finish: Vector2) -> bool:
	var segment := finish - start
	var relative := point - start
	if absf(segment.cross(relative)) > 0.01:
		return false
	var dot := relative.dot(segment)
	if dot < -0.01:
		return false
	return dot <= segment.length_squared() + 0.01


func _signature(plan: Dictionary) -> String:
	var parts: Array[String] = []
	for settlement in plan.get("settlements", []):
		var point: Vector2 = settlement["position"]
		parts.append("%s:%.9f:%.9f" % [str(settlement["id"]), point.x, point.y])
	for external in plan.get("external_connections", []):
		var point: Vector2 = external["position"]
		parts.append("%s:%.9f:%.9f" % [str(external["id"]), point.x, point.y])
	for edge in plan.get("graph_edges", []):
		parts.append(str(edge["id"]))
		for point in edge["points"]:
			parts.append("%.9f:%.9f" % [point.x, point.y])
	for parcel in plan.get("parcels", []):
		var parcel_position: Vector2 = parcel["position"]
		parts.append("%s:%.9f:%.9f" % [str(parcel["id"]), parcel_position.x, parcel_position.y])
	for building in plan.get("building_anchors", []):
		var building_position: Vector2 = building["position"]
		parts.append("%s:%.9f:%.9f" % [str(building["id"]), building_position.x, building_position.y])
	return "|".join(parts)


func _inside_bounds(bounds: Rect2, point: Vector2) -> bool:
	return (
		point.x >= bounds.position.x - 0.01
		and point.y >= bounds.position.y - 0.01
		and point.x <= bounds.end.x + 0.01
		and point.y <= bounds.end.y + 0.01
	)