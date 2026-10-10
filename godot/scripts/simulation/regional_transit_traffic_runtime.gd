extends RefCounted
class_name RegionalTransitTrafficRuntime

const Data = preload("res://scripts/core/game_data.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const TransitModes = preload("res://scripts/transport/transit_modes.gd")
const TransitLineHealth = preload("res://scripts/simulation/transit_line_health.gd")

const WORLD_UNITS_PER_KM := 1000.0
const MAX_CONGESTION_FACTOR := 6.0
const EPSILON := 0.000001


## Applies the current road-traffic state to buses that are already travelling.
## GameStore owns the transit simulation; this adapter only adjusts the duration
## of a bus's active road segment. Progress is preserved when congestion changes,
## so a vehicle never jumps backwards or restarts a segment.
static func apply(store: Node) -> bool:
	if not _is_regional_city(store.city):
		return false
	var road_lookup := _road_lookup(store.city)
	var network: Dictionary = store.transit_network
	var lines: Dictionary = network.get("lines", {})
	var stops: Dictionary = network.get("stops", {})
	var changed := false

	for line_id_value in lines.keys():
		var line_id := str(line_id_value)
		var line: Dictionary = lines[line_id]
		if str(line.get("source", "")) != "custom":
			continue
		if str(line.get("status", "")) != "active":
			continue
		if str(line.get("mode", "bus")) != "bus":
			_clear_line_runtime_fields(line)
			lines[line_id] = line
			continue

		var segments: Array = line.get("route_segments", [])
		var line_summary := _line_congestion_summary(segments, road_lookup)
		var operations := _line_operations_summary(line, stops, line_summary)
		line["traffic_delay_factor"] = float(line_summary.get("factor", 1.0))
		line["traffic_affected_segment_count"] = int(line_summary.get("affected_segments", 0))
		line["traffic_effective_driving_minutes_one_way"] = float(line_summary.get("effective_minutes", 0.0))
		line["traffic_nominal_driving_minutes_one_way"] = float(line_summary.get("nominal_minutes", 0.0))
		line["traffic_effective_cycle_minutes"] = float(operations.get("cycle_minutes", 0.0))
		line["traffic_effective_headway_minutes"] = float(operations.get("headway_minutes", INF))
		line["traffic_effective_capacity_ppm"] = float(operations.get("capacity_ppm", 0.0))
		line["operations_health"] = TransitLineHealth.evaluate(line)

		var vehicles: Array = line.get("vehicles", [])
		for vehicle_index in range(vehicles.size()):
			if typeof(vehicles[vehicle_index]) != TYPE_DICTIONARY:
				continue
			var vehicle: Dictionary = vehicles[vehicle_index]
			if str(vehicle.get("phase", "")) != "travel":
				if vehicle.has("traffic_segment_key") or vehicle.has("traffic_congestion_factor"):
					vehicle.erase("traffic_segment_key")
					vehicle.erase("traffic_congestion_factor")
					vehicles[vehicle_index] = vehicle
					changed = true
				continue

			var current := int(vehicle.get("current_stop_index", 0))
			var next_stop := int(vehicle.get("next_stop_index", current))
			var segment_index := mini(current, next_stop)
			if segment_index < 0 or segment_index >= segments.size():
				continue
			var segment: Dictionary = segments[segment_index]
			var nominal_minutes := _nominal_segment_minutes(line, segment)
			var factor := _segment_congestion_factor(segment, road_lookup)
			var target_duration := maxf(0.05, nominal_minutes * factor)
			var old_duration := maxf(0.000001, float(vehicle.get("phase_duration_minutes", nominal_minutes)))
			var old_remaining := clampf(
				float(vehicle.get("phase_minutes_remaining", old_duration)),
				0.0,
				old_duration
			)
			var progress := clampf(1.0 - old_remaining / old_duration, 0.0, 1.0)
			var segment_key := "%s:%d>%d" % [line_id, current, next_stop]
			var previous_factor := float(vehicle.get("traffic_congestion_factor", 1.0))
			var previous_key := str(vehicle.get("traffic_segment_key", ""))
			if (
				previous_key == segment_key
				and is_equal_approx(previous_factor, factor)
				and is_equal_approx(old_duration, target_duration)
			):
				continue

			vehicle["phase_duration_minutes"] = target_duration
			vehicle["phase_minutes_remaining"] = target_duration * (1.0 - progress)
			vehicle["traffic_segment_key"] = segment_key
			vehicle["traffic_congestion_factor"] = factor
			vehicles[vehicle_index] = vehicle
			changed = true

		line["vehicles"] = vehicles
		lines[line_id] = line

	network["lines"] = lines
	store.transit_network = network
	return changed


static func _line_congestion_summary(segments: Array, road_lookup: Dictionary) -> Dictionary:
	var nominal_minutes := 0.0
	var effective_minutes := 0.0
	var affected_segments := 0
	for segment_value in segments:
		if typeof(segment_value) != TYPE_DICTIONARY:
			continue
		var segment: Dictionary = segment_value
		var length_km := maxf(0.0, float(segment.get("length_world", 0.0))) / WORLD_UNITS_PER_KM
		var segment_nominal := length_km / maxf(1.0, float(TransitModes.profile("bus").get("speed_kph", 18.0))) * 60.0
		var factor := _segment_congestion_factor(segment, road_lookup)
		nominal_minutes += segment_nominal
		effective_minutes += segment_nominal * factor
		if factor > 1.0 + EPSILON:
			affected_segments += 1
	return {
		"factor": effective_minutes / nominal_minutes if nominal_minutes > EPSILON else 1.0,
		"nominal_minutes": nominal_minutes,
		"effective_minutes": effective_minutes,
		"affected_segments": affected_segments,
	}


static func _line_operations_summary(
	line: Dictionary,
	stops: Dictionary,
	line_summary: Dictionary
) -> Dictionary:
	var stop_ids_value: Variant = line.get("stop_ids", [])
	var stop_ids: Array = stop_ids_value if typeof(stop_ids_value) == TYPE_ARRAY else []
	var dwell_minutes := 0.0
	for stop_index in range(stop_ids.size()):
		var stop_id := str(stop_ids[stop_index])
		var stop: Dictionary = stops.get(stop_id, {})
		var level := clampi(
			int(stop.get("level", 0)),
			0,
			int(Data.STATION_UPGRADE["max_level"])
		)
		var reduction := float(Data.STATION_UPGRADE["dwell_reduction"][level])
		var dwell := maxf(0.12, float(Data.BUS["dwell_minutes"]) - reduction)
		var visits := 1 if stop_index == 0 or stop_index == stop_ids.size() - 1 else 2
		dwell_minutes += dwell * float(visits)
	var cycle_minutes := (
		float(line_summary.get("effective_minutes", 0.0)) * 2.0
		+ dwell_minutes
		+ float(Data.BUS["turnaround_minutes"])
	)
	var fleet := maxi(0, int(line.get("fleet_count", 0)))
	var headway := cycle_minutes / float(fleet) if fleet > 0 and cycle_minutes > EPSILON else INF
	var vehicle_capacity := maxf(
		1.0,
		float(TransitModes.profile("bus").get("vehicle_capacity", Data.BUS["capacity"]))
	)
	var capacity_ppm := (
		vehicle_capacity * float(fleet) * 2.0 / cycle_minutes
		if fleet > 0 and cycle_minutes > EPSILON
		else 0.0
	)
	return {
		"cycle_minutes": cycle_minutes,
		"headway_minutes": headway,
		"capacity_ppm": capacity_ppm,
	}


static func _nominal_segment_minutes(line: Dictionary, segment: Dictionary) -> float:
	var mode := str(line.get("mode", "bus"))
	var speed_kph := maxf(1.0, float(TransitModes.profile(mode).get("speed_kph", 18.0)))
	var length_km := maxf(0.0, float(segment.get("length_world", 0.0))) / WORLD_UNITS_PER_KM
	return maxf(0.05, length_km / speed_kph * 60.0)


static func _segment_congestion_factor(segment: Dictionary, road_lookup: Dictionary) -> float:
	var free_flow_minutes := 0.0
	var travel_minutes := 0.0
	var seen: Dictionary = {}
	for road_id_value in segment.get("road_ids", []):
		var road_id := str(road_id_value)
		if road_id.is_empty() or seen.has(road_id) or not road_lookup.has(road_id):
			continue
		seen[road_id] = true
		var road: Dictionary = road_lookup[road_id]
		var traffic_value: Variant = road.get("traffic", {})
		if typeof(traffic_value) != TYPE_DICTIONARY:
			continue
		var traffic: Dictionary = traffic_value
		var free := maxf(0.0, float(traffic.get("free_flow_minutes", 0.0)))
		var travel := maxf(free, float(traffic.get("travel_time_minutes", free)))
		if free <= EPSILON:
			continue
		free_flow_minutes += free
		travel_minutes += travel
	if free_flow_minutes <= EPSILON:
		return 1.0
	return clampf(travel_minutes / free_flow_minutes, 1.0, MAX_CONGESTION_FACTOR)


static func _clear_line_runtime_fields(line: Dictionary) -> void:
	for key in [
		"traffic_delay_factor",
		"traffic_affected_segment_count",
		"traffic_effective_driving_minutes_one_way",
		"traffic_nominal_driving_minutes_one_way",
		"traffic_effective_cycle_minutes",
		"traffic_effective_headway_minutes",
		"traffic_effective_capacity_ppm",
		"operations_health",
	]:
		line.erase(key)
	var vehicles: Array = line.get("vehicles", [])
	for vehicle_index in range(vehicles.size()):
		if typeof(vehicles[vehicle_index]) != TYPE_DICTIONARY:
			continue
		var vehicle: Dictionary = vehicles[vehicle_index]
		vehicle.erase("traffic_segment_key")
		vehicle.erase("traffic_congestion_factor")
		vehicles[vehicle_index] = vehicle
	line["vehicles"] = vehicles


static func _road_lookup(city: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		var road_id := str(road.get("id", ""))
		if not road_id.is_empty():
			result[road_id] = road
	return result


static func _is_regional_city(city: Dictionary) -> bool:
	return str(city.get("world_map_id", MapDefinition.LEGACY_CITY_MAP_ID)) != MapDefinition.LEGACY_CITY_MAP_ID
