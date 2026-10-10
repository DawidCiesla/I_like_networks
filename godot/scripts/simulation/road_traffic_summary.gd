extends RefCounted
class_name RoadTrafficSummary

const EPSILON := 0.000001


## Reduces edge-level traffic state into gameplay-facing network KPIs. The
## values are rates over one modeled hour and can be fed directly to dashboards,
## highway-planning triggers, and balancing telemetry.
static func summarize(traffic_result: Dictionary) -> Dictionary:
	var edge_metrics_value: Variant = traffic_result.get("edge_metrics", {})
	var edge_metrics: Dictionary = edge_metrics_value if typeof(edge_metrics_value) == TYPE_DICTIONARY else {}
	var vehicle_km_per_hour := 0.0
	var vehicle_hours_per_hour := 0.0
	var free_flow_vehicle_hours_per_hour := 0.0
	var max_vc_ratio := 0.0
	var congested_edges := 0
	var severe_edges := 0
	var active_edges := 0

	for edge_id_value in edge_metrics.keys():
		var metrics_value: Variant = edge_metrics[edge_id_value]
		if typeof(metrics_value) != TYPE_DICTIONARY:
			continue
		var metrics: Dictionary = metrics_value
		var flow := maxf(0.0, _finite(metrics.get("flow_vph", 0.0)))
		var length_km := maxf(0.0, _finite(metrics.get("length_km", 0.0)))
		var travel_minutes := maxf(0.0, _finite(metrics.get("travel_time_minutes", 0.0)))
		var free_flow_minutes := maxf(0.0, _finite(metrics.get("free_flow_minutes", 0.0)))
		var vc_ratio := maxf(0.0, _finite(metrics.get("vc_ratio", 0.0)))
		if flow > EPSILON:
			active_edges += 1
		vehicle_km_per_hour += flow * length_km
		vehicle_hours_per_hour += flow * travel_minutes / 60.0
		free_flow_vehicle_hours_per_hour += flow * free_flow_minutes / 60.0
		max_vc_ratio = maxf(max_vc_ratio, vc_ratio)
		if vc_ratio >= 0.85:
			congested_edges += 1
		if vc_ratio >= 1.0:
			severe_edges += 1

	var delay_vehicle_hours_per_hour := maxf(
		0.0,
		vehicle_hours_per_hour - free_flow_vehicle_hours_per_hour
	)
	var totals_value: Variant = traffic_result.get("totals", {})
	var traffic_totals: Dictionary = totals_value if typeof(totals_value) == TYPE_DICTIONARY else {}
	return {
		"vehicle_demand_vph": maxf(0.0, _finite(traffic_totals.get("vehicle_demand_vph", 0.0))),
		"assigned_vehicle_demand_vph": maxf(0.0, _finite(traffic_totals.get("assigned_vehicle_demand_vph", 0.0))),
		"unassigned_vehicle_demand_vph": maxf(0.0, _finite(traffic_totals.get("unassigned_vehicle_demand_vph", 0.0))),
		"vehicle_km_per_hour": vehicle_km_per_hour,
		"vehicle_hours_per_hour": vehicle_hours_per_hour,
		"free_flow_vehicle_hours_per_hour": free_flow_vehicle_hours_per_hour,
		"delay_vehicle_hours_per_hour": delay_vehicle_hours_per_hour,
		"max_vc_ratio": max_vc_ratio,
		"active_edge_count": active_edges,
		"congested_edge_count": congested_edges,
		"severe_edge_count": severe_edges,
	}


static func _finite(value: Variant) -> float:
	if typeof(value) not in [TYPE_FLOAT, TYPE_INT]:
		return 0.0
	var number := float(value)
	return number if is_finite(number) else 0.0
