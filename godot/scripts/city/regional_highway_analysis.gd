extends RefCounted
class_name RegionalHighwayAnalysis

const Data = preload("res://scripts/core/game_data.gd")
const RoadTopology = preload("res://scripts/city/road_topology.gd")

const EPSILON := 0.000001
const DEFAULT_BPR_ALPHA := 0.15
const DEFAULT_BPR_BETA := 4.0
const PROJECT_CAPACITY_VPH := {
	"bypass": 2400.0,
	"expressway": 4200.0,
	"motorway": 6200.0,
	"ring_road": 3200.0,
}
const PROJECT_BUILD_MULTIPLIER := {
	"bypass": 1.35,
	"expressway": 2.20,
	"motorway": 3.20,
	"ring_road": 1.65,
}
const PROJECT_MAINTENANCE_PER_KM_MINUTE := {
	"bypass": 0.075,
	"expressway": 0.110,
	"motorway": 0.150,
	"ring_road": 0.085,
}


## Uses the final assigned OD paths from Traffic Core to describe what kind of
## demand actually occupies one strategic corridor. The OD flow is used only to
## derive shares; absolute volumes are scaled back to the measured road flow so
## MSA assignment and proposal diagnostics stay consistent.
static func corridor_flow_composition(
	city: Dictionary,
	road: Dictionary,
	a_id: String,
	b_id: String
) -> Dictionary:
	var traffic_value: Variant = road.get("traffic", {})
	var traffic: Dictionary = traffic_value if typeof(traffic_value) == TYPE_DICTIONARY else {}
	var measured_flow := maxf(0.0, float(traffic.get("flow_vph", 0.0)))
	var road_id := str(road.get("id", ""))
	var snapshot_value: Variant = city.get("road_traffic", {})
	if road_id.is_empty() or typeof(snapshot_value) != TYPE_DICTIONARY:
		return _empty_composition(measured_flow)
	var snapshot: Dictionary = snapshot_value
	var od_value: Variant = snapshot.get("od_results", [])
	if typeof(od_value) != TYPE_ARRAY:
		return _empty_composition(measured_flow)

	var node_to_settlement := _node_to_settlement_lookup(city)
	var raw_local := 0.0
	var raw_regional := 0.0
	var raw_through := 0.0
	var raw_total := 0.0
	for row_value in od_value:
		if typeof(row_value) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_value
		if not bool(row.get("assigned", false)):
			continue
		var route_roads_value: Variant = row.get("road_ids", [])
		if typeof(route_roads_value) != TYPE_ARRAY or not (route_roads_value as Array).has(road_id):
			continue
		var flow := maxf(0.0, float(row.get("vehicle_trips_per_hour", 0.0)))
		if flow <= EPSILON:
			continue
		var origin := _resolve_settlement_id(str(row.get("origin_node", "")), node_to_settlement)
		var destination := _resolve_settlement_id(str(row.get("destination_node", "")), node_to_settlement)
		if origin.is_empty() or destination.is_empty():
			continue
		var origin_incident := origin in [a_id, b_id]
		var destination_incident := destination in [a_id, b_id]
		if origin_incident and destination_incident:
			raw_local += flow
		elif origin_incident or destination_incident:
			raw_regional += flow
		else:
			raw_through += flow
		raw_total += flow

	if raw_total <= EPSILON:
		return _empty_composition(measured_flow)
	var local_share := raw_local / raw_total
	var regional_share := raw_regional / raw_total
	var through_share := raw_through / raw_total
	return {
		"available": true,
		"measured_flow_vph": measured_flow,
		"routed_sample_vph": raw_total,
		"local_share": local_share,
		"regional_share": regional_share,
		"through_share": through_share,
		"local_vph": measured_flow * local_share,
		"regional_vph": measured_flow * regional_share,
		"through_vph": measured_flow * through_share,
	}


## Bypass pressure is slightly reduced for overwhelmingly local demand and
## strengthened for true through traffic. The range is deliberately narrow so
## Traffic Core V1 thresholds remain compatible rather than being rebalanced.
static func strategic_pressure_multiplier(composition: Dictionary) -> float:
	if not bool(composition.get("available", false)):
		return 1.0
	var regional := clampf(float(composition.get("regional_share", 0.0)), 0.0, 1.0)
	var through := clampf(float(composition.get("through_share", 0.0)), 0.0, 1.0)
	return clampf(0.82 + regional * 0.23 + through * 0.40, 0.82, 1.22)


static func estimate_relief_benefit(
	road: Dictionary,
	composition: Dictionary,
	project_class: String
) -> Dictionary:
	var traffic_value: Variant = road.get("traffic", {})
	if typeof(traffic_value) != TYPE_DICTIONARY or (traffic_value as Dictionary).is_empty():
		return _empty_benefit()
	var traffic: Dictionary = traffic_value
	var flow := maxf(0.0, float(traffic.get("flow_vph", 0.0)))
	var capacity := maxf(1.0, float(traffic.get("capacity_vph", 1.0)))
	var free_flow := maxf(0.1, float(traffic.get("free_flow_minutes", 0.1)))
	var current_delay := maxf(0.0, float(traffic.get("delay_minutes", 0.0)))
	var diversion_fraction := 0.35
	if bool(composition.get("available", false)):
		diversion_fraction = clampf(
			float(composition.get("local_share", 0.0)) * 0.08
			+ float(composition.get("regional_share", 0.0)) * 0.38
			+ float(composition.get("through_share", 0.0)) * 0.78,
			0.05,
			0.82
		)
	var project_capacity := float(PROJECT_CAPACITY_VPH.get(project_class, PROJECT_CAPACITY_VPH["bypass"]))
	var diverted := minf(flow * diversion_fraction, project_capacity * 0.82)
	var remaining := maxf(0.0, flow - diverted)
	var vc_after := remaining / capacity
	var delay_after := _bpr_delay_minutes(free_flow, vc_after)
	var delay_reduction := maxf(0.0, current_delay - delay_after)
	var vehicle_hours_saved := flow * delay_reduction / 60.0
	var benefit_score := clampf(
		diversion_fraction * 0.35
		+ clampf(delay_reduction / 8.0, 0.0, 1.0) * 0.35
		+ clampf((float(traffic.get("vc_ratio", 0.0)) - vc_after) / 0.8, 0.0, 1.0) * 0.30,
		0.0,
		1.0
	)
	return {
		"available": true,
		"diversion_fraction": diversion_fraction,
		"diverted_vph": diverted,
		"remaining_vph": remaining,
		"vc_ratio_after": vc_after,
		"delay_minutes_after": delay_after,
		"delay_reduction_minutes": delay_reduction,
		"vehicle_hours_saved_per_hour": vehicle_hours_saved,
		"benefit_score": benefit_score,
	}


static func estimate_project_cost(points: Array, project_class: String) -> Dictionary:
	var length_world := RoadTopology.polyline_length(points)
	var length_km := length_world / 1000.0
	var base_rate := float(Data.ECONOMY.get("sandbox_road_cost_per_world_unit", 12.0))
	var multiplier := float(PROJECT_BUILD_MULTIPLIER.get(project_class, PROJECT_BUILD_MULTIPLIER["bypass"]))
	var capex := length_world * base_rate * multiplier
	var maintenance_rate := float(PROJECT_MAINTENANCE_PER_KM_MINUTE.get(
		project_class,
		PROJECT_MAINTENANCE_PER_KM_MINUTE["bypass"]
	))
	return {
		"length_world": length_world,
		"length_km": length_km,
		"construction_cost": capex,
		"maintenance_per_minute": length_km * maintenance_rate,
		"cost_multiplier": multiplier,
	}


static func _bpr_delay_minutes(free_flow_minutes: float, vc_ratio: float) -> float:
	var ratio := minf(maxf(0.0, vc_ratio), 8.0)
	var travel := free_flow_minutes * (1.0 + DEFAULT_BPR_ALPHA * pow(ratio, DEFAULT_BPR_BETA))
	return maxf(0.0, travel - free_flow_minutes)


static func _node_to_settlement_lookup(city: Dictionary) -> Dictionary:
	var settlements: Array[Dictionary] = []
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) == TYPE_DICTIONARY:
			settlements.append(settlement_value)
	var result: Dictionary = {}
	for settlement in settlements:
		var settlement_id := str(settlement.get("id", ""))
		if not settlement_id.is_empty():
			result[settlement_id] = settlement_id
	for node_value in city.get("nodes", []):
		if typeof(node_value) != TYPE_DICTIONARY:
			continue
		var node: Dictionary = node_value
		var node_id := str(node.get("id", ""))
		if node_id.is_empty() or result.has(node_id):
			continue
		var position := Vector2(float(node.get("x", 0.0)), float(node.get("y", 0.0)))
		var best_id := ""
		var best_distance := INF
		for settlement in settlements:
			var settlement_id := str(settlement.get("id", ""))
			var settlement_position: Vector2 = settlement.get("position", Vector2.ZERO)
			var distance := position.distance_squared_to(settlement_position)
			if distance < best_distance:
				best_distance = distance
				best_id = settlement_id
		if not best_id.is_empty():
			result[node_id] = best_id
	return result


static func _resolve_settlement_id(node_id: String, lookup: Dictionary) -> String:
	return str(lookup.get(node_id, ""))


static func _empty_composition(measured_flow: float) -> Dictionary:
	return {
		"available": false,
		"measured_flow_vph": measured_flow,
		"routed_sample_vph": 0.0,
		"local_share": 0.0,
		"regional_share": 0.0,
		"through_share": 0.0,
		"local_vph": 0.0,
		"regional_vph": 0.0,
		"through_vph": 0.0,
	}


static func _empty_benefit() -> Dictionary:
	return {
		"available": false,
		"diversion_fraction": 0.0,
		"diverted_vph": 0.0,
		"remaining_vph": 0.0,
		"vc_ratio_after": 0.0,
		"delay_minutes_after": 0.0,
		"delay_reduction_minutes": 0.0,
		"vehicle_hours_saved_per_hour": 0.0,
		"benefit_score": 0.0,
	}
