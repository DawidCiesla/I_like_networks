extends RefCounted
class_name RegionalEconomy

const Data = preload("res://scripts/core/game_data.gd")
const TransitModes = preload("res://scripts/transport/transit_modes.gd")

const WORLD_UNITS_PER_KM := 1000.0
const FORECAST_MINUTES := 60.0
const WATCH_RUNWAY_MINUTES := 240.0
const STRESSED_RUNWAY_MINUTES := 90.0
const EPSILON := 0.000001

# Only infrastructure paid for by the player is maintained by the player's
# transport authority. Historic roads that exist at regional sandbox start are
# intentionally excluded so a fresh map does not begin with a hidden deficit.
const ROAD_MAINTENANCE_PER_KM_MINUTE := {
	"service": 0.018,
	"local": 0.025,
	"collector": 0.045,
	"arterial": 0.075,
	"expressway": 0.110,
	"motorway": 0.150,
}


static func evaluate(store: Node) -> Dictionary:
	var revenue_per_minute := _fare_revenue_per_minute(store.transit_network)
	var transit_opex := _transit_opex_per_minute(store.transit_network)
	var service_opex := _service_opex_per_minute(store.city)
	var road_opex := road_maintenance_per_minute(store.city)
	var total_opex := transit_opex + service_opex + road_opex
	var net_per_minute := revenue_per_minute - total_opex
	var treasury := float(store.money)
	var runway_minutes := INF
	if net_per_minute < -EPSILON:
		runway_minutes = maxf(0.0, treasury) / -net_per_minute
	var status := _financial_status(treasury, net_per_minute, runway_minutes)
	return {
		"fare_revenue_per_minute": revenue_per_minute,
		"transit_opex_per_minute": transit_opex,
		"service_opex_per_minute": service_opex,
		"road_maintenance_per_minute": road_opex,
		"total_opex_per_minute": total_opex,
		"net_per_minute": net_per_minute,
		"forecast_minutes": FORECAST_MINUTES,
		"forecast_revenue": revenue_per_minute * FORECAST_MINUTES,
		"forecast_costs": total_opex * FORECAST_MINUTES,
		"forecast_net": net_per_minute * FORECAST_MINUTES,
		"runway_minutes": runway_minutes,
		"treasury": treasury,
		"status": status,
		"severity": _status_severity(status),
	}


## Accrues only the cost that GameStore did not already own before Economy V1:
## maintenance of player-funded roads. Existing transit and service OPEX remain
## charged by GameStore._accrue_sandbox_operating_costs().
static func advance(store: Node, delta_game_minutes: float) -> bool:
	if delta_game_minutes <= 0.0:
		return false
	var road_rate := road_maintenance_per_minute(store.city)
	var road_cost := road_rate * delta_game_minutes
	if road_cost > EPSILON:
		store.money = float(store.money) - road_cost
		store.stats["lifetime_road_maintenance_costs"] = (
			float(store.stats.get("lifetime_road_maintenance_costs", 0.0)) + road_cost
		)
		store.stats["lifetime_operating_costs"] = (
			float(store.stats.get("lifetime_operating_costs", 0.0)) + road_cost
		)
		store.stats["last_road_maintenance_cost"] = road_cost
		store.stats["operator_net_operating"] = (
			float(store.stats.get("lifetime_revenue", 0.0))
			- float(store.stats.get("lifetime_operating_costs", 0.0))
		)
	var snapshot := evaluate(store)
	var previous: Dictionary = store.city.get("economy", {})
	var changed := not _snapshot_equivalent(previous, snapshot)
	store.city["economy"] = snapshot
	return changed or road_cost > EPSILON


static func road_maintenance_per_minute(city: Dictionary) -> float:
	var result := 0.0
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("source", "")) != "player":
			continue
		if str(road.get("status", "")) != "built":
			continue
		var length_km := _road_length_world(road) / WORLD_UNITS_PER_KM
		if length_km <= EPSILON:
			continue
		var road_class := str(road.get("class", "collector"))
		var rate := float(ROAD_MAINTENANCE_PER_KM_MINUTE.get(
			road_class,
			ROAD_MAINTENANCE_PER_KM_MINUTE["collector"]
		))
		result += length_km * rate
	return result


static func _fare_revenue_per_minute(network: Dictionary) -> float:
	var result := 0.0
	var lines_value: Variant = network.get("lines", {})
	if typeof(lines_value) != TYPE_DICTIONARY:
		return result
	var lines: Dictionary = lines_value
	for line_value in lines.values():
		if typeof(line_value) != TYPE_DICTIONARY:
			continue
		var line: Dictionary = line_value
		if str(line.get("source", "")) != "custom" or str(line.get("status", "")) != "active":
			continue
		result += maxf(0.0, float(line.get("last_delivered_ppm", 0.0))) * float(Data.ECONOMY["fare_per_passenger"])
	return result


static func _transit_opex_per_minute(network: Dictionary) -> float:
	var operating_units := 0.0
	var lines_value: Variant = network.get("lines", {})
	if typeof(lines_value) != TYPE_DICTIONARY:
		return 0.0
	var lines: Dictionary = lines_value
	for line_value in lines.values():
		if typeof(line_value) != TYPE_DICTIONARY:
			continue
		var line: Dictionary = line_value
		if str(line.get("source", "")) != "custom" or str(line.get("status", "")) != "active":
			continue
		var profile := TransitModes.profile(str(line.get("mode", "bus")))
		operating_units += (
			maxf(0.0, float(line.get("fleet_count", 0)))
			* maxf(0.0, float(profile.get("operating_cost_multiplier", 1.0)))
		)
	return operating_units * float(Data.ECONOMY["sandbox_operating_cost_per_bus_minute"])


static func _service_opex_per_minute(city: Dictionary) -> float:
	var result := 0.0
	for facility_value in city.get("service_buildings", []):
		if typeof(facility_value) != TYPE_DICTIONARY:
			continue
		var facility: Dictionary = facility_value
		if str(facility.get("source", "")) != "player" or str(facility.get("status", "")) != "operational":
			continue
		result += maxf(0.0, float(facility.get("operatingCostPerMinute", 0.0)))
	return result


static func _road_length_world(road: Dictionary) -> float:
	var points: Array[Vector2] = []
	for point_value in road.get("points", []):
		if point_value is Vector2:
			points.append(point_value)
		elif typeof(point_value) == TYPE_DICTIONARY:
			var point: Dictionary = point_value
			points.append(Vector2(float(point.get("x", 0.0)), float(point.get("y", 0.0))))
	var result := 0.0
	for index in range(1, points.size()):
		result += points[index - 1].distance_to(points[index])
	return result


static func _financial_status(treasury: float, net_per_minute: float, runway_minutes: float) -> String:
	if treasury <= 0.0:
		return "critical"
	if net_per_minute >= -EPSILON:
		return "surplus"
	if runway_minutes <= STRESSED_RUNWAY_MINUTES:
		return "critical"
	if runway_minutes <= WATCH_RUNWAY_MINUTES:
		return "stressed"
	return "watch"


static func _status_severity(status: String) -> int:
	match status:
		"critical":
			return 4
		"stressed":
			return 3
		"watch":
			return 2
		_:
			return 0


static func _snapshot_equivalent(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() != b.is_empty():
		return false
	for key in [
		"fare_revenue_per_minute",
		"transit_opex_per_minute",
		"service_opex_per_minute",
		"road_maintenance_per_minute",
		"net_per_minute",
		"treasury",
	]:
		if not is_equal_approx(float(a.get(key, 0.0)), float(b.get(key, 0.0))):
			return false
	return str(a.get("status", "")) == str(b.get("status", ""))
