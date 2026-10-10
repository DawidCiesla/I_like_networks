extends RefCounted
class_name RoadTrafficModel

const RoadProfile = preload("res://scripts/city/road_profile.gd")

const WORLD_UNITS_PER_KM := 1000.0
const EPSILON := 0.000001
const DEFAULT_ITERATIONS := 4
const DEFAULT_BPR_ALPHA := 0.15
const DEFAULT_BPR_BETA := 4.0

# Approximate two-way lane capacities used by the first aggregate traffic pass.
# The model intentionally keeps these values in one place so balancing can be
# changed without touching routing or resident mode-choice code.
const CAPACITY_PER_VEHICLE_LANE_VPH := {
	"service": 450.0,
	"local": 700.0,
	"collector": 1000.0,
	"arterial": 1600.0,
}


## Assigns aggregate vehicle demand to the built road graph and computes a
## deterministic congestion state. Demand rows use graph node IDs:
## {
##   "origin_node": "settlement-a",
##   "destination_node": "settlement-b",
##   "vehicle_trips_per_hour": 420.0,
## }
##
## The solver uses repeated all-or-nothing shortest-path assignment with a
## method-of-successive-averages flow update. Edge travel times are updated with
## a BPR-style volume-delay function after every assignment pass.
static func evaluate(
	city: Dictionary,
	demands: Array,
	options: Dictionary = {}
) -> Dictionary:
	var iterations := maxi(1, int(options.get("iterations", DEFAULT_ITERATIONS)))
	var alpha := maxf(0.0, float(options.get("bpr_alpha", DEFAULT_BPR_ALPHA)))
	var beta := maxf(1.0, float(options.get("bpr_beta", DEFAULT_BPR_BETA)))
	var node_lookup := _node_lookup(city)
	var road_lookup := _road_lookup(city)
	var edge_metrics := _build_edge_metrics(city, node_lookup, road_lookup)
	var adjacency := _build_adjacency(edge_metrics)

	var normalized_demands := _normalize_demands(demands)
	var assigned_flow: Dictionary = {}
	for edge_id_value in edge_metrics.keys():
		assigned_flow[str(edge_id_value)] = 0.0

	for iteration in range(iterations):
		var iteration_flow: Dictionary = {}
		for edge_id_value in edge_metrics.keys():
			iteration_flow[str(edge_id_value)] = 0.0

		for demand in normalized_demands:
			var flow := float(demand["vehicle_trips_per_hour"])
			if flow <= EPSILON:
				continue
			var route := _shortest_path(
				adjacency,
				edge_metrics,
				str(demand["origin_node"]),
				str(demand["destination_node"])
			)
			if not bool(route.get("success", false)):
				continue
			for edge_id_value in route.get("edge_ids", []):
				var edge_id := str(edge_id_value)
				iteration_flow[edge_id] = float(iteration_flow.get(edge_id, 0.0)) + flow

		var step := 1.0 / float(iteration + 1)
		for edge_id_value in edge_metrics.keys():
			var edge_id := str(edge_id_value)
			var previous := float(assigned_flow.get(edge_id, 0.0))
			var target := float(iteration_flow.get(edge_id, 0.0))
			var smoothed := lerpf(previous, target, step)
			assigned_flow[edge_id] = smoothed
			var metrics: Dictionary = edge_metrics[edge_id]
			metrics["flow_vph"] = smoothed
			_update_congestion(metrics, alpha, beta)
			edge_metrics[edge_id] = metrics

	var od_results: Array[Dictionary] = []
	var total_demand := 0.0
	var assigned_demand := 0.0
	for demand in normalized_demands:
		var flow := float(demand["vehicle_trips_per_hour"])
		total_demand += flow
		var route := _shortest_path(
			adjacency,
			edge_metrics,
			str(demand["origin_node"]),
			str(demand["destination_node"])
		)
		var assigned := bool(route.get("success", false)) and flow > EPSILON
		if assigned:
			assigned_demand += flow
		od_results.append({
			"id": str(demand.get("id", "")),
			"origin_node": str(demand["origin_node"]),
			"destination_node": str(demand["destination_node"]),
			"vehicle_trips_per_hour": flow,
			"assigned": assigned,
			"travel_time_minutes": float(route.get("cost", 0.0)) if assigned else 0.0,
			"edge_ids": route.get("edge_ids", []).duplicate(),
			"road_ids": route.get("road_ids", []).duplicate(),
		})

	return {
		"schema_version": 1,
		"iterations": iterations,
		"edge_metrics": edge_metrics,
		"road_metrics": _aggregate_roads(edge_metrics),
		"od_results": od_results,
		"totals": {
			"vehicle_demand_vph": total_demand,
			"assigned_vehicle_demand_vph": assigned_demand,
			"unassigned_vehicle_demand_vph": maxf(0.0, total_demand - assigned_demand),
		},
	}


static func free_flow_edge_metrics(city: Dictionary) -> Dictionary:
	var node_lookup := _node_lookup(city)
	return _build_edge_metrics(city, node_lookup, _road_lookup(city))


static func _build_edge_metrics(
	city: Dictionary,
	node_lookup: Dictionary,
	road_lookup: Dictionary
) -> Dictionary:
	var result: Dictionary = {}
	for edge_value in city.get("graph_edges", []):
		if typeof(edge_value) != TYPE_DICTIONARY:
			continue
		var edge: Dictionary = edge_value
		var edge_id := str(edge.get("id", ""))
		var road_id := str(edge.get("roadId", ""))
		if edge_id.is_empty() or road_id.is_empty() or not road_lookup.has(road_id):
			continue
		var road: Dictionary = road_lookup[road_id]
		if str(road.get("status", "")) != "built":
			continue
		var a_id := str(edge.get("a", ""))
		var b_id := str(edge.get("b", ""))
		if not node_lookup.has(a_id) or not node_lookup.has(b_id):
			continue
		var a: Vector2 = node_lookup[a_id]
		var b: Vector2 = node_lookup[b_id]
		var length_world := a.distance_to(b)
		if length_world <= EPSILON:
			continue

		var road_class := str(edge.get("class", road.get("class", "local")))
		var profile := _road_profile(road, road_class)
		var speed_kph := maxf(1.0, float(profile.get("speed_kph", 30.0)))
		var lane_count := _vehicle_lane_count(profile)
		var capacity_per_lane := float(CAPACITY_PER_VEHICLE_LANE_VPH.get(road_class, 700.0))
		var capacity := maxf(1.0, capacity_per_lane * float(lane_count))
		var free_flow_minutes := (length_world / WORLD_UNITS_PER_KM) / speed_kph * 60.0

		result[edge_id] = {
			"edge_id": edge_id,
			"road_id": road_id,
			"road_class": road_class,
			"a": a_id,
			"b": b_id,
			"length_world": length_world,
			"length_km": length_world / WORLD_UNITS_PER_KM,
			"speed_kph": speed_kph,
			"vehicle_lanes": lane_count,
			"capacity_vph": capacity,
			"free_flow_minutes": free_flow_minutes,
			"flow_vph": 0.0,
			"vc_ratio": 0.0,
			"travel_time_minutes": free_flow_minutes,
			"delay_minutes": 0.0,
			"congestion_level": "free",
		}
	return result


static func _build_adjacency(edge_metrics: Dictionary) -> Dictionary:
	var adjacency: Dictionary = {}
	for edge_id_value in edge_metrics.keys():
		var edge_id := str(edge_id_value)
		var metrics: Dictionary = edge_metrics[edge_id]
		var a := str(metrics["a"])
		var b := str(metrics["b"])
		_add_adjacency(adjacency, a, b, edge_id)
		_add_adjacency(adjacency, b, a, edge_id)
	return adjacency


static func _add_adjacency(
	adjacency: Dictionary,
	from_id: String,
	to_id: String,
	edge_id: String
) -> void:
	if not adjacency.has(from_id):
		adjacency[from_id] = []
	var rows: Array = adjacency[from_id]
	rows.append({"to": to_id, "edge_id": edge_id})
	adjacency[from_id] = rows


static func _shortest_path(
	adjacency: Dictionary,
	edge_metrics: Dictionary,
	start_id: String,
	end_id: String
) -> Dictionary:
	if start_id.is_empty() or end_id.is_empty():
		return {"success": false, "reason": "node_missing"}
	if start_id == end_id:
		return {"success": true, "cost": 0.0, "edge_ids": [], "road_ids": []}
	if not adjacency.has(start_id) or not adjacency.has(end_id):
		return {"success": false, "reason": "node_missing"}

	# The old implementation kept every graph node in an Array and linearly
	# scanned that entire Array to find the next cheapest node. On a regional
	# road graph this made each OD route O(V^2), which was especially expensive
	# because traffic assignment routes every OD pair several times during game
	# startup. A binary min-heap keeps Dijkstra at O((V + E) log V) and avoids
	# blocking the main thread while preserving the exact same edge costs.
	var distance: Dictionary = {start_id: 0.0}
	var previous: Dictionary = {}
	var heap: Array[Dictionary] = []
	_heap_push(heap, {"node": start_id, "cost": 0.0})

	while not heap.is_empty():
		var current := _heap_pop(heap)
		var current_id := str(current.get("node", ""))
		var current_cost := float(current.get("cost", INF))
		if current_cost > float(distance.get(current_id, INF)) + EPSILON:
			continue
		if current_id == end_id:
			break

		for connection_value in adjacency.get(current_id, []):
			var connection: Dictionary = connection_value
			var neighbor := str(connection.get("to", ""))
			var edge_id := str(connection.get("edge_id", ""))
			if neighbor.is_empty() or not edge_metrics.has(edge_id):
				continue
			var edge: Dictionary = edge_metrics[edge_id]
			var alternate := current_cost + float(edge.get("travel_time_minutes", INF))
			if alternate + EPSILON >= float(distance.get(neighbor, INF)):
				continue
			distance[neighbor] = alternate
			previous[neighbor] = {
				"from": current_id,
				"edge_id": edge_id,
			}
			_heap_push(heap, {"node": neighbor, "cost": alternate})

	if not previous.has(end_id):
		return {"success": false, "reason": "no_path"}

	var reverse_edges: Array[String] = []
	var cursor := end_id
	while cursor != start_id:
		if not previous.has(cursor):
			return {"success": false, "reason": "no_path"}
		var step: Dictionary = previous[cursor]
		reverse_edges.append(str(step["edge_id"]))
		cursor = str(step["from"])
	reverse_edges.reverse()

	var road_ids: Array[String] = []
	for edge_id in reverse_edges:
		var road_id := str((edge_metrics[edge_id] as Dictionary).get("road_id", ""))
		if not road_id.is_empty() and not road_ids.has(road_id):
			road_ids.append(road_id)
	return {
		"success": true,
		"cost": float(distance.get(end_id, 0.0)),
		"edge_ids": reverse_edges,
		"road_ids": road_ids,
	}


static func _heap_push(heap: Array[Dictionary], entry: Dictionary) -> void:
	heap.append(entry)
	var index := heap.size() - 1
	while index > 0:
		var parent := int((index - 1) / 2)
		if not _heap_entry_less(heap[index], heap[parent]):
			break
		var swap := heap[parent]
		heap[parent] = heap[index]
		heap[index] = swap
		index = parent


static func _heap_pop(heap: Array[Dictionary]) -> Dictionary:
	if heap.is_empty():
		return {}
	var root := heap[0]
	var last: Dictionary = heap.pop_back()
	if heap.is_empty():
		return root
	heap[0] = last
	var index := 0
	while true:
		var left := index * 2 + 1
		if left >= heap.size():
			break
		var right := left + 1
		var smallest := left
		if right < heap.size() and _heap_entry_less(heap[right], heap[left]):
			smallest = right
		if not _heap_entry_less(heap[smallest], heap[index]):
			break
		var swap := heap[index]
		heap[index] = heap[smallest]
		heap[smallest] = swap
		index = smallest
	return root


static func _heap_entry_less(a: Dictionary, b: Dictionary) -> bool:
	var a_cost := float(a.get("cost", INF))
	var b_cost := float(b.get("cost", INF))
	if not is_equal_approx(a_cost, b_cost):
		return a_cost < b_cost
	return str(a.get("node", "")) < str(b.get("node", ""))


static func _update_congestion(metrics: Dictionary, alpha: float, beta: float) -> void:
	var flow := maxf(0.0, float(metrics.get("flow_vph", 0.0)))
	var capacity := maxf(1.0, float(metrics.get("capacity_vph", 1.0)))
	var free_flow := maxf(0.0, float(metrics.get("free_flow_minutes", 0.0)))
	var ratio := flow / capacity
	# Capping only protects the numerical model from pathological debug inputs;
	# the reported V/C remains the true ratio.
	var delay_ratio := minf(ratio, 8.0)
	var travel := free_flow * (1.0 + alpha * pow(delay_ratio, beta))
	metrics["vc_ratio"] = ratio
	metrics["travel_time_minutes"] = travel
	metrics["delay_minutes"] = maxf(0.0, travel - free_flow)
	metrics["congestion_level"] = _congestion_level(ratio)


static func _congestion_level(vc_ratio: float) -> String:
	if vc_ratio < 0.65:
		return "free"
	if vc_ratio < 0.85:
		return "moderate"
	if vc_ratio < 1.0:
		return "heavy"
	return "severe"


static func _aggregate_roads(edge_metrics: Dictionary) -> Dictionary:
	var accumulators: Dictionary = {}
	for edge_id_value in edge_metrics.keys():
		var metrics: Dictionary = edge_metrics[str(edge_id_value)]
		var road_id := str(metrics.get("road_id", ""))
		if road_id.is_empty():
			continue
		if not accumulators.has(road_id):
			accumulators[road_id] = {
				"road_id": road_id,
				"road_class": str(metrics.get("road_class", "local")),
				"length_km": 0.0,
				"free_flow_minutes": 0.0,
				"travel_time_minutes": 0.0,
				"delay_minutes": 0.0,
				"weighted_flow": 0.0,
				"weight": 0.0,
				"capacity_vph": INF,
				"vc_ratio": 0.0,
			}
		var row: Dictionary = accumulators[road_id]
		var length := maxf(EPSILON, float(metrics.get("length_km", 0.0)))
		row["length_km"] = float(row["length_km"]) + length
		row["free_flow_minutes"] = float(row["free_flow_minutes"]) + float(metrics.get("free_flow_minutes", 0.0))
		row["travel_time_minutes"] = float(row["travel_time_minutes"]) + float(metrics.get("travel_time_minutes", 0.0))
		row["delay_minutes"] = float(row["delay_minutes"]) + float(metrics.get("delay_minutes", 0.0))
		row["weighted_flow"] = float(row["weighted_flow"]) + float(metrics.get("flow_vph", 0.0)) * length
		row["weight"] = float(row["weight"]) + length
		row["capacity_vph"] = minf(float(row["capacity_vph"]), float(metrics.get("capacity_vph", INF)))
		row["vc_ratio"] = maxf(float(row["vc_ratio"]), float(metrics.get("vc_ratio", 0.0)))
		accumulators[road_id] = row

	var result: Dictionary = {}
	for road_id_value in accumulators.keys():
		var road_id := str(road_id_value)
		var row: Dictionary = accumulators[road_id]
		var weight := maxf(EPSILON, float(row["weight"]))
		var ratio := float(row["vc_ratio"])
		result[road_id] = {
			"road_id": road_id,
			"road_class": str(row["road_class"]),
			"length_km": float(row["length_km"]),
			"flow_vph": float(row["weighted_flow"]) / weight,
			"capacity_vph": float(row["capacity_vph"]),
			"vc_ratio": ratio,
			"free_flow_minutes": float(row["free_flow_minutes"]),
			"travel_time_minutes": float(row["travel_time_minutes"]),
			"delay_minutes": float(row["delay_minutes"]),
			"congestion_level": _congestion_level(ratio),
		}
	return result


static func _road_profile(road: Dictionary, road_class: String) -> Dictionary:
	var explicit_value: Variant = road.get("profile", {})
	if typeof(explicit_value) == TYPE_DICTIONARY and not (explicit_value as Dictionary).is_empty():
		return (explicit_value as Dictionary).duplicate(true)
	var base := RoadProfile.base_profile(road_class)
	if not base.is_empty():
		return base
	return {
		"road_class": road_class,
		"speed_kph": 30.0,
		"lanes": [{"type": "vehicle", "direction": "both", "width_m": 3.0}],
	}


static func _vehicle_lane_count(profile: Dictionary) -> int:
	var count := 0
	for lane_value in profile.get("lanes", []):
		if typeof(lane_value) != TYPE_DICTIONARY:
			continue
		var lane: Dictionary = lane_value
		if str(lane.get("type", "")) == "vehicle":
			count += 1
	return maxi(1, count)


static func _normalize_demands(demands: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(demands.size()):
		var value: Variant = demands[index]
		if typeof(value) != TYPE_DICTIONARY:
			continue
		var demand: Dictionary = value
		var origin := str(demand.get("origin_node", demand.get("origin_id", ""))).strip_edges()
		var destination := str(demand.get("destination_node", demand.get("destination_id", ""))).strip_edges()
		if origin.is_empty() or destination.is_empty() or origin == destination:
			continue
		var flow := maxf(0.0, float(demand.get("vehicle_trips_per_hour", demand.get("flow_vph", 0.0))))
		result.append({
			"id": str(demand.get("id", "od-%d" % index)),
			"origin_node": origin,
			"destination_node": destination,
			"vehicle_trips_per_hour": flow,
		})
	return result


static func _node_lookup(city: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for node_value in city.get("nodes", []):
		if typeof(node_value) != TYPE_DICTIONARY:
			continue
		var node: Dictionary = node_value
		var node_id := str(node.get("id", ""))
		if node_id.is_empty():
			continue
		result[node_id] = Vector2(float(node.get("x", 0.0)), float(node.get("y", 0.0)))
	return result


static func _road_lookup(city: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		var road_id := str(road.get("id", ""))
		if not road_id.is_empty():
			result[road_id] = road
	return result
