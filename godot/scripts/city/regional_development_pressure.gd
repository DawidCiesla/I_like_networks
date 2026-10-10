extends RefCounted
class_name RegionalDevelopmentPressure

const TransitNetwork = preload("res://scripts/transport/transit_network.gd")
const RegionalAccessibility = preload("res://scripts/city/regional_accessibility.gd")

const REAL_ACCESSIBILITY_BLEND := 0.55
const TRANSIT_RADIUS_METERS := 620.0
const NORMALIZATION_SCALE := 4.5
const CONGESTION_FREE_VC := 0.75
const CONGESTION_SEVERE_VC := 1.25
const CONGESTION_SEVERE_DELAY_MINUTES := 8.0


## Computes development pressure outside the growth tick. Organic growth and the
## diagnostics overlay consume the same canonical parcel values, so UI never
## runs its own gameplay model.
static func apply(store: Node) -> Dictionary:
	var city_value: Variant = store.get("city")
	if typeof(city_value) != TYPE_DICTIONARY:
		return {}
	var city: Dictionary = city_value
	var roads_by_id := _road_lookup(city.get("roads", []))
	var settlements_by_id := _settlement_lookup(city.get("regional_settlements", []))
	var summaries: Dictionary = {}
	for settlement_id_value in settlements_by_id.keys():
		var settlement_id := str(settlement_id_value)
		summaries[settlement_id] = {
			"available": false,
			"candidate_count": 0,
			"average_score": 0.0,
			"max_score": 0.0,
			"congested_candidate_count": 0,
			"source": "legacy_proxy",
		}

	for parcel_value in city.get("parcels", []):
		if typeof(parcel_value) != TYPE_DICTIONARY:
			continue
		var parcel: Dictionary = parcel_value
		_clear_runtime_fields(parcel)
		if str(parcel.get("status", "")) != "vacant":
			continue
		var settlement_id := str(parcel.get("districtId", ""))
		var settlement_value: Variant = settlements_by_id.get(settlement_id, {})
		if typeof(settlement_value) != TYPE_DICTIONARY or (settlement_value as Dictionary).is_empty():
			continue
		var settlement: Dictionary = settlement_value
		var frontage_value: Variant = roads_by_id.get(str(parcel.get("frontageRoadId", "")), {})
		if typeof(frontage_value) != TYPE_DICTIONARY or (frontage_value as Dictionary).is_empty():
			continue
		var frontage: Dictionary = frontage_value
		if str(frontage.get("status", "")) != "built":
			continue
		var row := _score_parcel(store, settlement, parcel, frontage)
		for key_value in row.keys():
			parcel[str(key_value)] = row[key_value]
		var summary: Dictionary = summaries.get(settlement_id, {}).duplicate(true)
		var count := int(summary.get("candidate_count", 0)) + 1
		var score := float(row.get("developmentPressure", 0.0))
		var previous_total := float(summary.get("average_score", 0.0)) * float(count - 1)
		summary["available"] = true
		summary["candidate_count"] = count
		summary["average_score"] = (previous_total + score) / float(count)
		summary["max_score"] = maxf(float(summary.get("max_score", 0.0)), score)
		if float(row.get("developmentCongestionPenalty", 0.0)) >= 0.5:
			summary["congested_candidate_count"] = int(summary.get("congested_candidate_count", 0)) + 1
		if str(row.get("developmentPressureSource", "legacy_proxy")) == "blended_real_accessibility":
			summary["source"] = "blended_real_accessibility"
		summaries[settlement_id] = summary

	for settlement_id_value in summaries.keys():
		var settlement_id := str(settlement_id_value)
		var settlement: Dictionary = settlements_by_id.get(settlement_id, {})
		if settlement.is_empty():
			continue
		var summary: Dictionary = summaries[settlement_id]
		settlement["developmentPressureAvailable"] = bool(summary.get("available", false))
		settlement["developmentPressure"] = float(summary.get("average_score", 0.0))
		settlement["developmentPressurePeak"] = float(summary.get("max_score", 0.0))
		settlement["developmentPressureSource"] = str(summary.get("source", "legacy_proxy"))

	var snapshot := {
		"updated_at": float(city.get("time_seconds", 0.0)),
		"settlements": summaries,
	}
	city["regional_development_pressure"] = snapshot
	return snapshot


static func _score_parcel(
	store: Node,
	settlement: Dictionary,
	parcel: Dictionary,
	frontage: Dictionary
) -> Dictionary:
	var position := Vector2(float(parcel.get("x", 0.0)), float(parcel.get("y", 0.0)))
	var center: Vector2 = settlement.get("position", Vector2.ZERO)
	var radius := maxf(1.0, float(settlement.get("built_up_radius_m", 500.0)))
	var transit := 0.0
	var network_value: Variant = store.get("transit_network")
	if typeof(network_value) == TYPE_DICTIONARY:
		var network: Dictionary = network_value
		if not network.is_empty():
			transit = TransitNetwork.stop_accessibility_score(network, position, TRANSIT_RADIUS_METERS)
	var centrality := 1.0 - clampf(position.distance_to(center) / maxf(radius * 1.35, 1.0), 0.0, 1.0)
	var road_access := _road_access_score(frontage)
	var congestion := _road_congestion_penalty(frontage)
	var order_penalty := float(parcel.get("developmentOrder", 0.0)) * 0.0005

	# Keep the old ranking exactly when there is no real accessibility snapshot.
	var legacy_raw := transit * 4.0 + centrality * 0.35 - order_penalty
	var accessibility := RegionalAccessibility.snapshot_row(store.city, str(settlement.get("id", "")))
	var accessibility_available := bool(accessibility.get("available", false))
	var accessibility_score := clampf(float(accessibility.get("score", 0.0)), 0.0, 1.0)
	var source := "legacy_proxy"
	var raw_score := legacy_raw
	if accessibility_available:
		var real_raw := (
			accessibility_score * 1.60
			+ transit * 2.20
			+ centrality * 0.55
			+ road_access * 0.55
			- congestion * 1.15
			- order_penalty
		)
		raw_score = lerpf(legacy_raw, real_raw, REAL_ACCESSIBILITY_BLEND)
		source = "blended_real_accessibility"

	var traffic_value: Variant = frontage.get("traffic", {})
	var traffic: Dictionary = traffic_value if typeof(traffic_value) == TYPE_DICTIONARY else {}
	return {
		"developmentPressureAvailable": true,
		"developmentPressure": clampf(raw_score / NORMALIZATION_SCALE, 0.0, 1.0),
		"developmentPressureRaw": raw_score,
		"developmentPressureSource": source,
		"developmentAccessibility": accessibility_score,
		"developmentTransitProximity": transit,
		"developmentCentrality": centrality,
		"developmentRoadAccess": road_access,
		"developmentCongestionPenalty": congestion,
		"developmentFrontageVcRatio": maxf(0.0, float(traffic.get("vc_ratio", 0.0))),
		"developmentFrontageDelayMinutes": maxf(0.0, float(traffic.get("delay_minutes", 0.0))),
	}


static func _road_access_score(road: Dictionary) -> float:
	match str(road.get("class", "local")):
		"arterial":
			return 1.0
		"collector":
			return 0.90
		"local":
			return 0.72
		"service":
			return 0.52
	return 0.65


static func _road_congestion_penalty(road: Dictionary) -> float:
	var traffic_value: Variant = road.get("traffic", {})
	if typeof(traffic_value) != TYPE_DICTIONARY or (traffic_value as Dictionary).is_empty():
		return 0.0
	var traffic: Dictionary = traffic_value
	var vc := maxf(0.0, float(traffic.get("vc_ratio", 0.0)))
	var delay := maxf(0.0, float(traffic.get("delay_minutes", 0.0)))
	var vc_penalty := clampf(
		(vc - CONGESTION_FREE_VC) / maxf(0.01, CONGESTION_SEVERE_VC - CONGESTION_FREE_VC),
		0.0,
		1.0
	)
	var delay_penalty := clampf(delay / CONGESTION_SEVERE_DELAY_MINUTES, 0.0, 1.0)
	return maxf(vc_penalty, delay_penalty * 0.85)


static func _clear_runtime_fields(parcel: Dictionary) -> void:
	for key in [
		"developmentPressureAvailable",
		"developmentPressure",
		"developmentPressureRaw",
		"developmentPressureSource",
		"developmentAccessibility",
		"developmentTransitProximity",
		"developmentCentrality",
		"developmentRoadAccess",
		"developmentCongestionPenalty",
		"developmentFrontageVcRatio",
		"developmentFrontageDelayMinutes",
	]:
		parcel.erase(key)


static func _road_lookup(roads: Array) -> Dictionary:
	var result: Dictionary = {}
	for road_value in roads:
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		var road_id := str(road.get("id", ""))
		if not road_id.is_empty():
			result[road_id] = road
	return result


static func _settlement_lookup(settlements: Array) -> Dictionary:
	var result: Dictionary = {}
	for settlement_value in settlements:
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var settlement_id := str(settlement.get("id", ""))
		if not settlement_id.is_empty():
			result[settlement_id] = settlement
	return result
