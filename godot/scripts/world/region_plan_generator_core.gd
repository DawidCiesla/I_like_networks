extends RefCounted
class_name RegionPlanGenerator

const Terrain = preload("res://scripts/world/terrain_model.gd")

const WORLD_LAYERS_PATH := "res://scripts/world/world_layers.gd"
const MAX_GRID_AXIS := 56
const MIN_GRID_AXIS := 8
const MAX_WATER_COST := 40.0
const WATER_THRESHOLD := 0.05
const NEIGHBOR_OFFSETS := [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]
const SETTLEMENT_SITES := [
	{"id": "regional-center", "name": "Regional Center", "tier": "capital", "fraction": Vector2(0.5, 0.5), "population": 42000},
	{"id": "northwest-town", "name": "Northwest Town", "tier": "market", "fraction": Vector2(0.21, 0.22), "population": 12500},
	{"id": "northeast-town", "name": "Northeast Town", "tier": "market", "fraction": Vector2(0.79, 0.22), "population": 11000},
	{"id": "southwest-town", "name": "Southwest Town", "tier": "market", "fraction": Vector2(0.21, 0.78), "population": 9200},
	{"id": "southeast-town", "name": "Southeast Town", "tier": "market", "fraction": Vector2(0.79, 0.78), "population": 10500},
	{"id": "north-village", "name": "North Village", "tier": "village", "fraction": Vector2(0.5, 0.13), "population": 3600},
	{"id": "south-village", "name": "South Village", "tier": "village", "fraction": Vector2(0.5, 0.87), "population": 3100},
]
const EXTERNAL_SIDES := ["north", "east", "south", "west"]

static var _world_layers_script: Script


static func generate(seed: int, bounds: Rect2) -> Dictionary:
	var region := bounds.abs()
	if region.size.x <= 1.0 or region.size.y <= 1.0:
		return {
			"valid": false,
			"reason": "invalid_bounds",
			"seed": seed,
			"bounds": region,
			"settlements": [],
			"external_connections": [],
			"graph_nodes": [],
			"graph_edges": [],
		}

	# Load the optional layer sampler at generation time. This keeps the module
	# usable in projects that only ship TerrainModel.
	if _world_layers_script == null and ResourceLoader.exists(WORLD_LAYERS_PATH):
		_world_layers_script = load(WORLD_LAYERS_PATH) as Script

	var grid := _build_grid(seed, region)
	var region_id := _region_id(seed, region)
	var settlement_count := _settlement_count(region)
	var settlements := _place_settlements(seed, region, region_id, grid, settlement_count)
	var externals := _place_external_connections(seed, region, region_id)
	var nodes: Array[Dictionary] = []
	for settlement in settlements:
		nodes.append({
			"id": settlement["id"],
			"kind": "settlement",
			"position": settlement["position"],
			"tier": settlement["tier"],
		})
	for external in externals:
		nodes.append({
			"id": external["id"],
			"kind": "external_connection",
			"side": external["side"],
			"position": external["position"],
		})

	var selected_edges := _build_hierarchical_edges(nodes, settlements, externals)
	var graph_edges: Array[Dictionary] = []
	for selected in selected_edges:
		var routed := _route_edge(seed, selected, nodes, grid)
		if not bool(routed.get("valid", false)):
			continue
		graph_edges.append(routed)
	var regional_edge_count := graph_edges.size()
	var local_plan := _build_local_morphology(seed, region, settlements, nodes, graph_edges, grid)
	for node in local_plan["nodes"]:
		nodes.append(node)
	for street in local_plan["streets"]:
		graph_edges.append(street)

	var connected := _is_connected(nodes, graph_edges)
	return {
		"valid": connected and not settlements.is_empty(),
		"reason": "" if connected else "network_disconnected",
		"seed": seed,
		"region_id": region_id,
		"bounds": region,
		"settlements": settlements,
		"external_connections": externals,
		"local_streets": local_plan["streets"],
		"parcels": local_plan["parcels"],
		"building_anchors": local_plan["buildings"],
		"graph_nodes": nodes,
		"graph_edges": graph_edges,
		"grid": {
			"columns": int(grid["columns"]),
			"rows": int(grid["rows"]),
			"step": Vector2(grid["step_x"], grid["step_z"]),
		},
		"stats": {
			"settlement_count": settlements.size(),
			"external_connection_count": externals.size(),
			"edge_count": graph_edges.size(),
			"regional_edge_count": regional_edge_count,
			"local_street_count": (local_plan["streets"] as Array).size(),
			"parcel_count": (local_plan["parcels"] as Array).size(),
			"building_anchor_count": (local_plan["buildings"] as Array).size(),
			"bridge_crossing_count": _count_bridge_crossings(graph_edges),
		},
	}


static func _settlement_count(bounds: Rect2) -> int:
	var shortest_side := minf(bounds.size.x, bounds.size.y)
	if shortest_side < 520.0:
		return 3
	if shortest_side < 1800.0:
		return 5
	if shortest_side < 3600.0:
		return 6
	return SETTLEMENT_SITES.size()


static func _region_id(seed: int, bounds: Rect2) -> String:
	var signature := "%d|%.8f|%.8f|%.8f|%.8f" % [
		seed, bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y,
	]
	return "region-%08x" % _stable_text_hash(signature)


static func _build_grid(seed: int, bounds: Rect2) -> Dictionary:
	var columns := clampi(ceili(bounds.size.x / 95.0) + 1, MIN_GRID_AXIS, MAX_GRID_AXIS)
	var rows := clampi(ceili(bounds.size.y / 95.0) + 1, MIN_GRID_AXIS, MAX_GRID_AXIS)
	var step_x := bounds.size.x / float(columns - 1)
	var step_z := bounds.size.y / float(rows - 1)
	var cell_count := columns * rows
	var costs := PackedFloat32Array()
	var water_depths := PackedFloat32Array()
	var water_kinds := PackedStringArray()
	costs.resize(cell_count)
	water_depths.resize(cell_count)
	water_kinds.resize(cell_count)
	for z in range(rows):
		for x in range(columns):
			var cell_index := z * columns + x
			var point := bounds.position + Vector2(step_x * float(x), step_z * float(z))
			var terrain := _sample_terrain(seed, point)
			var slope := clampf(float(terrain.get("slope_degrees", 0.0)), 0.0, 60.0)
			var forest := clampf(float(terrain.get("forest_potential", 0.0)), 0.0, 1.0)
			var depth := maxf(0.0, float(terrain.get("water_depth", 0.0)))
			var kind := str(terrain.get("water_kind", ""))
			var slope_cost := pow(slope / 12.0, 1.55) * 1.8
			var forest_cost := forest * 0.75
			var water_cost := 0.0
			if depth > WATER_THRESHOLD or (not kind.is_empty() and kind != "none"):
				water_cost = minf(MAX_WATER_COST, 12.0 + depth * 14.0)
			costs[cell_index] = 1.0 + slope_cost + forest_cost + water_cost
			water_depths[cell_index] = depth
			water_kinds[cell_index] = kind
	return {
		"columns": columns,
		"rows": rows,
		"step_x": step_x,
		"step_z": step_z,
		"bounds": bounds,
		"costs": costs,
		"water_depths": water_depths,
		"water_kinds": water_kinds,
	}


static func _sample_terrain(seed: int, point: Vector2) -> Dictionary:
	if _world_layers_script != null and _world_layers_script.has_method("sample"):
		var sampler := "sample_route_terrain" if _world_layers_script.has_method("sample_route_terrain") else "sample"
		var sample_value: Variant = _world_layers_script.call(sampler, seed, point)
		if sample_value is Dictionary:
			var sample: Dictionary = sample_value
			var slope: float = float(sample["slope_degrees"]) if sample.has("slope_degrees") else Terrain.slope_degrees(seed, point.x, point.y)
			var forest: float = float(sample["forest_potential"]) if sample.has("forest_potential") else Terrain.forest_potential(seed, point.x, point.y)
			return {
				"slope_degrees": slope,
				"forest_potential": forest,
				"water_depth": sample.get("water_depth", 0.0),
				"water_kind": sample.get("water_kind", ""),
			}
	return {
		"slope_degrees": Terrain.slope_degrees(seed, point.x, point.y),
		"forest_potential": Terrain.forest_potential(seed, point.x, point.y),
		"water_depth": 0.0,
		"water_kind": "",
	}


static func _place_settlements(
	seed: int,
	bounds: Rect2,
	region_id: String,
	grid: Dictionary,
	settlement_count: int
) -> Array[Dictionary]:
	var sites: Array = SETTLEMENT_SITES.duplicate()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	# A seed-derived rotation gives similarly sized regions different but stable
	# peripheral settlement patterns while keeping the main hub central.
	var peripheral_count := sites.size() - 1
	var rotation := rng.randi_range(0, peripheral_count - 1)
	var ordered: Array[Dictionary] = [sites[0]]
	for offset in range(peripheral_count):
		ordered.append(sites[1 + ((offset + rotation) % peripheral_count)])
	var margin := minf(180.0, minf(bounds.size.x, bounds.size.y) * 0.16)
	var safe_rect := Rect2(bounds.position + Vector2.ONE * margin, bounds.size - Vector2.ONE * margin * 2.0)
	var placed: Array[Dictionary] = []
	var min_spacing := minf(bounds.size.x, bounds.size.y) * 0.21
	for site_index in range(mini(settlement_count, ordered.size())):
		var site: Dictionary = ordered[site_index]
		var fraction: Vector2 = site["fraction"]
		var target := bounds.position + Vector2(bounds.size.x * fraction.x, bounds.size.y * fraction.y)
		var position := _best_settlement_position(seed, target, safe_rect, grid, placed, min_spacing, site_index == 0)
		placed.append({
			"id": "settlement-%s-%s" % [region_id, str(site["id"])],
			"region_id": region_id,
			"name": str(site["name"]),
			"tier": str(site["tier"]),
			"population": int(site["population"]),
			"position": position,
			"role": "regional_hub" if site_index == 0 else "settlement",
		})
	return placed


static func _best_settlement_position(
	seed: int,
	target: Vector2,
	safe_rect: Rect2,
	grid: Dictionary,
	placed: Array[Dictionary],
	min_spacing: float,
	is_hub: bool
) -> Vector2:
	var radius := minf(safe_rect.size.x, safe_rect.size.y) * 0.055
	var best := _clamp_to_rect(target, safe_rect)
	var best_score := INF
	for z_offset in range(-2, 3):
		for x_offset in range(-2, 3):
			var candidate := _clamp_to_rect(
				target + Vector2(float(x_offset), float(z_offset)) * radius * 0.5,
				safe_rect
			)
			var sample := _sample_terrain(seed, candidate)
			var score := float(sample.get("slope_degrees", 0.0)) * 1.7
			score += float(sample.get("forest_potential", 0.0)) * 12.0
			if float(sample.get("water_depth", 0.0)) > WATER_THRESHOLD or str(sample.get("water_kind", "")) not in ["", "none"]:
				score += 10000.0
			score += candidate.distance_to(target) * (0.006 if is_hub else 0.012)
			for other in placed:
				var other_position: Vector2 = other["position"]
				var distance := candidate.distance_to(other_position)
				if distance < min_spacing:
					score += (min_spacing - distance) * 4.0
			if score < best_score:
				best_score = score
				best = candidate
	return best


static func _clamp_to_rect(point: Vector2, rect: Rect2) -> Vector2:
	return Vector2(
		clampf(point.x, rect.position.x, rect.end.x),
		clampf(point.y, rect.position.y, rect.end.y)
	)


static func _place_external_connections(seed: int, bounds: Rect2, region_id: String) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed ^ 0x5f3759df
	var jitter_fraction := 0.12
	var positions := {
		"north": Vector2(
			bounds.position.x + bounds.size.x * clampf(0.5 + (rng.randf() - 0.5) * jitter_fraction, 0.3, 0.7),
			bounds.position.y
		),
		"east": Vector2(
			bounds.end.x,
			bounds.position.y + bounds.size.y * clampf(0.5 + (rng.randf() - 0.5) * jitter_fraction, 0.3, 0.7)
		),
		"south": Vector2(
			bounds.position.x + bounds.size.x * clampf(0.5 + (rng.randf() - 0.5) * jitter_fraction, 0.3, 0.7),
			bounds.end.y
		),
		"west": Vector2(
			bounds.position.x,
			bounds.position.y + bounds.size.y * clampf(0.5 + (rng.randf() - 0.5) * jitter_fraction, 0.3, 0.7)
		),
	}
	var result: Array[Dictionary] = []
	for side in EXTERNAL_SIDES:
		result.append({
			"id": "external-%s-%s" % [region_id, side],
			"region_id": region_id,
			"name": "%s Regional Route" % side.capitalize(),
			"side": side,
			"kind": "rail" if side == "east" else ("utility" if side == "west" else "road"),
			"position": positions[side],
		})
	return result


static func _build_hierarchical_edges(
	nodes: Array[Dictionary],
	settlements: Array[Dictionary],
	externals: Array[Dictionary]
) -> Array[Dictionary]:
	var selected: Array[Dictionary] = []
	var settlement_tree := _settlement_spine(settlements)
	var used_pairs: Dictionary = {}
	for tree_edge in settlement_tree:
		selected.append(tree_edge)
		used_pairs[_pair_key(str(tree_edge["a"]), str(tree_edge["b"]))] = true

	# Each boundary connection joins the closest settlement, making external
	# routes branches off the settlement spine.
	for external in externals:
		var external_position: Vector2 = external["position"]
		var closest_id := ""
		var closest_distance := INF
		for settlement in settlements:
			var distance := external_position.distance_to(settlement["position"])
			var settlement_id := str(settlement["id"])
			if distance < closest_distance or (is_equal_approx(distance, closest_distance) and settlement_id < closest_id):
				closest_distance = distance
				closest_id = settlement_id
		selected.append({
			"id": "road-%s-to-%s" % [str(external["id"]), closest_id],
			"a": str(external["id"]),
			"b": closest_id,
			"class": "primary",
			"role": "external_branch",
		})

	var loop_candidates: Array[Dictionary] = []
	for first_index in range(settlements.size()):
		for second_index in range(first_index + 1, settlements.size()):
			var first: Dictionary = settlements[first_index]
			var second: Dictionary = settlements[second_index]
			var first_id := str(first["id"])
			var second_id := str(second["id"])
			if used_pairs.has(_pair_key(first_id, second_id)):
				continue
			var distance: float = (first["position"] as Vector2).distance_to(second["position"])
			loop_candidates.append({
				"id": "road-%s-to-%s-loop" % [first_id, second_id],
				"a": first_id,
				"b": second_id,
				"class": "secondary",
				"role": "loop",
				"distance": distance,
			})
	loop_candidates.sort_custom(_loop_candidate_less)
	var desired_loops := mini(2, maxi(1, settlements.size() / 3))
	for loop_index in range(mini(desired_loops, loop_candidates.size())):
		selected.append(loop_candidates[loop_index])
	return selected


static func _settlement_spine(settlements: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if settlements.size() < 2:
		return result
	var visited: Array[String] = [str(settlements[0]["id"])]
	var remaining: Array[String] = []
	for settlement in settlements:
		var settlement_id := str(settlement["id"])
		if settlement_id != visited[0]:
			remaining.append(settlement_id)
	remaining.sort()
	while not remaining.is_empty():
		var best_distance := INF
		var best_a := ""
		var best_b := ""
		for a_id in visited:
			var a_position := _settlement_position(settlements, a_id)
			for b_id in remaining:
				var distance := a_position.distance_to(_settlement_position(settlements, b_id))
				var tie_key := a_id + "|" + b_id
				var best_key := best_a + "|" + best_b
				if distance < best_distance or (is_equal_approx(distance, best_distance) and (best_a.is_empty() or tie_key < best_key)):
					best_distance = distance
					best_a = a_id
					best_b = b_id
		var road_class := "primary" if best_a == str(settlements[0]["id"]) or _settlement_tier(settlements, best_b) == "market" else "secondary"
		result.append({
			"id": "road-%s-to-%s-spine" % [best_a, best_b],
			"a": best_a,
			"b": best_b,
			"class": road_class,
			"role": "spine",
		})
		visited.append(best_b)
		remaining.erase(best_b)
	return result


static func _settlement_position(settlements: Array[Dictionary], settlement_id: String) -> Vector2:
	for settlement in settlements:
		if str(settlement["id"]) == settlement_id:
			return settlement["position"]
	return Vector2.ZERO


static func _settlement_tier(settlements: Array[Dictionary], settlement_id: String) -> String:
	for settlement in settlements:
		if str(settlement["id"]) == settlement_id:
			return str(settlement["tier"])
	return "village"


static func _pair_key(first_id: String, second_id: String) -> String:
	var endpoints := [first_id, second_id]
	endpoints.sort()
	return "%s|%s" % [endpoints[0], endpoints[1]]


static func _loop_candidate_less(first: Dictionary, second: Dictionary) -> bool:
	var first_distance := float(first["distance"])
	var second_distance := float(second["distance"])
	if not is_equal_approx(first_distance, second_distance):
		return first_distance < second_distance
	return str(first["id"]) < str(second["id"])


static func _route_edge(seed: int, selected: Dictionary, nodes: Array[Dictionary], grid: Dictionary) -> Dictionary:
	var start_id := str(selected["a"])
	var end_id := str(selected["b"])
	var start := _node_position(nodes, start_id)
	var finish := _node_position(nodes, end_id)
	var start_cell := _cell_at(start, grid)
	var end_cell := _cell_at(finish, grid)
	var search := _astar(start_cell, end_cell, grid)
	if not bool(search.get("valid", false)):
		return {"valid": false}
	var cell_path: Array[int] = search["path"]
	var points := _path_points(start, finish, cell_path, grid)
	var edge_id := str(selected["id"])
	var bridge_crossings := _bridge_crossings(edge_id, cell_path, grid)
	var length := 0.0
	for index in range(1, points.size()):
		length += points[index - 1].distance_to(points[index])
	return {
		"valid": true,
		"id": edge_id,
		"a": start_id,
		"b": end_id,
		"class": str(selected.get("class", "secondary")),
		"role": str(selected.get("role", "spine")),
		"points": points,
		"length": length,
		"terrain_cost": float(search.get("cost", 0.0)),
		"bridge_crossings": bridge_crossings,
	}


static func _node_position(nodes: Array[Dictionary], node_id: String) -> Vector2:
	for node in nodes:
		if str(node["id"]) == node_id:
			return node["position"]
	return Vector2.ZERO


static func _cell_at(point: Vector2, grid: Dictionary) -> int:
	var bounds: Rect2 = grid["bounds"]
	var columns := int(grid["columns"])
	var rows := int(grid["rows"])
	var x := clampi(roundi((point.x - bounds.position.x) / float(grid["step_x"])), 0, columns - 1)
	var z := clampi(roundi((point.y - bounds.position.y) / float(grid["step_z"])), 0, rows - 1)
	return z * columns + x


static func _astar(start_cell: int, end_cell: int, grid: Dictionary) -> Dictionary:
	if start_cell == end_cell:
		var same_cell_path: Array[int] = [start_cell]
		return {"valid": true, "path": same_cell_path, "cost": 0.0}
	var columns := int(grid["columns"])
	var rows := int(grid["rows"])
	var cell_count := columns * rows
	var costs: PackedFloat32Array = grid["costs"]
	var step_x := float(grid["step_x"])
	var step_z := float(grid["step_z"])
	var g_score := PackedFloat32Array()
	g_score.resize(cell_count)
	g_score.fill(INF)
	var came_from := PackedInt32Array()
	came_from.resize(cell_count)
	came_from.fill(-1)
	var closed := PackedByteArray()
	closed.resize(cell_count)
	closed.fill(0)
	var open_heap: Array[Dictionary] = []
	g_score[start_cell] = 0.0
	_heap_push(open_heap, {"cell": start_cell, "g": 0.0, "f": _heuristic(start_cell, end_cell, columns, step_x, step_z)})
	var visit_limit := cell_count
	var visited_count := 0
	while not open_heap.is_empty() and visited_count < visit_limit:
		var current_entry := _heap_pop(open_heap)
		var current := int(current_entry["cell"])
		if closed[current] != 0:
			continue
		if current == end_cell:
			return {
				"valid": true,
				"path": _rebuild_cell_path(came_from, start_cell, end_cell),
				"cost": float(g_score[end_cell]),
			}
		closed[current] = 1
		visited_count += 1
		var current_x: int = current % columns
		var current_z: int = current / columns
		for offset_value in NEIGHBOR_OFFSETS:
			var offset: Vector2i = offset_value
			var neighbor_x: int = current_x + offset.x
			var neighbor_z: int = current_z + offset.y
			if neighbor_x < 0 or neighbor_x >= columns or neighbor_z < 0 or neighbor_z >= rows:
				continue
			var neighbor: int = neighbor_z * columns + neighbor_x
			if closed[neighbor] != 0:
				continue
			var travel_distance := Vector2(float(offset.x) * step_x, float(offset.y) * step_z).length()
			var step_cost := travel_distance * (float(costs[current]) + float(costs[neighbor])) * 0.5
			var candidate_g := float(g_score[current]) + step_cost
			if candidate_g >= float(g_score[neighbor]):
				continue
			came_from[neighbor] = current
			g_score[neighbor] = candidate_g
			var estimate := candidate_g + _heuristic(neighbor, end_cell, columns, step_x, step_z)
			_heap_push(open_heap, {"cell": neighbor, "g": candidate_g, "f": estimate})
	return {"valid": false, "path": [], "cost": INF}


static func _heuristic(cell: int, goal: int, columns: int, step_x: float, step_z: float) -> float:
	var cell_point := Vector2(float(cell % columns) * step_x, float(cell / columns) * step_z)
	var goal_point := Vector2(float(goal % columns) * step_x, float(goal / columns) * step_z)
	return cell_point.distance_to(goal_point)


static func _rebuild_cell_path(came_from: PackedInt32Array, start_cell: int, end_cell: int) -> Array[int]:
	var reversed_path: Array[int] = [end_cell]
	var current := end_cell
	var guard := came_from.size()
	while current != start_cell and guard > 0:
		current = came_from[current]
		if current < 0:
			return []
		reversed_path.append(current)
		guard -= 1
	reversed_path.reverse()
	return reversed_path


static func _heap_less(first: Dictionary, second: Dictionary) -> bool:
	var first_f := float(first["f"])
	var second_f := float(second["f"])
	if not is_equal_approx(first_f, second_f):
		return first_f < second_f
	return int(first["cell"]) < int(second["cell"])


static func _heap_push(heap: Array[Dictionary], value: Dictionary) -> void:
	heap.append(value)
	var child := heap.size() - 1
	while child > 0:
		var parent := (child - 1) / 2
		if not _heap_less(heap[child], heap[parent]):
			break
		var swap := heap[parent]
		heap[parent] = heap[child]
		heap[child] = swap
		child = parent


static func _heap_pop(heap: Array[Dictionary]) -> Dictionary:
	var first := heap[0]
	var last: Dictionary = heap.pop_back()
	if heap.is_empty():
		return first
	heap[0] = last
	var parent := 0
	while true:
		var left := parent * 2 + 1
		var right := left + 1
		var smallest := parent
		if left < heap.size() and _heap_less(heap[left], heap[smallest]):
			smallest = left
		if right < heap.size() and _heap_less(heap[right], heap[smallest]):
			smallest = right
		if smallest == parent:
			break
		var swap := heap[parent]
		heap[parent] = heap[smallest]
		heap[smallest] = swap
		parent = smallest
	return first


static func _grid_point(cell: int, grid: Dictionary) -> Vector2:
	var bounds: Rect2 = grid["bounds"]
	var columns := int(grid["columns"])
	return bounds.position + Vector2(
		float(cell % columns) * float(grid["step_x"]),
		float(cell / columns) * float(grid["step_z"])
	)


static func _path_points(start: Vector2, finish: Vector2, cell_path: Array[int], grid: Dictionary) -> Array[Vector2]:
	var result: Array[Vector2] = [start]
	if cell_path.size() > 1:
		var last_direction := Vector2i.ZERO
		for index in range(1, cell_path.size()):
			var previous_point := _grid_point(cell_path[index - 1], grid)
			var current_point := _grid_point(cell_path[index], grid)
			var delta := current_point - previous_point
			var direction := Vector2i(signf(delta.x), signf(delta.y))
			if direction != last_direction and index > 1:
				var turn_point := previous_point
				if result.back().distance_to(turn_point) > 0.01:
					result.append(turn_point)
			last_direction = direction
		var last_interior_index := cell_path.size() - 2
		if last_interior_index > 0:
			var last_interior_point := _grid_point(cell_path[last_interior_index], grid)
			if result.back().distance_to(last_interior_point) > 0.01:
				result.append(last_interior_point)
	if result.back().distance_to(finish) > 0.01:
		result.append(finish)
	return result


static func _bridge_crossings(edge_id: String, cell_path: Array[int], grid: Dictionary) -> Array[Dictionary]:
	var crossings: Array[Dictionary] = []
	if cell_path.is_empty():
		return crossings
	var depths: PackedFloat32Array = grid["water_depths"]
	var kinds: PackedStringArray = grid["water_kinds"]
	var run_start := -1
	var run_max_depth := 0.0
	var run_kind := "water"
	for path_index in range(cell_path.size() + 1):
		var cell := -1 if path_index == cell_path.size() else cell_path[path_index]
		var in_water := cell >= 0 and (float(depths[cell]) > WATER_THRESHOLD or (not str(kinds[cell]).is_empty() and kinds[cell] != "none"))
		if in_water:
			if run_start < 0:
				run_start = path_index
				run_max_depth = float(depths[cell])
				run_kind = str(kinds[cell]) if not str(kinds[cell]).is_empty() else "water"
			else:
				run_max_depth = maxf(run_max_depth, float(depths[cell]))
		else:
			if run_start >= 0:
				var run_end := path_index - 1
				var water_points: Array[Vector2] = []
				for water_index in range(run_start, run_end + 1):
					water_points.append(_grid_point(cell_path[water_index], grid))
				var from_point := _grid_point(cell_path[maxi(0, run_start - 1)], grid)
				var to_index := mini(cell_path.size() - 1, run_end + 1)
				var to_point := _grid_point(cell_path[to_index], grid)
				crossings.append({
					"id": "%s-bridge-%d" % [edge_id, crossings.size() + 1],
					"water_kind": run_kind,
					"start": from_point,
					"end": to_point,
					"water_points": water_points,
					"cell_count": water_points.size(),
					"max_depth": run_max_depth,
					"length": from_point.distance_to(to_point),
				})
				run_start = -1
	return crossings


static func _build_local_morphology(
	seed: int,
	bounds: Rect2,
	settlements: Array[Dictionary],
	regional_nodes: Array[Dictionary],
	regional_edges: Array[Dictionary],
	grid: Dictionary
) -> Dictionary:
	var local_nodes: Array[Dictionary] = []
	var local_streets: Array[Dictionary] = []
	var for_routing: Array[Dictionary] = []
	for_routing.append_array(regional_edges)
	for settlement in settlements:
		var settlement_id := str(settlement["id"])
		var center: Vector2 = settlement["position"]
		var desired_count := 2 if str(settlement["tier"]) == "village" else 3
		var directions := _ordered_local_directions(seed, settlement_id, regional_edges)
		var built_count := 0
		for direction_data in directions:
			if built_count >= desired_count:
				break
			var direction: Vector2 = direction_data["vector"]
			var endpoint := _best_local_endpoint(seed, center, direction, bounds)
			if endpoint.distance_to(center) < 45.0:
				continue
			var direction_id := str(direction_data["id"])
			var node_id := "street-node-%s-%s" % [settlement_id, direction_id]
			var street_id := "local-road-%s-%s" % [settlement_id, direction_id]
			var street_node := {
				"id": node_id,
				"kind": "street_terminal",
				"settlement_id": settlement_id,
				"position": endpoint,
			}
			var routing_nodes: Array[Dictionary] = []
			routing_nodes.append_array(regional_nodes)
			routing_nodes.append_array(local_nodes)
			routing_nodes.append(street_node)
			var routed := _route_edge(seed, {
				"id": street_id,
				"a": settlement_id,
				"b": node_id,
				"class": "local",
				"role": "local_street",
			}, routing_nodes, grid)
			if not bool(routed.get("valid", false)):
				continue
			if _would_create_unmodeled_intersection(
				routed["points"], for_routing, settlement_id, center,
				0.1
			):
				continue
			routed["settlement_id"] = settlement_id
			routed["direction"] = direction_id
			routed["direction_index"] = int(direction_data["index"])
			local_nodes.append(street_node)
			local_streets.append(routed)
			for_routing.append(routed)
			built_count += 1

	var parcels: Array[Dictionary] = []
	var buildings: Array[Dictionary] = []
	var occupied_positions: Array[Vector2] = []
	for settlement in settlements:
		var settlement_id := str(settlement["id"])
		var settlement_streets: Array[Dictionary] = []
		for street in local_streets:
			if str(street.get("settlement_id", "")) == settlement_id:
				settlement_streets.append(street)
		settlement_streets.sort_custom(_local_street_less)
		for street in settlement_streets:
			for slot_index in range(2):
				var anchor := _best_building_anchor(
					seed, bounds, street, slot_index, occupied_positions, local_streets
				)
				if anchor.is_empty():
					continue
				var direction_id := str(street["direction"])
				var slot_id := "%s-%s-%02d" % [settlement_id, direction_id, slot_index + 1]
				var parcel_id := "parcel-%s" % slot_id
				var building_id := "building-%s" % slot_id
				var building_type := "shop" if slot_index == 0 and str(settlement["tier"]) != "village" else "house"
				var building_position: Vector2 = anchor["position"]
				var access_point: Vector2 = anchor["access_point"]
				var footprint_scale := clampf(minf(bounds.size.x, bounds.size.y) / 800.0, 0.35, 1.0)
				var footprint: Vector2 = (
					Vector2(58.0, 46.0) if building_type == "house" else Vector2(72.0, 58.0)
				) * footprint_scale
				parcels.append({
					"id": parcel_id,
					"settlement_id": settlement_id,
					"street_id": str(street["id"]),
					"position": building_position,
					"access_point": access_point,
					"footprint": footprint,
					"building_id": building_id,
				})
				buildings.append({
					"id": building_id,
					"parcel_id": parcel_id,
					"settlement_id": settlement_id,
					"street_id": str(street["id"]),
					"type": building_type,
					"status": "occupied",
					"position": building_position,
					"facing": (access_point - building_position).normalized(),
					"footprint": footprint,
				})
				occupied_positions.append(building_position)
	return {
		"nodes": local_nodes,
		"streets": local_streets,
		"parcels": parcels,
		"buildings": buildings,
	}


static func _ordered_local_directions(seed: int, settlement_id: String, regional_edges: Array[Dictionary]) -> Array[Dictionary]:
	var choices := [
		{"id": "east", "vector": Vector2(1.0, 0.0)},
		{"id": "southeast", "vector": Vector2(0.70710678, 0.70710678)},
		{"id": "south", "vector": Vector2(0.0, 1.0)},
		{"id": "southwest", "vector": Vector2(-0.70710678, 0.70710678)},
		{"id": "west", "vector": Vector2(-1.0, 0.0)},
		{"id": "northwest", "vector": Vector2(-0.70710678, -0.70710678)},
		{"id": "north", "vector": Vector2(0.0, -1.0)},
		{"id": "northeast", "vector": Vector2(0.70710678, -0.70710678)},
	]
	var occupied_axes: Array[Vector2] = []
	for edge in regional_edges:
		var outward := Vector2.ZERO
		var points: Array = edge.get("points", [])
		if points.size() < 2:
			continue
		if str(edge.get("a", "")) == settlement_id:
			outward = (points[1] as Vector2) - (points[0] as Vector2)
		elif str(edge.get("b", "")) == settlement_id:
			outward = (points[points.size() - 2] as Vector2) - (points.back() as Vector2)
		if outward.length_squared() > 0.01:
			occupied_axes.append(outward.normalized())
	var rotation := posmod(seed ^ _stable_text_hash(settlement_id), choices.size())
	var ranked: Array[Dictionary] = []
	for choice_index in range(choices.size()):
		var choice: Dictionary = choices[choice_index]
		var direction: Vector2 = choice["vector"]
		var clearance := PI * 0.5
		for occupied in occupied_axes:
			var angle := acos(clampf(direction.dot(occupied), -1.0, 1.0))
			clearance = minf(clearance, minf(angle, PI - angle))
		ranked.append({
			"id": choice["id"],
			"vector": direction,
			"index": choice_index,
			"clearance": clearance,
			"tie": posmod(choice_index - rotation, choices.size()),
		})
	ranked.sort_custom(_direction_choice_less)
	return ranked


static func _direction_choice_less(first: Dictionary, second: Dictionary) -> bool:
	var first_clearance := float(first["clearance"])
	var second_clearance := float(second["clearance"])
	if not is_equal_approx(first_clearance, second_clearance):
		return first_clearance > second_clearance
	return int(first["tie"]) < int(second["tie"])


static func _stable_text_hash(text_value: String) -> int:
	var hash_value := 2166136261
	for index in range(text_value.length()):
		hash_value = (hash_value ^ text_value.unicode_at(index)) & 0xffffffff
		hash_value = (hash_value * 16777619) & 0xffffffff
	return hash_value


static func _best_local_endpoint(seed: int, center: Vector2, direction: Vector2, bounds: Rect2) -> Vector2:
	var padding := minf(45.0, minf(bounds.size.x, bounds.size.y) * 0.08)
	var safe_bounds := Rect2(bounds.position + Vector2.ONE * padding, bounds.size - Vector2.ONE * padding * 2.0)
	var shortest_side := minf(bounds.size.x, bounds.size.y)
	var radius := clampf(shortest_side * 0.065, 100.0, 420.0)
	if direction.x > 0.001:
		radius = minf(radius, maxf(0.0, (safe_bounds.end.x - center.x) / direction.x))
	elif direction.x < -0.001:
		radius = minf(radius, maxf(0.0, (center.x - safe_bounds.position.x) / -direction.x))
	if direction.y > 0.001:
		radius = minf(radius, maxf(0.0, (safe_bounds.end.y - center.y) / direction.y))
	elif direction.y < -0.001:
		radius = minf(radius, maxf(0.0, (center.y - safe_bounds.position.y) / -direction.y))
	var target := center + direction * radius
	var side_vector := Vector2(-direction.y, direction.x)
	var best := _clamp_to_rect(target, safe_bounds)
	var best_score := INF
	for lateral_index in range(-2, 3):
		var candidate := _clamp_to_rect(target + side_vector * radius * 0.12 * float(lateral_index), safe_bounds)
		var sample := _sample_terrain(seed, candidate)
		if float(sample.get("water_depth", 0.0)) > WATER_THRESHOLD or str(sample.get("water_kind", "")) not in ["", "none"]:
			continue
		var score := float(sample.get("slope_degrees", 0.0)) * 1.8
		score += float(sample.get("forest_potential", 0.0)) * 9.0
		score += candidate.distance_to(target) * 0.025
		if score < best_score:
			best_score = score
			best = candidate
	return best


static func _would_create_unmodeled_intersection(
	candidate_points: Array,
	existing_edges: Array[Dictionary],
	settlement_id: String,
	settlement_position: Vector2,
	root_clearance: float
) -> bool:
	for edge in existing_edges:
		var existing_points: Array = edge.get("points", [])
		if existing_points.size() < 2:
			continue
		var touches_root := str(edge.get("a", "")) == settlement_id or str(edge.get("b", "")) == settlement_id
		for candidate_index in range(1, candidate_points.size()):
			var candidate_a: Vector2 = candidate_points[candidate_index - 1]
			var candidate_b: Vector2 = candidate_points[candidate_index]
			for existing_index in range(1, existing_points.size()):
				var existing_a: Vector2 = existing_points[existing_index - 1]
				var existing_b: Vector2 = existing_points[existing_index]
				for intersection in _segment_intersections(candidate_a, candidate_b, existing_a, existing_b):
					var crossing: Vector2 = intersection
					if touches_root and crossing.distance_to(settlement_position) <= root_clearance:
						continue
					return true
	return false


static func _segment_intersections(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Array[Vector2]:
	var intersections: Array[Vector2] = []
	var first_direction := b - a
	var second_direction := d - c
	var denominator := first_direction.cross(second_direction)
	var offset := c - a
	if absf(denominator) <= 0.00001:
		if absf(offset.cross(first_direction)) > 0.0001 or first_direction.length_squared() <= 0.0001:
			return intersections
		var first_t := offset.dot(first_direction) / first_direction.length_squared()
		var second_t := (d - a).dot(first_direction) / first_direction.length_squared()
		var overlap_start := maxf(0.0, minf(first_t, second_t))
		var overlap_end := minf(1.0, maxf(first_t, second_t))
		if overlap_end < overlap_start - 0.00001:
			return intersections
		intersections.append(a + first_direction * overlap_start)
		if overlap_end - overlap_start > 0.00001:
			intersections.append(a + first_direction * overlap_end)
		return intersections
	var t := offset.cross(second_direction) / denominator
	var u := offset.cross(first_direction) / denominator
	if t >= -0.00001 and t <= 1.00001 and u >= -0.00001 and u <= 1.00001:
		intersections.append(a + first_direction * clampf(t, 0.0, 1.0))
	return intersections


static func _local_street_less(first: Dictionary, second: Dictionary) -> bool:
	var first_index := int(first.get("direction_index", 0))
	var second_index := int(second.get("direction_index", 0))
	if first_index != second_index:
		return first_index < second_index
	return str(first["id"]) < str(second["id"])


static func _best_building_anchor(
	seed: int,
	bounds: Rect2,
	street: Dictionary,
	slot_index: int,
	occupied_positions: Array[Vector2],
	local_streets: Array[Dictionary]
) -> Dictionary:
	var points: Array = street.get("points", [])
	if points.size() < 2:
		return {}
	var total_length := _polyline_length(points)
	if total_length < 60.0:
		return {}
	var base_fraction := 0.38 if slot_index == 0 else 0.70
	var side := 1.0 if slot_index == 0 else -1.0
	var safe_padding := minf(65.0, minf(bounds.size.x, bounds.size.y) * 0.15)
	var safe_bounds := Rect2(bounds.position + Vector2.ONE * safe_padding, bounds.size - Vector2.ONE * safe_padding * 2.0)
	var best: Dictionary = {}
	var best_score := INF
	for along_offset in [-18.0, 0.0, 18.0]:
		var along := clampf(total_length * base_fraction + float(along_offset), 30.0, total_length - 20.0)
		var street_sample := _point_and_tangent(points, along)
		var access_point: Vector2 = street_sample["point"]
		var tangent: Vector2 = street_sample["tangent"]
		var side_vector := Vector2(-tangent.y, tangent.x) * side
		for lateral_distance in [48.0, 68.0, 88.0]:
			var candidate := _clamp_to_rect(access_point + side_vector * float(lateral_distance), safe_bounds)
			var terrain := _sample_terrain(seed, candidate)
			if float(terrain.get("water_depth", 0.0)) > WATER_THRESHOLD or str(terrain.get("water_kind", "")) not in ["", "none"]:
				continue
			var score := float(terrain.get("slope_degrees", 0.0)) * 1.7
			score += float(terrain.get("forest_potential", 0.0)) * 11.0
			score += absf(float(lateral_distance) - 68.0) * 0.08
			for occupied in occupied_positions:
				var separation := candidate.distance_to(occupied)
				if separation < 72.0:
					score += (72.0 - separation) * 6.0
			for other_street in local_streets:
				if str(other_street["id"]) == str(street["id"]):
					continue
				var road_distance := _distance_to_polyline(candidate, other_street.get("points", []))
				if road_distance < 34.0:
					score = INF
					break
				if road_distance < 48.0:
					score += (48.0 - road_distance) * 8.0
			if score < best_score:
				best_score = score
				best = {"position": candidate, "access_point": access_point}
	return best


static func _polyline_length(points: Array) -> float:
	var length := 0.0
	for index in range(1, points.size()):
		length += (points[index] as Vector2).distance_to(points[index - 1] as Vector2)
	return length


static func _point_and_tangent(points: Array, distance_along: float) -> Dictionary:
	var remaining := distance_along
	for index in range(1, points.size()):
		var start: Vector2 = points[index - 1]
		var finish: Vector2 = points[index]
		var segment_length := start.distance_to(finish)
		if segment_length <= 0.001:
			continue
		if remaining <= segment_length or index == points.size() - 1:
			var tangent := (finish - start).normalized()
			return {"point": start.lerp(finish, clampf(remaining / segment_length, 0.0, 1.0)), "tangent": tangent}
		remaining -= segment_length
	return {"point": points.back(), "tangent": (points.back() - points[points.size() - 2]).normalized()}


static func _distance_to_polyline(point: Vector2, points: Array) -> float:
	var best_distance := INF
	for index in range(1, points.size()):
		var start: Vector2 = points[index - 1]
		var finish: Vector2 = points[index]
		var segment := finish - start
		var denominator := segment.length_squared()
		if denominator <= 0.0001:
			best_distance = minf(best_distance, point.distance_to(start))
			continue
		var amount := clampf((point - start).dot(segment) / denominator, 0.0, 1.0)
		best_distance = minf(best_distance, point.distance_to(start + segment * amount))
	return best_distance


static func _is_connected(nodes: Array[Dictionary], edges: Array[Dictionary]) -> bool:
	if nodes.is_empty():
		return false
	var adjacency: Dictionary = {}
	for node in nodes:
		adjacency[str(node["id"])] = []
	for edge in edges:
		var a := str(edge["a"])
		var b := str(edge["b"])
		if adjacency.has(a) and adjacency.has(b):
			adjacency[a].append(b)
			adjacency[b].append(a)
	var seen: Dictionary = {str(nodes[0]["id"]): true}
	var queue: Array[String] = [str(nodes[0]["id"])]
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for neighbor in adjacency[current]:
			var neighbor_id := str(neighbor)
			if seen.has(neighbor_id):
				continue
			seen[neighbor_id] = true
			queue.append(neighbor_id)
	return seen.size() == nodes.size()


static func _count_bridge_crossings(edges: Array[Dictionary]) -> int:
	var count := 0
	for edge in edges:
		count += (edge.get("bridge_crossings", []) as Array).size()
	return count
