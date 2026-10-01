extends RefCounted
class_name TransitNetwork

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const RoadRouter = preload("res://scripts/transport/road_router.gd")

const SCHEMA_VERSION := 1
const SOURCE_LEGACY_BRIDGE := "legacy_bridge"
const SOURCE_FREE_LINES := "free_lines"

static func create_legacy_bridge(
	city: Dictionary,
	line_states: Dictionary,
	station_states: Dictionary
) -> Dictionary:
	var stops: Dictionary = {}
	var line_models: Dictionary = {}

	for line_key in Data.LINE_KEYS:
		var station_ids: Array = Data.STATION_IDS[line_key]
		for stop_index in range(station_ids.size()):
			var station_id := str(station_ids[stop_index])
			if stops.has(station_id):
				continue

			var position := Layout.stop_position(line_key, stop_index)
			var snap := RoadRouter.snap_to_road(city, position, false)
			var station_state: Dictionary = station_states.get(station_id, {"level": 0})
			stops[station_id] = _legacy_stop(
				station_id,
				Data.station_name(station_id),
				position,
				snap,
				int(station_state.get("level", 0))
			)

	for line_key in Data.LINE_KEYS:
		var line_state: Dictionary = line_states.get(line_key, {})
		line_models[line_key] = _legacy_line(
			city,
			line_key,
			line_state,
			stops
		)

	var network := {
		"schema_version": SCHEMA_VERSION,
		"source": SOURCE_LEGACY_BRIDGE,
		"next_stop_serial": 1,
		"next_line_serial": 1,
		"stops": stops,
		"lines": line_models,
	}
	_refresh_stop_activity(network)
	return network

static func ensure_legacy_bridge(
	network: Dictionary,
	city: Dictionary,
	line_states: Dictionary,
	station_states: Dictionary
) -> Dictionary:
	if network.is_empty():
		return create_legacy_bridge(city, line_states, station_states)
	if int(network.get("schema_version", 0)) != SCHEMA_VERSION:
		return create_legacy_bridge(city, line_states, station_states)
	if str(network.get("source", SOURCE_LEGACY_BRIDGE)) != SOURCE_LEGACY_BRIDGE:
		return network
	return create_legacy_bridge(city, line_states, station_states)

static func stop_position(network: Dictionary, stop_id: String) -> Vector2:
	var stops: Dictionary = network.get("stops", {})
	var stop: Dictionary = stops.get(stop_id, {})
	return Vector2(
		float(stop.get("x", 0.0)),
		float(stop.get("y", 0.0))
	)

static func line_stop_ids(network: Dictionary, line_id: String) -> Array[String]:
	var result: Array[String] = []
	var lines: Dictionary = network.get("lines", {})
	var line: Dictionary = lines.get(line_id, {})
	for stop_id_value in line.get("stop_ids", []):
		result.append(str(stop_id_value))
	return result

static func line_route_points(network: Dictionary, line_id: String) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var lines: Dictionary = network.get("lines", {})
	var line: Dictionary = lines.get(line_id, {})
	for raw_value in line.get("route_points", []):
		if typeof(raw_value) != TYPE_DICTIONARY:
			continue
		var raw: Dictionary = raw_value
		result.append(Vector2(
			float(raw.get("x", 0.0)),
			float(raw.get("y", 0.0))
		))
	return result

static func _legacy_stop(
	stop_id: String,
	stop_name: String,
	position: Vector2,
	snap: Dictionary,
	level: int
) -> Dictionary:
	return {
		"id": stop_id,
		"name": stop_name,
		"x": position.x,
		"y": position.y,
		"road_id": str(snap.get("road_id", "")),
		"edge_id": str(snap.get("edge_id", "")),
		"edge_t": float(snap.get("t", 0.0)),
		"road_class": str(snap.get("road_class", "")),
		"snap_distance": float(snap.get("distance", -1.0)),
		"level": level,
		"status": "planned",
		"served_line_ids": [],
		"source": "legacy",
	}

static func _legacy_line(
	city: Dictionary,
	line_key: String,
	line_state: Dictionary,
	stops: Dictionary
) -> Dictionary:
	var planned_stop_ids: Array[String] = []
	for stop_id_value in Data.STATION_IDS[line_key]:
		planned_stop_ids.append(str(stop_id_value))

	var active_count := clampi(
		int(line_state.get("stop_count", 0)),
		0,
		planned_stop_ids.size()
	)
	var active_stop_ids: Array[String] = []
	for index in range(active_count):
		active_stop_ids.append(planned_stop_ids[index])

	var segments: Array = []
	var combined_points: Array[Vector2] = []
	var route_length_world := 0.0

	for index in range(active_stop_ids.size() - 1):
		var from_id := active_stop_ids[index]
		var to_id := active_stop_ids[index + 1]
		var from_stop: Dictionary = stops.get(from_id, {})
		var to_stop: Dictionary = stops.get(to_id, {})
		if from_stop.is_empty() or to_stop.is_empty():
			continue

		var route := RoadRouter.route_between_points(
			city,
			Vector2(float(from_stop["x"]), float(from_stop["y"])),
			Vector2(float(to_stop["x"]), float(to_stop["y"])),
			false,
			false
		)
		var serialized_points := _serialize_points(route.get("points", []))
		var segment := {
			"from_stop_id": from_id,
			"to_stop_id": to_id,
			"success": bool(route.get("success", false)),
			"length_world": float(route.get("length", 0.0)),
			"road_ids": route.get("road_ids", []).duplicate(),
			"points": serialized_points,
		}
		segments.append(segment)
		route_length_world += float(segment["length_world"])

		var route_points: Array[Vector2] = []
		for raw_point in route.get("points", []):
			if raw_point is Vector2:
				route_points.append(raw_point)
		for point_index in range(route_points.size()):
			if not combined_points.is_empty() and point_index == 0:
				if combined_points.back().distance_to(route_points[point_index]) <= 0.001:
					continue
			combined_points.append(route_points[point_index])

	var built := bool(line_state.get("built", false))
	return {
		"id": line_key,
		"name": "Bus Line %d" % Data.line_number(line_key),
		"color": Data.LINE_COLORS[line_key].to_html(false),
		"status": "active" if built else "planned",
		"stop_ids": active_stop_ids,
		"planned_stop_ids": planned_stop_ids,
		"route_segments": segments,
		"route_points": _serialize_points(combined_points),
		"route_length_world": route_length_world,
		"fleet_count": int(line_state.get("fleet_count", 0)),
		"legacy_line_key": line_key,
		"source": "legacy",
	}

static func _refresh_stop_activity(network: Dictionary) -> void:
	var stops: Dictionary = network.get("stops", {})
	for stop_id_value in stops.keys():
		var stop_id := str(stop_id_value)
		var stop: Dictionary = stops[stop_id]
		stop["status"] = "planned"
		stop["served_line_ids"] = []
		stops[stop_id] = stop

	var lines: Dictionary = network.get("lines", {})
	for line_id_value in lines.keys():
		var line_id := str(line_id_value)
		var line: Dictionary = lines[line_id]
		for stop_id_value in line.get("stop_ids", []):
			var stop_id := str(stop_id_value)
			if not stops.has(stop_id):
				continue
			var stop: Dictionary = stops[stop_id]
			stop["status"] = "built"
			var served: Array = stop.get("served_line_ids", [])
			if bool(line.get("status", "" ) == "active") and not served.has(line_id):
				served.append(line_id)
			stop["served_line_ids"] = served
			stops[stop_id] = stop
	network["stops"] = stops

static func _serialize_points(points_value) -> Array:
	var result: Array = []
	for point_value in points_value:
		if point_value is Vector2:
			var point: Vector2 = point_value
			result.append({"x": point.x, "y": point.y})
		elif typeof(point_value) == TYPE_DICTIONARY:
			var raw: Dictionary = point_value
			result.append({
				"x": float(raw.get("x", 0.0)),
				"y": float(raw.get("y", 0.0)),
			})
	return result
