extends RefCounted
class_name RegionalProgressionRuntime

const SandboxProgression = preload("res://scripts/city/sandbox_progression.gd")


static func apply(store: Node) -> Dictionary:
	var metrics := collect_metrics(store)
	var progression := SandboxProgression.evaluate(metrics)
	var snapshot := {
		"updated_at": float(store.city.get("time_seconds", 0.0)),
		"metrics": metrics,
		"goals": progression.get("goals", []).duplicate(true),
		"mode_unlocks": progression.get("mode_unlocks", {}).duplicate(true),
		"next_objective": progression.get("next_objective", {}).duplicate(true),
	}
	store.city["progression_v2"] = snapshot
	return snapshot


static func collect_metrics(store: Node) -> Dictionary:
	var transport: Dictionary = {}
	if store.has_method("resident_transport_metrics"):
		var transport_value: Variant = store.call("resident_transport_metrics")
		if typeof(transport_value) == TYPE_DICTIONARY:
			transport = transport_value
	var health: Dictionary = {}
	if store.has_method("resident_health_metrics"):
		var health_value: Variant = store.call("resident_health_metrics")
		if typeof(health_value) == TYPE_DICTIONARY:
			health = health_value
	var economy_value: Variant = store.city.get("economy", {})
	var economy: Dictionary = economy_value if typeof(economy_value) == TYPE_DICTIONARY else {}
	var accessibility := _population_weighted_accessibility(store.city)
	var startup_capital: Dictionary = {}
	if store.has_method("transit_mode_status"):
		for mode in ["tram", "metro"]:
			var status_value: Variant = store.call("transit_mode_status", mode)
			if typeof(status_value) == TYPE_DICTIONARY:
				var status: Dictionary = status_value
				startup_capital[mode] = float(status.get(
					"minimum_startup_capital",
					status.get("unlock_cost", 0.0)
				))
	var unlocked_modes: Variant = store.transit_network.get("unlocked_modes", {"bus": true})
	return {
		"resident_count": int(transport.get("resident_count", _resident_count(store.city))),
		"public_treasury": float(store.money),
		"unlocked_modes": unlocked_modes,
		"minimum_startup_capital_by_mode": startup_capital,
		"reachable_transit_od_pairs": float(transport.get("reachable_transit_od_pairs", 0.0)),
		"total_od_pairs": float(transport.get("total_od_pairs", 0.0)),
		"transit_share": float(transport.get("transit_share", 0.0)),
		"healthcare_coverage": float(health.get("healthcare_coverage", 0.0)),
		"healthcare_data_available": bool(health.get("healthcare_data_available", not health.is_empty())),
		"lifetime_revenue": float(store.stats.get("lifetime_revenue", 0.0)),
		"lifetime_operating_costs": float(store.stats.get("lifetime_operating_costs", 0.0)),
		"lifetime_passengers": float(store.stats.get("lifetime_passengers", 0.0)),
		"current_cashflow_available": not economy.is_empty(),
		"current_net_per_minute": float(economy.get("net_per_minute", 0.0)),
		"current_revenue_per_minute": float(economy.get("fare_revenue_per_minute", 0.0)),
		"current_opex_per_minute": float(economy.get("total_opex_per_minute", 0.0)),
		"average_mobility_accessibility": float(accessibility.get("score", 0.0)),
		"mobility_accessibility_available": bool(accessibility.get("available", false)),
	}


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
		var settlement_id := str(settlement.get("id", ""))
		var row_value: Variant = rows.get(settlement_id, {})
		if typeof(row_value) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_value
		if not bool(row.get("available", false)):
			continue
		var weight := maxf(1.0, float(settlement.get("population", 0.0)))
		weighted += clampf(float(row.get("score", 0.0)), 0.0, 1.0) * weight
		weight_sum += weight
	return {
		"available": weight_sum > 0.0,
		"score": weighted / weight_sum if weight_sum > 0.0 else 0.0,
	}


static func _resident_count(city: Dictionary) -> int:
	var total := 0
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) == TYPE_DICTIONARY:
			total += maxi(0, int((settlement_value as Dictionary).get("population", 0)))
	return total
