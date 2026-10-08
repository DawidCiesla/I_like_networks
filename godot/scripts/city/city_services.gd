extends RefCounted
class_name CityServices

## Pure-data service simulation. Utility edges use node IDs (`a` and `b`) and a
## capacity; coverage demand points represent parcels or other weighted places,
## never individual citizens.

const UTILITY_TYPES := ["electricity", "water", "sewage"]
const SERVICE_TYPES := ["healthcare", "education", "fire", "police", "waste", "recreation"]
const EPSILON := 0.000001
const UNBOUNDED_CAPACITY := 1.0e30


## Evaluates a utility graph with `sources`, `edges`, and `consumers` arrays.
## Sources contain `id`, `nodeId`, and `capacity`; edges contain `id`, `a`,
## `b`, and `capacity`; consumers contain `id`, `nodeId`, and `demand`.
## Records may set `active`; otherwise `status` values other than planned,
## queued, or under_construction are treated as active.
static func evaluate_network(network: Dictionary) -> Dictionary:
	var sources: Array = _sorted_records(network.get("sources", []))
	var edges: Array = _sorted_records(network.get("edges", []))
	var consumers: Array = _sorted_records(network.get("consumers", []))
	var adjacency: Dictionary = {}
	var network_nodes: Dictionary = {}
	var source_nodes: Array[String] = []
	var source_capacity := 0.0

	for source in sources:
		if not _is_active(source):
			continue
		var node_id := str(source.get("nodeId", ""))
		if node_id.is_empty():
			continue
		_add_node(network_nodes, adjacency, node_id)
		source_nodes.append(node_id)
		source_capacity += _non_negative(source.get("capacity", 0.0))

	for edge in edges:
		if not _is_active(edge):
			continue
		var a := str(edge.get("a", ""))
		var b := str(edge.get("b", ""))
		if a.is_empty() or b.is_empty():
			continue
		_add_node(network_nodes, adjacency, a)
		_add_node(network_nodes, adjacency, b)
		_add_unique_neighbor(adjacency, a, b)
		_add_unique_neighbor(adjacency, b, a)

	for consumer in consumers:
		var node_id := str(consumer.get("nodeId", ""))
		if not node_id.is_empty():
			_add_node(network_nodes, adjacency, node_id)

	var connected_nodes := _reachable_nodes(adjacency, source_nodes)
	var super_source := _unique_internal_id("__city_services_source__", network_nodes)
	var super_sink := _unique_internal_id("__city_services_sink__", network_nodes)
	var residual: Dictionary = {}
	var all_nodes: Dictionary = network_nodes.duplicate()
	all_nodes[super_source] = true
	all_nodes[super_sink] = true
	for node_value in all_nodes.keys():
		residual[str(node_value)] = {}

	for edge in edges:
		if not _is_active(edge):
			continue
		var a := str(edge.get("a", ""))
		var b := str(edge.get("b", ""))
		if a.is_empty() or b.is_empty():
			continue
		_add_undirected_capacity(residual, a, b, _non_negative(edge.get("capacity", 0.0)))

	for source in sources:
		if not _is_active(source):
			continue
		var node_id := str(source.get("nodeId", ""))
		if node_id.is_empty():
			continue
		_add_capacity(residual, super_source, node_id, _non_negative(source.get("capacity", 0.0)))

	var consumer_flow_nodes: Array[String] = []
	for index in range(consumers.size()):
		var consumer: Dictionary = consumers[index]
		var node_id := str(consumer.get("nodeId", ""))
		var flow_node := _unique_internal_id("__city_services_consumer_%d__" % index, all_nodes)
		all_nodes[flow_node] = true
		residual[flow_node] = {}
		consumer_flow_nodes.append(flow_node)
		if not _is_active(consumer) or node_id.is_empty():
			continue
		var demand := _non_negative(consumer.get("demand", 0.0))
		_add_capacity(residual, node_id, flow_node, demand)
		_add_capacity(residual, flow_node, super_sink, demand)

	_run_max_flow(residual, super_source, super_sink)

	var consumer_statuses: Array[Dictionary] = []
	var status_by_id: Dictionary = {}
	var total_demand := 0.0
	var connected_demand := 0.0
	var served_demand := 0.0
	var connected_count := 0
	for index in range(consumers.size()):
		var consumer: Dictionary = consumers[index]
		var consumer_id := str(consumer.get("id", "consumer-%d" % index))
		var node_id := str(consumer.get("nodeId", ""))
		var requested := _non_negative(consumer.get("demand", 0.0)) if _is_active(consumer) else 0.0
		var connected := _is_active(consumer) and not node_id.is_empty() and connected_nodes.has(node_id)
		var served := 0.0
		if _is_active(consumer):
			var flow_node: String = consumer_flow_nodes[index]
			served = maxf(0.0, float(residual.get(super_sink, {}).get(flow_node, 0.0)))
		served = minf(requested, served)
		var status := "disconnected"
		if connected:
			status = "served" if requested - served <= EPSILON else "capacity_limited"
		var row := {
			"id": consumer_id,
			"nodeId": node_id,
			"connected": connected,
			"requested": requested,
			"served": served,
			"unserved": maxf(0.0, requested - served),
			"coverage": served / requested if requested > EPSILON else 1.0,
			"status": status,
		}
		consumer_statuses.append(row)
		status_by_id[consumer_id] = row
		total_demand += requested
		served_demand += served
		if connected:
			connected_count += 1
			connected_demand += requested

	var network_status := "no_demand"
	if total_demand > EPSILON:
		network_status = "operational" if total_demand - served_demand <= EPSILON else "capacity_limited"
	return {
		"status": network_status,
		"sourceCapacity": source_capacity,
		"requested": total_demand,
		"connectedDemand": connected_demand,
		"served": served_demand,
		"unserved": maxf(0.0, total_demand - served_demand),
		"coverage": served_demand / total_demand if total_demand > EPSILON else 1.0,
		"consumerCount": consumers.size(),
		"connectedConsumerCount": connected_count,
		"consumers": consumer_statuses,
		"consumerStatusById": status_by_id,
	}


## Evaluates all three utility networks in the canonical order. Missing network
## entries are returned as empty, no-demand network results.
static func evaluate_utility_networks(networks: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	for utility_type in UTILITY_TYPES:
		var network: Variant = networks.get(utility_type, {})
		results[utility_type] = evaluate_network(network if typeof(network) == TYPE_DICTIONARY else {})
	return results


## Computes facility catchment and capacity coverage for districts. Each demand
## point is a parcel/block/aggregate location with `districtId`, `x`, `y`, and a
## `demands` dictionary keyed by SERVICE_TYPES. Buildings contain `service`,
## `x`, `y`, `catchmentRadius`, and optional `capacity` (unlimited by default).
## Demand within range is allocated through a deterministic capacity flow, so
## overlapping catchments can share facility capacity without wasting it.
static func evaluate_district_coverage(
	districts: Array,
	demand_points: Array,
	service_buildings: Array
) -> Dictionary:
	var result_by_district: Dictionary = {}
	for district in _sorted_records(districts):
		var district_id := str(district.get("id", ""))
		if district_id.is_empty() or result_by_district.has(district_id):
			continue
		result_by_district[district_id] = _empty_district_coverage(district_id)

	var demand_by_service: Dictionary = {}
	for service_type in SERVICE_TYPES:
		demand_by_service[service_type] = []

	var sorted_demand_points := _sorted_records(demand_points)
	for point_index in range(sorted_demand_points.size()):
		var point: Dictionary = sorted_demand_points[point_index]
		if not _is_active(point):
			continue
		var district_id := str(point.get("districtId", ""))
		if district_id.is_empty():
			continue
		if not result_by_district.has(district_id):
			result_by_district[district_id] = _empty_district_coverage(district_id)
		var point_id := str(point.get("id", "demand-%d" % point_index))
		var position := Vector2(float(point.get("x", 0.0)), float(point.get("y", 0.0)))
		var demands: Variant = point.get("demands", {})
		if typeof(demands) != TYPE_DICTIONARY:
			continue
		for service_type in SERVICE_TYPES:
			var amount := _non_negative(demands.get(service_type, 0.0))
			if amount <= EPSILON:
				continue
			demand_by_service[service_type].append({
				"id": point_id,
				"districtId": district_id,
				"position": position,
				"demand": amount,
			})
			var metrics: Dictionary = result_by_district[district_id]["services"][service_type]
			metrics["demand"] = float(metrics["demand"]) + amount

	var facilities_by_service: Dictionary = {}
	for service_type in SERVICE_TYPES:
		facilities_by_service[service_type] = []
	for building in _sorted_records(service_buildings):
		if not _is_active(building):
			continue
		var service_type := str(building.get("service", ""))
		if not SERVICE_TYPES.has(service_type):
			continue
		facilities_by_service[service_type].append({
			"id": str(building.get("id", "facility")),
			"position": Vector2(float(building.get("x", 0.0)), float(building.get("y", 0.0))),
			"radius": _non_negative(building.get("catchmentRadius", 0.0)),
			"capacity": _non_negative(building.get("capacity", UNBOUNDED_CAPACITY)),
		})

	for service_type in SERVICE_TYPES:
		_allocate_service_demand(
			demand_by_service[service_type],
			facilities_by_service[service_type],
			result_by_district,
			service_type
		)

	for district_id_value in result_by_district.keys():
		var district_result: Dictionary = result_by_district[str(district_id_value)]
		var total := {"demand": 0.0, "withinCatchment": 0.0, "served": 0.0, "uncovered": 0.0}
		for service_type in SERVICE_TYPES:
			var metrics: Dictionary = district_result["services"][service_type]
			var demand := float(metrics["demand"])
			var served := minf(demand, float(metrics["served"]))
			var reachable := minf(demand, float(metrics["withinCatchment"]))
			metrics["served"] = served
			metrics["uncovered"] = maxf(0.0, demand - served)
			metrics["coverage"] = served / demand if demand > EPSILON else 0.0
			if demand <= EPSILON:
				metrics["status"] = "no_demand"
			elif served + EPSILON >= demand:
				metrics["status"] = "covered"
			elif reachable + EPSILON < demand:
				metrics["status"] = "catchment_limited"
			else:
				metrics["status"] = "capacity_limited"
			for metric_key in ["demand", "withinCatchment", "served", "uncovered"]:
				total[metric_key] = float(total[metric_key]) + float(metrics[metric_key])
			var total_service := {
				"demand": demand,
				"withinCatchment": reachable,
				"served": served,
				"uncovered": maxf(0.0, demand - served),
				"coverage": metrics["coverage"],
				"status": metrics["status"],
			}
			district_result["services"][service_type] = total_service
		total["coverage"] = float(total["served"]) / float(total["demand"]) if float(total["demand"]) > EPSILON else 0.0
		total["status"] = "no_demand" if float(total["demand"]) <= EPSILON else ("covered" if float(total["uncovered"]) <= EPSILON else "partially_covered")
		district_result["total"] = total

	var totals := {"services": {}, "total": {"demand": 0.0, "withinCatchment": 0.0, "served": 0.0, "uncovered": 0.0}}
	for service_type in SERVICE_TYPES:
		var service_total := {"demand": 0.0, "withinCatchment": 0.0, "served": 0.0, "uncovered": 0.0}
		for district_id_value in result_by_district.keys():
			var metrics: Dictionary = result_by_district[str(district_id_value)]["services"][service_type]
			for metric_key in ["demand", "withinCatchment", "served", "uncovered"]:
				service_total[metric_key] = float(service_total[metric_key]) + float(metrics[metric_key])
		service_total["coverage"] = float(service_total["served"]) / float(service_total["demand"]) if float(service_total["demand"]) > EPSILON else 0.0
		totals["services"][service_type] = service_total
		for metric_key in ["demand", "withinCatchment", "served", "uncovered"]:
			totals["total"][metric_key] = float(totals["total"][metric_key]) + float(service_total[metric_key])
	totals["total"]["coverage"] = float(totals["total"]["served"]) / float(totals["total"]["demand"]) if float(totals["total"]["demand"]) > EPSILON else 0.0
	return {"districts": result_by_district, "totals": totals}


static func _allocate_service_demand(
	demands: Array,
	facilities: Array,
	result_by_district: Dictionary,
	service_type: String
) -> void:
	var used_ids: Dictionary = {}
	var source_id := _unique_internal_id("__city_services_facility_source__", used_ids)
	used_ids[source_id] = true
	var sink_id := _unique_internal_id("__city_services_demand_sink__", used_ids)
	used_ids[sink_id] = true
	var residual: Dictionary = {source_id: {}, sink_id: {}}
	var facility_flow_nodes: Array[String] = []
	var demand_flow_nodes: Array[String] = []
	var in_catchment_by_demand: Dictionary = {}

	for facility_index in range(facilities.size()):
		var facility_node := _unique_internal_id("__city_services_facility_%d__" % facility_index, used_ids)
		used_ids[facility_node] = true
		facility_flow_nodes.append(facility_node)
		residual[facility_node] = {}
		_add_capacity(residual, source_id, facility_node, float(facilities[facility_index]["capacity"]))

	for demand_index in range(demands.size()):
		var demand_node := _unique_internal_id("__city_services_demand_%d__" % demand_index, used_ids)
		used_ids[demand_node] = true
		demand_flow_nodes.append(demand_node)
		residual[demand_node] = {}
		_add_capacity(residual, demand_node, sink_id, float(demands[demand_index]["demand"]))

	for facility_index in range(facilities.size()):
		var facility: Dictionary = facilities[facility_index]
		var facility_position: Vector2 = facility["position"]
		for demand_index in range(demands.size()):
			var demand: Dictionary = demands[demand_index]
			var demand_position: Vector2 = demand["position"]
			var distance := demand_position.distance_to(facility_position)
			if distance > float(facility["radius"]) + EPSILON:
				continue
			if not in_catchment_by_demand.has(demand_index):
				in_catchment_by_demand[demand_index] = true
				var metrics: Dictionary = result_by_district[str(demand["districtId"])]["services"][service_type]
				metrics["withinCatchment"] = float(metrics["withinCatchment"]) + float(demand["demand"])
			_add_capacity(
				residual,
				facility_flow_nodes[facility_index],
				demand_flow_nodes[demand_index],
				float(demand["demand"])
			)

	_run_max_flow(residual, source_id, sink_id)
	for demand_index in range(demands.size()):
		var demand: Dictionary = demands[demand_index]
		var served := minf(
			float(demand["demand"]),
			float(residual[sink_id].get(demand_flow_nodes[demand_index], 0.0))
		)
		var metrics: Dictionary = result_by_district[str(demand["districtId"])]["services"][service_type]
		metrics["served"] = float(metrics["served"]) + served


static func _empty_district_coverage(district_id: String) -> Dictionary:
	var services: Dictionary = {}
	for service_type in SERVICE_TYPES:
		services[service_type] = {
			"demand": 0.0,
			"withinCatchment": 0.0,
			"served": 0.0,
			"uncovered": 0.0,
			"coverage": 0.0,
			"status": "no_demand",
		}
	return {
		"id": district_id,
		"services": services,
		"total": {"demand": 0.0, "withinCatchment": 0.0, "served": 0.0, "uncovered": 0.0, "coverage": 0.0, "status": "no_demand"},
	}


static func _sorted_records(records: Variant) -> Array:
	var result: Array = []
	if typeof(records) != TYPE_ARRAY:
		return result
	for record in records:
		if typeof(record) == TYPE_DICTIONARY:
			result.append(record)
	result.sort_custom(func(a, b): return str(a.get("id", "")) < str(b.get("id", "")))
	return result


static func _is_active(record: Dictionary) -> bool:
	if record.has("active"):
		return bool(record["active"])
	var status := str(record.get("status", "")).to_lower()
	return status not in ["planned", "queued", "under_construction", "inactive", "closed"]


static func _non_negative(value: Variant) -> float:
	var amount := float(value)
	if not is_finite(amount):
		return 0.0
	return maxf(0.0, amount)


static func _add_node(nodes: Dictionary, adjacency: Dictionary, node_id: String) -> void:
	nodes[node_id] = true
	if not adjacency.has(node_id):
		adjacency[node_id] = []


static func _add_unique_neighbor(adjacency: Dictionary, node_id: String, neighbor_id: String) -> void:
	var neighbors: Array = adjacency[node_id]
	if not neighbors.has(neighbor_id):
		neighbors.append(neighbor_id)


static func _reachable_nodes(adjacency: Dictionary, source_nodes: Array[String]) -> Dictionary:
	var reached: Dictionary = {}
	var queue: Array[String] = []
	for source_id in source_nodes:
		if reached.has(source_id):
			continue
		reached[source_id] = true
		queue.append(source_id)
	var cursor := 0
	while cursor < queue.size():
		var node_id := queue[cursor]
		cursor += 1
		var neighbors: Array = adjacency.get(node_id, []).duplicate()
		neighbors.sort()
		for neighbor_value in neighbors:
			var neighbor_id := str(neighbor_value)
			if reached.has(neighbor_id):
				continue
			reached[neighbor_id] = true
			queue.append(neighbor_id)
	return reached


static func _unique_internal_id(prefix: String, used_ids: Dictionary) -> String:
	var candidate := prefix
	var suffix := 0
	while used_ids.has(candidate):
		suffix += 1
		candidate = "%s%d" % [prefix, suffix]
	return candidate


static func _add_capacity(residual: Dictionary, from_id: String, to_id: String, capacity: float) -> void:
	if not residual.has(from_id):
		residual[from_id] = {}
	if not residual.has(to_id):
		residual[to_id] = {}
	var from_row: Dictionary = residual[from_id]
	var to_row: Dictionary = residual[to_id]
	from_row[to_id] = float(from_row.get(to_id, 0.0)) + capacity
	if not to_row.has(from_id):
		to_row[from_id] = 0.0


static func _add_undirected_capacity(residual: Dictionary, a: String, b: String, capacity: float) -> void:
	_add_capacity(residual, a, b, capacity)
	_add_capacity(residual, b, a, capacity)


static func _run_max_flow(residual: Dictionary, source_id: String, sink_id: String) -> float:
	var total_flow := 0.0
	while true:
		var parent := _find_augmenting_path(residual, source_id, sink_id)
		if parent.is_empty():
			break
		var path: Array[String] = [sink_id]
		var cursor := sink_id
		var bottleneck := UNBOUNDED_CAPACITY
		while cursor != source_id:
			var previous := str(parent[cursor])
			bottleneck = minf(bottleneck, float(residual[previous][cursor]))
			path.push_front(previous)
			cursor = previous
		if bottleneck <= EPSILON:
			break
		for index in range(path.size() - 1):
			var from_id := path[index]
			var to_id := path[index + 1]
			var from_row: Dictionary = residual[from_id]
			var to_row: Dictionary = residual[to_id]
			from_row[to_id] = maxf(0.0, float(from_row.get(to_id, 0.0)) - bottleneck)
			to_row[from_id] = float(to_row.get(from_id, 0.0)) + bottleneck
		total_flow += bottleneck
	return total_flow


static func _find_augmenting_path(residual: Dictionary, source_id: String, sink_id: String) -> Dictionary:
	var parent: Dictionary = {}
	var visited := {source_id: true}
	var queue: Array[String] = [source_id]
	var cursor := 0
	while cursor < queue.size():
		var node_id := queue[cursor]
		cursor += 1
		if node_id == sink_id:
			break
		var row: Dictionary = residual.get(node_id, {})
		var neighbors: Array = row.keys()
		neighbors.sort()
		for neighbor_value in neighbors:
			var neighbor_id := str(neighbor_value)
			if visited.has(neighbor_id) or float(row[neighbor_id]) <= EPSILON:
				continue
			visited[neighbor_id] = true
			parent[neighbor_id] = node_id
			queue.append(neighbor_id)
			if neighbor_id == sink_id:
				return parent
	return parent if visited.has(sink_id) else {}
