extends RefCounted
class_name RegionalTutorialProgress

const PASSENGER_TARGET := 25.0


static func has_player_road(city: Dictionary) -> bool:
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("source", "")) == "player" and str(road.get("status", "")) == "built":
			return true
	return false


static func has_operating_line(network: Dictionary) -> bool:
	var lines_value: Variant = network.get("lines", {})
	if typeof(lines_value) != TYPE_DICTIONARY:
		return false
	for line_value in (lines_value as Dictionary).values():
		if typeof(line_value) != TYPE_DICTIONARY:
			continue
		var line: Dictionary = line_value
		if str(line.get("source", "")) != "custom":
			continue
		if str(line.get("status", "")) != "active":
			continue
		if int(line.get("fleet_count", 0)) <= 0:
			continue
		var stop_ids_value: Variant = line.get("stop_ids", [])
		if typeof(stop_ids_value) == TYPE_ARRAY and (stop_ids_value as Array).size() >= 2:
			return true
	return false


static func passenger_target_met(stats: Dictionary) -> bool:
	return maxf(0.0, float(stats.get("lifetime_passengers", 0.0))) >= PASSENGER_TARGET


static func passenger_progress(stats: Dictionary) -> Dictionary:
	var current := maxf(0.0, float(stats.get("lifetime_passengers", 0.0)))
	return {
		"current": current,
		"target": PASSENGER_TARGET,
		"progress": clampf(current / PASSENGER_TARGET, 0.0, 1.0),
		"complete": current >= PASSENGER_TARGET,
	}
