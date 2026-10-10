extends RefCounted
class_name TransitLineHealth

const EPSILON := 0.000001
const CONGESTION_WARNING_FACTOR := 1.25
const SEVERE_CONGESTION_FACTOR := 1.75
const LOAD_WARNING_RATIO := 0.85
const OVERLOAD_RATIO := 1.0
const LONG_HEADWAY_MINUTES := 15.0
const TARGET_HEADWAY_TOLERANCE := 1.15


## Converts raw line operations metrics into a stable gameplay-facing status.
## The output intentionally separates the dominant problem from supporting
## diagnostics so UI/objectives can explain what the player should react to.
static func evaluate(line: Dictionary) -> Dictionary:
	var fleet := maxi(0, int(line.get("fleet_count", 0)))
	var demand_ppm := maxf(0.0, float(line.get("current_demand_ppm", 0.0)))
	var capacity_ppm := maxf(0.0, float(line.get(
		"traffic_effective_capacity_ppm",
		line.get("capacity_ppm", 0.0)
	)))
	var delay_factor := maxf(1.0, float(line.get("traffic_delay_factor", 1.0)))
	var headway := float(line.get("traffic_effective_headway_minutes", INF))
	var crowding_ratio := maxf(0.0, float(line.get("crowding_ratio", 0.0)))
	var utilization := demand_ppm / capacity_ppm if capacity_ppm > EPSILON else (INF if demand_ppm > EPSILON else 0.0)
	var effective_load := maxf(crowding_ratio, utilization if is_finite(utilization) else 0.0)
	var stored_target := float(line.get("target_headway_minutes", 0.0))
	var target_active := stored_target > EPSILON
	var target_headway := stored_target if target_active else LONG_HEADWAY_MINUTES
	var under_service_threshold := (
		target_headway * TARGET_HEADWAY_TOLERANCE
		if target_active
		else LONG_HEADWAY_MINUTES
	)
	var target_ratio := (
		headway / target_headway
		if target_active and target_headway > EPSILON and is_finite(headway)
		else 0.0
	)

	var status := "healthy"
	var severity := 0
	var reason := "service_balanced"
	var recommended_action := "monitor"

	if fleet <= 0:
		status = "no_service"
		severity = 4
		reason = "no_vehicles"
		recommended_action = "add_vehicle"
	elif capacity_ppm <= EPSILON and demand_ppm > EPSILON:
		status = "overloaded"
		severity = 4
		reason = "no_effective_capacity"
		recommended_action = "add_vehicle"
	elif effective_load >= OVERLOAD_RATIO:
		status = "overloaded"
		severity = 4 if effective_load >= 1.25 else 3
		reason = "demand_exceeds_capacity"
		recommended_action = "increase_capacity"
	elif delay_factor >= SEVERE_CONGESTION_FACTOR:
		status = "congestion_limited"
		severity = 3
		reason = "severe_road_congestion"
		recommended_action = "use_priority_or_separate_right_of_way"
	elif effective_load >= LOAD_WARNING_RATIO:
		status = "capacity_warning"
		severity = 2
		reason = "near_capacity"
		recommended_action = "add_vehicle"
	elif delay_factor >= CONGESTION_WARNING_FACTOR:
		status = "congestion_limited"
		severity = 2
		reason = "road_congestion"
		recommended_action = "improve_corridor"
	elif is_finite(headway) and headway >= under_service_threshold and demand_ppm > EPSILON:
		status = "under_served"
		severity = 1
		reason = "headway_above_target" if target_active else "long_headway"
		recommended_action = "add_vehicle"

	return {
		"status": status,
		"severity": severity,
		"reason": reason,
		"recommended_action": recommended_action,
		"fleet_count": fleet,
		"demand_ppm": demand_ppm,
		"capacity_ppm": capacity_ppm,
		"utilization": utilization,
		"effective_load_ratio": effective_load,
		"traffic_delay_factor": delay_factor,
		"headway_minutes": headway,
		"crowding_ratio": crowding_ratio,
		"target_headway_active": target_active,
		"target_headway_minutes": target_headway,
		"target_headway_tolerance": TARGET_HEADWAY_TOLERANCE,
		"headway_target_ratio": target_ratio,
	}
