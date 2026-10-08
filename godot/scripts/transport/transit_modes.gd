extends RefCounted
class_name TransitModes

const MODE_IDS := ["bus", "tram", "metro"]

# Speeds and capacities are per vehicle. Cost and emission values are relative
# to one bus. Stop spacing is measured in the world's meter-like units.
const MODE_PROFILES := {
	"bus": {
		"speed_kph": 18.0,
		"vehicle_capacity": 40,
		"operating_cost_multiplier": 1.0,
		"construction_cost_multiplier": 1.0,
		"emission_factor": 1.0,
		"headway_minutes": 10.0,
		"stop_spacing": 450.0,
		"minimum_stop_spacing": 70.0,
		"maximum_stop_spacing": 900.0,
		"requires_road_corridor": true,
		"requires_tram_corridor": false,
		"grade_separated": false,
		"requires_accessible_stations": false,
		"right_of_way": "mixed_traffic",
		"unlock_population": 0,
		"unlock_cost": 0.0,
	},
	"tram": {
		"speed_kph": 24.0,
		"vehicle_capacity": 180,
		"operating_cost_multiplier": 2.0,
		"construction_cost_multiplier": 8.0,
		"emission_factor": 0.35,
		"headway_minutes": 8.0,
		"stop_spacing": 550.0,
		"minimum_stop_spacing": 180.0,
		"maximum_stop_spacing": 1200.0,
		"requires_road_corridor": true,
		"requires_tram_corridor": true,
		"grade_separated": false,
		"requires_accessible_stations": false,
		"right_of_way": "reserved_road_corridor",
		"unlock_population": 25000,
		"unlock_cost": 16000.0,
	},
	"metro": {
		"speed_kph": 40.0,
		"vehicle_capacity": 600,
		"operating_cost_multiplier": 5.0,
		"construction_cost_multiplier": 35.0,
		"emission_factor": 0.15,
		"headway_minutes": 4.0,
		"stop_spacing": 1400.0,
		"minimum_stop_spacing": 600.0,
		"maximum_stop_spacing": 2800.0,
		"requires_road_corridor": false,
		"requires_tram_corridor": false,
		"grade_separated": true,
		"requires_accessible_stations": true,
		"right_of_way": "underground_or_grade_separated",
		"unlock_population": 80000,
		"unlock_cost": 150000.0,
	},
}


static func mode_ids() -> Array[String]:
	var result: Array[String] = []
	for mode_value in MODE_IDS:
		result.append(str(mode_value))
	return result


static func profile(mode: String) -> Dictionary:
	if not MODE_PROFILES.has(mode):
		return {}
	return (MODE_PROFILES[mode] as Dictionary).duplicate(true)


static func unlock_status(
	mode: String,
	population: int,
	treasury: float,
	minimum_startup_capital: float = 0.0
) -> Dictionary:
	var mode_profile := profile(mode)
	if mode_profile.is_empty():
		return {"unlocked": false, "reason": "unknown_mode"}

	var population_required := int(mode_profile.get("unlock_population", 0))
	var licence_cost := float(mode_profile.get("unlock_cost", 0.0))
	var cost_required := maxf(licence_cost, maxf(0.0, minimum_startup_capital))
	var population_met := population >= population_required
	var cost_met := treasury >= cost_required
	var reason := ""
	if not population_met:
		reason = "population_requirement_not_met"
	elif not cost_met:
		reason = "unlock_cost_not_met"

	return {
		"unlocked": population_met and cost_met,
		"reason": reason,
		"population_required": population_required,
		"unlock_cost": cost_required,
		"licence_cost": licence_cost,
		"minimum_startup_capital": cost_required,
		"population_remaining": maxi(0, population_required - population),
		"funds_remaining": maxf(0.0, cost_required - treasury),
	}


## Validates a route dictionary. The route may carry current custom-transit
## `route_segments` / `road_ids` data, or explicit facts such as
## `road_corridor`, `grade_separated`, `underground`, `accessible_stations`, and
## `station_spacings`. `stations` may contain records with either
## `position: Vector2`, `position: {x, y}`, or top-level x/y values.
static func validate_route(mode: String, route: Dictionary) -> Dictionary:
	var mode_profile := profile(mode)
	if mode_profile.is_empty():
		return _invalid("unknown_mode")
	if route.is_empty():
		return _invalid("route_missing")
	if _has_malformed_route_segment(route):
		return _invalid("malformed_route_segment")

	if bool(mode_profile.get("requires_road_corridor", false)):
		if not _has_built_road_corridor(route):
			return _invalid("built_road_corridor_required")

	if bool(mode_profile.get("requires_tram_corridor", false)):
		if not _has_tram_corridor(route):
			return _invalid("tram_track_corridor_required")

	# Surface routes receive station positions from the in-game builder too. Keep
	# the spacing check optional for callers that only validate corridor facts,
	# but enforce the profile limits whenever stop geometry is available.
	if not bool(mode_profile.get("grade_separated", false)) and _has_spacing_facts(route):
		var spacing_result := _validate_station_spacing(route, mode_profile)
		if not bool(spacing_result.get("valid", false)):
			return spacing_result

	if bool(mode_profile.get("grade_separated", false)):
		if not _has_grade_separated_route(route):
			return _invalid("grade_separated_or_underground_route_required")
		var station_result := _validate_metro_stations(route, mode_profile)
		if not bool(station_result.get("valid", false)):
			return station_result

	return {"valid": true, "reason": ""}


static func _invalid(reason: String) -> Dictionary:
	return {"valid": false, "reason": reason}


static func _has_built_road_corridor(route: Dictionary) -> bool:
	if _is_true_flag(route.get("road_corridor", false)) or _is_true_flag(route.get("roads_connected", false)):
		return true
	var road_ids := _route_road_ids(route)
	if road_ids.is_empty():
		return false
	var built_ids := _built_road_ids(route)
	if built_ids.is_empty():
		return false
	for road_id in road_ids:
		if not built_ids.has(road_id):
			return false
	return true


static func _has_tram_corridor(route: Dictionary) -> bool:
	if _is_true_flag(route.get("tram_corridor", false)) or _is_true_flag(route.get("tram_reservation", false)):
		return true
	var road_ids := _route_road_ids(route)
	if road_ids.is_empty():
		return false
	var roads := _road_lookup(route)
	if roads.is_empty():
		return false
	for road_id in road_ids:
		if not roads.has(road_id):
			return false
		var road: Dictionary = roads[road_id]
		if not _is_built_road(road) or not _road_has_tram_tracks(road):
			return false
	return true


static func _has_grade_separated_route(route: Dictionary) -> bool:
	if _is_grade_separated(route):
		return true
	var segments := _route_segments(route)
	if segments.is_empty():
		return false
	var roads := _road_lookup(route)
	for segment_value in segments:
		if not (segment_value is Dictionary):
			return false
		var segment: Dictionary = segment_value
		if _is_grade_separated(segment):
			continue
		var road_ids := _road_ids_from_segment(segment)
		if road_ids.is_empty():
			return false
		for road_id in road_ids:
			if not roads.has(road_id) or not _is_grade_separated(roads[road_id]):
				return false
	return true


static func _validate_metro_stations(route: Dictionary, mode_profile: Dictionary) -> Dictionary:
	var stations := _stations(route)
	var explicit_accessibility = route.get("accessible_stations", null)
	var station_count := stations.size()
	if _is_number(route.get("station_count", null)):
		station_count = int(route.get("station_count", 0))
	if station_count < 2:
		return _invalid("at_least_two_stations_required")

	if explicit_accessibility is bool:
		if not explicit_accessibility:
			return _invalid("accessible_stations_required")
	elif explicit_accessibility is Array:
		if explicit_accessibility.size() < 2:
			return _invalid("at_least_two_stations_required")
		for station_value in explicit_accessibility:
			if not _station_is_accessible(station_value):
				return _invalid("accessible_stations_required")
	else:
		if stations.size() < 2:
			return _invalid("station_accessibility_missing")
		for station_value in stations:
			if not _station_is_accessible(station_value):
				return _invalid("accessible_stations_required")

	return _validate_station_spacing(route, mode_profile)


static func _validate_station_spacing(route: Dictionary, mode_profile: Dictionary) -> Dictionary:
	var spacings := _station_spacings(route, _stations(route))
	if spacings.is_empty():
		return _invalid("station_spacing_missing")
	var stations := _stations(route)
	var station_count := stations.size()
	if _is_number(route.get("station_count", null)):
		station_count = int(route["station_count"])
	if station_count >= 2 and spacings.size() != station_count - 1:
		return _invalid("station_spacing_invalid")
	var minimum_spacing := float(mode_profile.get("minimum_stop_spacing", 0.0))
	var maximum_spacing := float(mode_profile.get("maximum_stop_spacing", INF))
	for spacing in spacings:
		if not is_finite(spacing):
			return _invalid("station_spacing_invalid")
		if spacing < minimum_spacing:
			return _invalid("stations_too_close")
		if spacing > maximum_spacing:
			return _invalid("stations_too_far_apart")
	return {"valid": true, "reason": ""}


static func _has_spacing_facts(route: Dictionary) -> bool:
	return (
		route.has("station_spacings")
		or route.has("stop_spacings")
		or route.has("station_spacing")
		or route.has("stations")
		or route.has("stops")
		or route.has("station_count")
	)


static func _station_spacings(route: Dictionary, stations: Array) -> Array[float]:
	var result: Array[float] = []
	var raw_spacings = route.get("station_spacings", route.get("stop_spacings", null))
	if raw_spacings is Array:
		for value in raw_spacings:
			if not _is_number(value):
				return []
			result.append(float(value))
		return result
	if stations.size() >= 2:
		var previous := _station_position(stations[0])
		if not previous["valid"]:
			return []
		for index in range(1, stations.size()):
			var current := _station_position(stations[index])
			if not current["valid"]:
				return []
			var previous_point: Vector2 = previous["position"]
			var current_point: Vector2 = current["position"]
			result.append(previous_point.distance_to(current_point))
			previous = current
		return result
	var single_spacing = route.get("station_spacing", null)
	if _is_number(single_spacing):
		result.append(float(single_spacing))
	return result


static func _stations(route: Dictionary) -> Array:
	var raw = route.get("stations", route.get("stops", []))
	if raw is Array:
		return raw
	if raw is Dictionary:
		var result: Array = []
		var keys: Array = raw.keys()
		keys.sort()
		for key in keys:
			result.append(raw[key])
		return result
	return []


static func _station_is_accessible(value: Variant) -> bool:
	if value is bool:
		return value
	if not (value is Dictionary):
		return false
	var station: Dictionary = value
	if station.get("accessible", null) is bool:
		return bool(station["accessible"])
	if station.get("wheelchair_accessible", null) is bool:
		return bool(station["wheelchair_accessible"])
	var access = station.get("accessibility", null)
	return access is Dictionary and _is_true_flag(access.get("accessible", false))


static func _station_position(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {"valid": false, "position": Vector2.ZERO}
	var station: Dictionary = value
	var position = station.get("position", null)
	if position is Vector2:
		return {"valid": true, "position": position}
	if position is Dictionary:
		var point: Dictionary = position
		if _is_number(point.get("x", null)) and _is_number(point.get("y", null)):
			return {"valid": true, "position": Vector2(float(point["x"]), float(point["y"]))}
	if _is_number(station.get("x", null)) and _is_number(station.get("y", null)):
		return {"valid": true, "position": Vector2(float(station["x"]), float(station["y"]))}
	return {"valid": false, "position": Vector2.ZERO}


static func _route_road_ids(route: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var raw = route.get("road_ids", [])
	if raw is Array:
		for road_id_value in raw:
			var road_id := str(road_id_value).strip_edges()
			if not road_id.is_empty() and not result.has(road_id):
				result.append(road_id)
	for segment_value in _route_segments(route):
		if not (segment_value is Dictionary):
			continue
		for road_id in _road_ids_from_segment(segment_value):
			if not result.has(road_id):
				result.append(road_id)
	return result


static func _road_ids_from_segment(segment: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var raw = segment.get("road_ids", [])
	if raw is Array:
		for road_id_value in raw:
			var road_id := str(road_id_value).strip_edges()
			if not road_id.is_empty() and not result.has(road_id):
				result.append(road_id)
	var singular := str(segment.get("road_id", "")).strip_edges()
	if not singular.is_empty() and not result.has(singular):
		result.append(singular)
	return result


static func _built_road_ids(route: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var explicit = route.get("built_road_ids", [])
	if explicit is Array:
		for road_id_value in explicit:
			result.append(str(road_id_value))
	var roads := _road_lookup(route)
	for road_id_value in roads.keys():
		var road: Dictionary = roads[road_id_value]
		if _is_built_road(road):
			result.append(str(road_id_value))
	return result


static func _road_lookup(route: Dictionary) -> Dictionary:
	var source: Dictionary = route
	var city = route.get("city", null)
	if city is Dictionary:
		source = city
	var raw = source.get("roads", null)
	if raw == null:
		var road_network = route.get("road_network", null)
		if road_network is Dictionary:
			raw = road_network.get("roads", null)
	var result: Dictionary = {}
	if raw is Array:
		for road_value in raw:
			if not (road_value is Dictionary):
				continue
			var road: Dictionary = road_value
			var road_id := str(road.get("id", road.get("road_id", ""))).strip_edges()
			if not road_id.is_empty():
				result[road_id] = road
	elif raw is Dictionary:
		for road_id_value in raw.keys():
			if raw[road_id_value] is Dictionary:
				result[str(road_id_value)] = raw[road_id_value]
	return result


static func _route_segments(route: Dictionary) -> Array:
	var raw = route.get("route_segments", route.get("segments", []))
	return raw if raw is Array else []


static func _has_malformed_route_segment(route: Dictionary) -> bool:
	var raw = route.get("route_segments", route.get("segments", []))
	if not (raw is Array):
		return raw != null
	for segment_value in raw:
		if not (segment_value is Dictionary):
			return true
		var segment: Dictionary = segment_value
		if segment.has("success"):
			if not (segment["success"] is bool) or not bool(segment["success"]):
				return true
		var road_ids = segment.get("road_ids", [])
		if not (road_ids is Array):
			return true
	return false


static func _is_built_road(road: Dictionary) -> bool:
	if road.get("built", null) is bool:
		return bool(road["built"])
	return str(road.get("status", "")) == "built"


static func _road_has_tram_tracks(road: Dictionary) -> bool:
	if _is_true_flag(road.get("tram_corridor", false)) or _is_true_flag(road.get("tram_reservation", false)):
		return true
	var profile_value = road.get("profile", {})
	if not (profile_value is Dictionary):
		return false
	var road_profile: Dictionary = profile_value
	if _is_true_flag(road_profile.get("tram_reservation", false)):
		return true
	var lanes = road_profile.get("lanes", [])
	if not (lanes is Array):
		return false
	for lane_value in lanes:
		if lane_value is Dictionary and str(lane_value.get("type", "")) == "tram":
			return true
	return false


static func _is_grade_separated(value: Dictionary) -> bool:
	if _is_true_flag(value.get("underground", false)) or _is_true_flag(value.get("grade_separated", false)):
		return true
	var right_of_way := str(value.get("right_of_way", ""))
	if right_of_way in ["underground", "elevated", "exclusive", "grade_separated"]:
		return true
	var level = value.get("level", null)
	return _is_number(level) and absf(float(level)) > 0.000001


static func _is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _is_true_flag(value: Variant) -> bool:
	return value is bool and bool(value)
