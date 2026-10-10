extends RefCounted
class_name RegionalAccessibility

const EPSILON := 0.000001
const COMMUTE_BEST_MINUTES := 15.0
const COMMUTE_POOR_MINUTES := 55.0
const TARGET_TRANSIT_SHARE := 0.35
const CONGESTION_FREE_VC := 0.70
const CONGESTION_SEVERE_VC := 1.35


## Converts already-simulated resident travel outcomes and road traffic into a
## normalized 0..1 accessibility score. This deliberately does not inspect
## population growth or parcels, so growth may consume this metric without a
## circular dependency on its own output.
static func evaluate(city: Dictionary, transport_metrics: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var districts_value: Variant = transport_metrics.get("districts", {})
	var districts: Dictionary = districts_value if typeof(districts_value) == TYPE_DICTIONARY else {}
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var settlement_id := str(settlement.get("id", ""))
		if settlement_id.is_empty():
			continue
		var district_value: Variant = districts.get(settlement_id, {})
		if typeof(district_value) != TYPE_DICTIONARY or (district_value as Dictionary).is_empty():
			result[settlement_id] = {
				"available": false,
				"score": 0.0,
				"reason": "transport_metrics_unavailable",
			}
			continue
		var district: Dictionary = district_value
		result[settlement_id] = _score_settlement(city, settlement, district)
	return result


## Stores one canonical snapshot for systems such as organic growth and UI.
## The transport metrics are sampled outside the growth tick, so consumers read
## a stable previous-period result instead of recursively recomputing OD choice.
static func apply(store: Node) -> Dictionary:
	if not store.has_method("resident_transport_metrics"):
		return {}
	var metrics_value: Variant = store.call("resident_transport_metrics")
	if typeof(metrics_value) != TYPE_DICTIONARY:
		return {}
	var scores := evaluate(store.city, metrics_value)
	var snapshot := {
		"updated_at": float(store.city.get("time_seconds", 0.0)),
		"settlements": scores,
	}
	store.city["regional_accessibility"] = snapshot
	var settlements: Array = store.city.get("regional_settlements", [])
	for index in range(settlements.size()):
		if typeof(settlements[index]) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlements[index]
		var settlement_id := str(settlement.get("id", ""))
		var row_value: Variant = scores.get(settlement_id, {})
		if typeof(row_value) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_value
		settlement["mobilityAccessibilityAvailable"] = bool(row.get("available", false))
		settlement["mobilityAccessibility"] = float(row.get("score", 0.0))
		settlement["mobilityAverageCommuteMinutes"] = float(row.get("average_commute_minutes", 0.0))
		settlement["mobilityUnservedShare"] = float(row.get("unserved_share", 0.0))
		settlement["mobilityTransitShare"] = float(row.get("transit_share", 0.0))
		settlement["mobilityLocalMaxVcRatio"] = float(row.get("local_max_vc_ratio", 0.0))
		settlements[index] = settlement
	store.city["regional_settlements"] = settlements
	return snapshot


static func settlement_score(
	city: Dictionary,
	transport_metrics: Dictionary,
	settlement_id: String
) -> Dictionary:
	return evaluate(city, transport_metrics).get(settlement_id, {
		"available": false,
		"score": 0.0,
		"reason": "settlement_not_found",
	})


static func snapshot_row(city: Dictionary, settlement_id: String) -> Dictionary:
	var snapshot_value: Variant = city.get("regional_accessibility", {})
	if typeof(snapshot_value) != TYPE_DICTIONARY:
		return {}
	var rows_value: Variant = (snapshot_value as Dictionary).get("settlements", {})
	if typeof(rows_value) != TYPE_DICTIONARY:
		return {}
	var row_value: Variant = (rows_value as Dictionary).get(settlement_id, {})
	return row_value if typeof(row_value) == TYPE_DICTIONARY else {}


static func _score_settlement(
	city: Dictionary,
	settlement: Dictionary,
	district: Dictionary
) -> Dictionary:
	var commute_minutes := maxf(0.0, float(district.get("average_commute_minutes", COMMUTE_POOR_MINUTES)))
	var unserved_share := clampf(float(district.get("unserved_share", 1.0)), 0.0, 1.0)
	var transit_share := clampf(float(district.get("transit_share", 0.0)), 0.0, 1.0)
	var car_share := clampf(float(district.get("car_share", 0.0)), 0.0, 1.0)
	var commute_score := 1.0 - clampf(
		(commute_minutes - COMMUTE_BEST_MINUTES) / (COMMUTE_POOR_MINUTES - COMMUTE_BEST_MINUTES),
		0.0,
		1.0
	)
	var served_score := 1.0 - unserved_share
	# Transit is intentionally a bounded bonus rather than the whole score:
	# a well-connected settlement can still be accessible by road, while a
	# useful transit network materially improves resilience and development.
	var transit_score := clampf(transit_share / TARGET_TRANSIT_SHARE, 0.0, 1.0)
	var traffic := _local_traffic_metrics(city, settlement)
	var max_vc := float(traffic.get("max_vc_ratio", 0.0))
	var road_reliability := 1.0 - clampf(
		(max_vc - CONGESTION_FREE_VC) / (CONGESTION_SEVERE_VC - CONGESTION_FREE_VC),
		0.0,
		1.0
	)
	var score := clampf(
		commute_score * 0.45
		+ served_score * 0.30
		+ transit_score * 0.15
		+ road_reliability * 0.10,
		0.0,
		1.0
	)
	return {
		"available": true,
		"score": score,
		"reason": "",
		"average_commute_minutes": commute_minutes,
		"unserved_share": unserved_share,
		"transit_share": transit_share,
		"car_share": car_share,
		"commute_score": commute_score,
		"served_score": served_score,
		"transit_score": transit_score,
		"road_reliability_score": road_reliability,
		"local_average_vc_ratio": float(traffic.get("average_vc_ratio", 0.0)),
		"local_max_vc_ratio": max_vc,
		"local_average_delay_minutes": float(traffic.get("average_delay_minutes", 0.0)),
		"local_traffic_road_count": int(traffic.get("road_count", 0)),
	}


static func _local_traffic_metrics(city: Dictionary, settlement: Dictionary) -> Dictionary:
	var vc_sum := 0.0
	var delay_sum := 0.0
	var max_vc := 0.0
	var count := 0
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("status", "")) != "built" or not _road_touches_settlement(road, settlement):
			continue
		var traffic_value: Variant = road.get("traffic", {})
		if typeof(traffic_value) != TYPE_DICTIONARY:
			continue
		var traffic: Dictionary = traffic_value
		var vc := maxf(0.0, float(traffic.get("vc_ratio", 0.0)))
		var delay := maxf(0.0, float(traffic.get("delay_minutes", 0.0)))
		vc_sum += vc
		delay_sum += delay
		max_vc = maxf(max_vc, vc)
		count += 1
	return {
		"road_count": count,
		"average_vc_ratio": vc_sum / float(count) if count > 0 else 0.0,
		"max_vc_ratio": max_vc,
		"average_delay_minutes": delay_sum / float(count) if count > 0 else 0.0,
	}


static func _road_touches_settlement(road: Dictionary, settlement: Dictionary) -> bool:
	var settlement_id := str(settlement.get("id", ""))
	if settlement_id in [
		str(road.get("a", "")),
		str(road.get("b", "")),
		str(road.get("settlementId", "")),
		str(road.get("districtId", "")),
	]:
		return true
	var center: Vector2 = _point(settlement.get("position", Vector2.ZERO))
	var radius := maxf(350.0, float(settlement.get("built_up_radius_m", 500.0)) + 180.0)
	var points := _road_points(road)
	for index in range(points.size() - 1):
		if _distance_to_segment(center, points[index], points[index + 1]) <= radius:
			return true
	return false


static func _road_points(road: Dictionary) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for value in road.get("points", []):
		result.append(_point(value))
	return result


static func _point(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if typeof(value) == TYPE_DICTIONARY:
		var raw: Dictionary = value
		return Vector2(float(raw.get("x", 0.0)), float(raw.get("y", 0.0)))
	return Vector2.ZERO


static func _distance_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var segment := b - a
	var length_squared := segment.length_squared()
	if length_squared <= EPSILON:
		return point.distance_to(a)
	var t := clampf((point - a).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(a + segment * t)
