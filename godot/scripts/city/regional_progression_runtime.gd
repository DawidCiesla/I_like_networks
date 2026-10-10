extends RefCounted
class_name RegionalProgressionRuntime

const SandboxProgression = preload("res://scripts/city/sandbox_progression.gd")

const CONGESTION_SEEN_VC := 0.95
const CONGESTION_RESOLVED_VC := 0.85
const SEVERE_CONGESTION_VC := 1.15
const HIGH_DEMAND_PPM := 6.0
const SERVED_TRANSIT_SHARE := 0.01


static func apply(store: Node) -> Dictionary:
	var metrics := collect_metrics(store)
	var history := _updated_history(store.city, metrics)
	metrics["had_congestion"] = bool(history.get("had_congestion", false))
	metrics["resolved_first_congestion"] = bool(history.get("resolved_first_congestion", false))
	metrics["had_severe_congestion"] = bool(history.get("had_severe_congestion", false))
	var progression := SandboxProgression.evaluate(metrics)
	var snapshot := {
		"updated_at": float(store.city.get("time_seconds", 0.0)),
		"metrics": metrics,
		"history": history,
		"goals": progression.get("goals", []).duplicate(true),
		"mode_unlocks": progression.get("mode_unlocks", {}).duplicate(true),
		"next_objective": progression.get("next_objective", {}).duplicate(true),
	}
	store.city["progression_v2"] = snapshot
	return snapshot


static func collect_metrics(store: Node) -> Dictionary:
	var transport := _call_dictionary(store, "resident_transport_metrics")
	var economy_value: Variant = store.city.get("economy", {})
	var economy: Dictionary = economy_value if typeof(economy_value) == TYPE_DICTIONARY else {}
	var accessibility := _population_weighted_accessibility(store.city)
	var traffic := _traffic_metrics(store.city)
	var network := _network_metrics(store.transit_network)
	var startup_capital: Dictionary = {}
	if store.has_method("transit_mode_status"):
		for mode in ["tram", "metro"]:
			var status_value: Variant = store.call("transit_mode_status", mode)
			if typeof(status_value) == TYPE_DICTIONARY:
				var status: Dictionary = status_value
				startup_capital[mode] = float(status.get("minimum_startup_capital", status.get("unlock_cost", 0.0)))
	var unlocked_modes: Variant = store.transit_network.get("unlocked_modes", {"bus": true})
	return {
		"resident_count": int(transport.get("resident_count", _resident_count(store.city))),
		"public_treasury": float(store.money),
		"unlocked_modes": unlocked_modes,
		"minimum_startup_capital_by_mode": startup_capital,
		"player_built_road_count": _player_built_road_count(store.city),
		"depot_built": _depot_built(store),
		"custom_active_line_count": int(network.get("active_lines", 0)),
		"active_custom_fleet": int(network.get("fleet", 0)),
		"active_tram_line_count": int(network.get("tram_lines", 0)),
		"high_demand_corridor_served": bool(network.get("high_demand_corridor_served", false)),
		"served_settlement_count": _served_settlement_count(store.city),
		"reachable_transit_od_pairs": float(transport.get("reachable_transit_od_pairs", 0.0)),
		"total_od_pairs": float(transport.get("total_od_pairs", 0.0)),
		"transit_share": float(transport.get("transit_share", 0.0)),
		"lifetime_revenue": float(store.stats.get("lifetime_revenue", 0.0)),
		"lifetime_operating_costs": float(store.stats.get("lifetime_operating_costs", 0.0)),
		"lifetime_passengers": float(store.stats.get("lifetime_passengers", 0.0)),
		"current_cashflow_available": not economy.is_empty(),
		"current_net_per_minute": float(economy.get("net_per_minute", 0.0)),
		"current_revenue_per_minute": float(economy.get("fare_revenue_per_minute", 0.0)),
		"current_opex_per_minute": float(economy.get("total_opex_per_minute", 0.0)),
		"average_mobility_accessibility": float(accessibility.get("score", 0.0)),
		"mobility_accessibility_available": bool(accessibility.get("available", false)),
		"max_vc_ratio": float(traffic.get("max_vc_ratio", 0.0)),
		"congested_road_count": int(traffic.get("congested_road_count", 0)),
		"first_bypass_built": _has_completed_bypass(store.city),
	}


static func _updated_history(city: Dictionary, metrics: Dictionary) -> Dictionary:
	var previous_snapshot_value: Variant = city.get("progression_v2", {})
	var previous_snapshot: Dictionary = previous_snapshot_value if typeof(previous_snapshot_value) == TYPE_DICTIONARY else {}
	var previous_value: Variant = previous_snapshot.get("history", {})
	var history: Dictionary = (previous_value as Dictionary).duplicate(true) if typeof(previous_value) == TYPE_DICTIONARY else {}
	var max_vc := float(metrics.get("max_vc_ratio", 0.0))
	if max_vc >= CONGESTION_SEEN_VC:
		history["had_congestion"] = true
	if max_vc >= SEVERE_CONGESTION_VC:
		history["had_severe_congestion"] = true
	if bool(history.get("had_congestion", false)) and max_vc < CONGESTION_RESOLVED_VC:
		history["resolved_first_congestion"] = true
	return history


static func _network_metrics(network: Dictionary) -> Dictionary:
	var result := {"active_lines": 0, "fleet": 0, "tram_lines": 0, "high_demand_corridor_served": false}
	var lines_value: Variant = network.get("lines", {})
	if typeof(lines_value) != TYPE_DICTIONARY:
		return result
	for line_value in (lines_value as Dictionary).values():
		if typeof(line_value) != TYPE_DICTIONARY:
			continue
		var line: Dictionary = line_value
		if str(line.get("source", "")) != "custom" or str(line.get("status", "")) != "active":
			continue
		result["active_lines"] = int(result["active_lines"]) + 1
		result["fleet"] = int(result["fleet"]) + maxi(0, int(line.get("fleet_count", 0)))
		if str(line.get("mode", "bus")) == "tram":
			result["tram_lines"] = int(result["tram_lines"]) + 1
		var health_value: Variant = line.get("operations_health", {})
		var health: Dictionary = health_value if typeof(health_value) == TYPE_DICTIONARY else {}
		var demand_signal := maxf(
			maxf(0.0, float(line.get("last_delivered_ppm", 0.0))),
			maxf(0.0, float(health.get("effective_load_ratio", line.get("crowding_ratio", 0.0)))) * HIGH_DEMAND_PPM
		)
		if demand_signal >= HIGH_DEMAND_PPM:
			result["high_demand_corridor_served"] = true
	return result


static func _traffic_metrics(city: Dictionary) -> Dictionary:
	var state_value: Variant = city.get("road_traffic", {})
	if typeof(state_value) != TYPE_DICTIONARY:
		return {"max_vc_ratio": 0.0, "congested_road_count": 0}
	var state: Dictionary = state_value
	var summary_value: Variant = state.get("summary", {})
	var summary: Dictionary = summary_value if typeof(summary_value) == TYPE_DICTIONARY else {}
	return {
		"max_vc_ratio": maxf(0.0, float(summary.get("max_vc_ratio", 0.0))),
		"congested_road_count": maxi(0, int(summary.get("congested_edge_count", 0))),
	}


static func _served_settlement_count(city: Dictionary) -> int:
	var snapshot_value: Variant = city.get("regional_accessibility", {})
	if typeof(snapshot_value) != TYPE_DICTIONARY:
		return 0
	var rows_value: Variant = (snapshot_value as Dictionary).get("settlements", {})
	if typeof(rows_value) != TYPE_DICTIONARY:
		return 0
	var count := 0
	for row_value in (rows_value as Dictionary).values():
		if typeof(row_value) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_value
		if bool(row.get("available", false)) and float(row.get("transit_share", 0.0)) >= SERVED_TRANSIT_SHARE:
			count += 1
	return count


static func _player_built_road_count(city: Dictionary) -> int:
	var count := 0
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("source", "")) == "player" and str(road.get("status", "")) == "built":
			count += 1
	return count


static func _has_completed_bypass(city: Dictionary) -> bool:
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("source", "")) != "player" or str(road.get("status", "")) != "built":
			continue
		if str(road.get("regionalRole", "")) == "player_relief_corridor" or not str(road.get("proposalId", "")).is_empty():
			return true
	return false


static func _depot_built(store: Node) -> bool:
	if store.has_method("has_depot"):
		return bool(store.call("has_depot"))
	var depot_value: Variant = store.get("depot")
	return typeof(depot_value) == TYPE_DICTIONARY and bool((depot_value as Dictionary).get("built", false))


static func _call_dictionary(store: Node, method_name: String) -> Dictionary:
	if not store.has_method(method_name):
		return {}
	var value: Variant = store.call(method_name)
	return value if typeof(value) == TYPE_DICTIONARY else {}


static func _population_weighted_accessibility(city: Dictionary) -> Dictionary:
	var snapshot_value: Variant = city.get("regional_accessibility", {})
	if typeof(snapshot_value) != TYPE_DICTIONARY:
		return {"available": false, "score": 0.0}
	var rows_value: Variant = (snapshot_value as Dictionary).get("settlements", {})
	if typeof(rows_value) != TYPE_DICTIONARY:
		return {"available": false, "score": 0.0}
	var rows: Dictionary = rows_value
	var weighted := 0.0
	var weight_sum := 0.0
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var row_value: Variant = rows.get(str(settlement.get("id", "")), {})
		if typeof(row_value) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_value
		if not bool(row.get("available", false)):
			continue
		var weight := maxf(1.0, float(settlement.get("population", 0.0)))
		weighted += clampf(float(row.get("score", 0.0)), 0.0, 1.0) * weight
		weight_sum += weight
	return {"available": weight_sum > 0.0, "score": weighted / weight_sum if weight_sum > 0.0 else 0.0}


static func _resident_count(city: Dictionary) -> int:
	var total := 0
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) == TYPE_DICTIONARY:
			total += maxi(0, int((settlement_value as Dictionary).get("population", 0)))
	return total
