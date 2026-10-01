extends RefCounted
class_name TransitNetwork

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const RoadRouter = preload("res://scripts/transport/road_router.gd")

const SCHEMA_VERSION := 2
const SOURCE_LEGACY_BRIDGE := "legacy_bridge"
const SOURCE_FREE_LINES := "free_lines"

const MIN_STOP_SPACING := 70.0
const DEFAULT_CATCHMENT_RADIUS := 180.0
const TRANSFER_WALK_RADIUS := 95.0
const MAX_CUSTOM_STOPS := 12

static func create_legacy_bridge(
	city: Dictionary,
	line_states: Dictionary,
	station_states: Dictionary
) -> Dictionary:
	var network := {
		"schema_version": SCHEMA_VERSION,
		"source": SOURCE_LEGACY_BRIDGE,
		"next_stop_serial": 1,
		"next_line_serial": 1,
		"stops": {},
		"lines": {},
	}
	sync_legacy_bridge(network, city, line_states, station_states)
	return network

static func ensure_legacy_bridge(
	network: Dictionary,
	city: Dictionary,
	line_states: Dictionary,
	station_states: Dictionary
) -> Dictionary:
	if network.is_empty() or int(network.get("schema_version", 0)) != SCHEMA_VERSION:
		return create_legacy_bridge(city, line_states, station_states)

	if not network.has("stops"):
		network["stops"] = {}
	if not network.has("lines"):
		network["lines"] = {}
	if not network.has("next_stop_serial"):
		network["next_stop_serial"] = 1
	if not network.has("next_line_serial"):
		network["next_line_serial"] = 1

	sync_legacy_bridge(network, city, line_states, station_states)
	return network

static func sync_legacy_bridge(
	network: Dictionary,
	city: Dictionary,
	line_states: Dictionary,
	station_states: Dictionary
) -> void:
	var stops: Dictionary = network.get("stops", {})
	var lines: Dictionary = network.get("lines", {})

	for line_key in Data.LINE_KEYS:
		var station_ids: Array = Data.STATION_IDS[line_key]
		for stop_index in range(station_ids.size()):
			var station_id := str(station_ids[stop_index])
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
		lines[line_key] = _legacy_line(
			city,
			line_key,
			line_state,
			stops
		)

	network["stops"] = stops
	network["lines"] = lines
	_refresh_stop_activity(network)

	var has_custom := false
	for line_value in lines.values():
		var line: Dictionary = line_value
		if str(line.get("source", "")) == "custom":
			has_custom = true
			break
	network["source"] = SOURCE_FREE_LINES if has_custom else SOURCE_LEGACY_BRIDGE

static func custom_line_ids(network: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var lines: Dictionary = network.get("lines", {})
	for line_id_value in lines.keys():
		var line_id := str(line_id_value)
		var line: Dictionary = lines[line_id]
		if str(line.get("source", "")) == "custom":
			result.append(line_id)
	result.sort()
	return result

static func active_line_ids(network: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var lines: Dictionary = network.get("lines", {})
	for line_id_value in lines.keys():
		var line_id := str(line_id_value)
		var line: Dictionary = lines[line_id]
		if str(line.get("status", "")) == "active":
			result.append(line_id)
	result.sort()
	return result

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

static func create_custom_line(
	network: Dictionary,
	city: Dictionary,
	points: Array[Vector2],
	color: Color,
	name: String = ""
) -> Dictionary:
	if points.size() < 2:
		return {"success": false, "reason": "need_two_stops"}
	if points.size() > MAX_CUSTOM_STOPS:
		return {"success": false, "reason": "too_many_stops"}

	var snapped: Array[Dictionary] = []
	for point in points:
		var snap := RoadRouter.snap_to_road(city, point, true, 110.0)
		if snap.is_empty():
			return {"success": false, "reason": "stop_not_on_built_road"}
		snapped.append(snap)

	for index in range(snapped.size() - 1):
		var a: Vector2 = snapped[index]["point"]
		var b: Vector2 = snapped[index + 1]["point"]
		if a.distance_to(b) < MIN_STOP_SPACING:
			return {"success": false, "reason": "stops_too_close"}

	var line_serial := int(network.get("next_line_serial", 1))
	network["next_line_serial"] = line_serial + 1
	var line_id := "custom-line-%d" % line_serial
	var stop_ids: Array[String] = []
	var stops: Dictionary = network.get("stops", {})

	for index in range(snapped.size()):
		var snap: Dictionary = snapped[index]
		var point: Vector2 = snap["point"]
		var existing_id := _nearest_active_stop_id(stops, point, 28.0)
		if not existing_id.is_empty():
			stop_ids.append(existing_id)
			continue

		var stop_serial := int(network.get("next_stop_serial", 1))
		network["next_stop_serial"] = stop_serial + 1
		var stop_id := "custom-stop-%d" % stop_serial
		stops[stop_id] = _custom_stop(stop_id, point, snap, stop_serial)
		stop_ids.append(stop_id)

	network["stops"] = stops
	var lines: Dictionary = network.get("lines", {})
	var final_name := name.strip_edges()
	if final_name.is_empty():
		final_name = "Bus Line %d" % (4 + line_serial)
	lines[line_id] = {
		"id": line_id,
		"name": final_name,
		"color": color.to_html(false),
		"status": "active",
		"stop_ids": stop_ids,
		"planned_stop_ids": stop_ids.duplicate(),
		"route_segments": [],
		"route_points": [],
		"route_length_world": 0.0,
		"fleet_count": 1,
		"vehicles": [],
		"next_vehicle_id": 1,
		"waiting_by_stop": [],
		"queue_passengers": 0.0,
		"last_delivered_ppm": 0.0,
		"current_abandonment_ppm": 0.0,
		"event_serial": 0,
		"passenger_events": [],
		"source": "custom",
	}
	network["lines"] = lines
	var rebuild := rebuild_custom_line(network, city, line_id)
	if not bool(rebuild.get("success", false)):
		lines.erase(line_id)
		network["lines"] = lines
		return rebuild

	_refresh_stop_activity(network)
	network["source"] = SOURCE_FREE_LINES
	return {"success": true, "line_id": line_id}

static func update_custom_line_points(
	network: Dictionary,
	city: Dictionary,
	line_id: String,
	points: Array[Vector2]
) -> Dictionary:
	var lines: Dictionary = network.get("lines", {})
	if not lines.has(line_id):
		return {"success": false, "reason": "line_not_found"}
	var line: Dictionary = lines[line_id]
	if str(line.get("source", "")) != "custom":
		return {"success": false, "reason": "legacy_line_locked"}
	if points.size() < 2:
		return {"success": false, "reason": "need_two_stops"}
	if points.size() > MAX_CUSTOM_STOPS:
		return {"success": false, "reason": "too_many_stops"}

	var snaps: Array[Dictionary] = []
	for point in points:
		var snap := RoadRouter.snap_to_road(city, point, true, 110.0)
		if snap.is_empty():
			return {"success": false, "reason": "stop_not_on_built_road"}
		snaps.append(snap)
	for index in range(snaps.size() - 1):
		var a: Vector2 = snaps[index]["point"]
		var b: Vector2 = snaps[index + 1]["point"]
		if a.distance_to(b) < MIN_STOP_SPACING:
			return {"success": false, "reason": "stops_too_close"}

	var old_stop_ids: Array[String] = line_stop_ids(network, line_id)
	var stops: Dictionary = network.get("stops", {})
	var next_ids: Array[String] = []
	for index in range(snaps.size()):
		var snap: Dictionary = snaps[index]
		var point: Vector2 = snap["point"]
		if index < old_stop_ids.size():
			var stop_id := old_stop_ids[index]
			var stop: Dictionary = stops.get(stop_id, {})
			var served: Array = stop.get("served_line_ids", [])
			var shared_with_other := false
			for served_line_value in served:
				if str(served_line_value) != line_id:
					shared_with_other = true
					break
			if (
				str(stop.get("source", "")) == "custom"
				and not shared_with_other
			):
				_apply_snap_to_stop(stop, point, snap)
				stops[stop_id] = stop
				next_ids.append(stop_id)
				continue

		var existing_id := _nearest_active_stop_id(stops, point, 28.0)
		if not existing_id.is_empty():
			next_ids.append(existing_id)
			continue
		var serial := int(network.get("next_stop_serial", 1))
		network["next_stop_serial"] = serial + 1
		var new_id := "custom-stop-%d" % serial
		stops[new_id] = _custom_stop(new_id, point, snap, serial)
		next_ids.append(new_id)

	line["stop_ids"] = next_ids
	line["planned_stop_ids"] = next_ids.duplicate()
	lines[line_id] = line
	network["stops"] = stops
	network["lines"] = lines
	var rebuild := rebuild_custom_line(network, city, line_id)
	if not bool(rebuild.get("success", false)):
		return rebuild
	_prune_unused_custom_stops(network)
	_refresh_stop_activity(network)
	return {"success": true, "line_id": line_id}

static func rebuild_custom_line(
	network: Dictionary,
	city: Dictionary,
	line_id: String
) -> Dictionary:
	var lines: Dictionary = network.get("lines", {})
	if not lines.has(line_id):
		return {"success": false, "reason": "line_not_found"}
	var line: Dictionary = lines[line_id]
	var stop_ids := line_stop_ids(network, line_id)
	var segments: Array = []
	var combined: Array[Vector2] = []
	var total := 0.0

	for index in range(stop_ids.size() - 1):
		var a := stop_position(network, stop_ids[index])
		var b := stop_position(network, stop_ids[index + 1])
		var route := RoadRouter.route_between_points(city, a, b, true, true, 115.0)
		if not bool(route.get("success", false)):
			return {
				"success": false,
				"reason": "segment_unroutable",
				"segment_index": index,
			}
		var route_points: Array[Vector2] = []
		for point_value in route.get("points", []):
			if point_value is Vector2:
				route_points.append(point_value)
		segments.append({
			"from_stop_id": stop_ids[index],
			"to_stop_id": stop_ids[index + 1],
			"success": true,
			"length_world": float(route.get("length", 0.0)),
			"road_ids": route.get("road_ids", []).duplicate(),
			"points": _serialize_points(route_points),
		})
		total += float(route.get("length", 0.0))
		for point_index in range(route_points.size()):
			if not combined.is_empty() and point_index == 0:
				if combined.back().distance_to(route_points[point_index]) <= 0.001:
					continue
			combined.append(route_points[point_index])

	line["route_segments"] = segments
	line["route_points"] = _serialize_points(combined)
	line["route_length_world"] = total
	lines[line_id] = line
	network["lines"] = lines
	return {"success": true, "line_id": line_id}

static func remove_custom_line(network: Dictionary, line_id: String) -> bool:
	var lines: Dictionary = network.get("lines", {})
	if not lines.has(line_id):
		return false
	var line: Dictionary = lines[line_id]
	if str(line.get("source", "")) != "custom":
		return false
	lines.erase(line_id)
	network["lines"] = lines
	_prune_unused_custom_stops(network)
	_refresh_stop_activity(network)
	return true

static func catchment_stats(
	network: Dictionary,
	city: Dictionary,
	stop_id: String,
	radius: float = DEFAULT_CATCHMENT_RADIUS
) -> Dictionary:
	var position := stop_position(network, stop_id)
	var buildings := 0
	var weighted_demand := 0.0
	var residents_proxy := 0.0

	for building_value in city.get("buildings", []):
		var building: Dictionary = building_value
		if str(building.get("status", "")) != "built":
			continue
		var point := Vector2(
			float(building.get("x", 0.0)),
			float(building.get("y", 0.0))
		)
		var distance := position.distance_to(point)
		if distance > radius:
			continue
		buildings += 1
		var profile: Dictionary = building.get("profile", {})
		var density := float(profile.get("density", 1))
		var floors := float(profile.get("floors", 1))
		var zone_factor := _zone_demand_factor(str(building.get("zone", "residential")))
		var proximity := 1.0 - 0.55 * clampf(distance / radius, 0.0, 1.0)
		var weight := (0.55 + density * 0.42 + floors * 0.10) * zone_factor * proximity
		weighted_demand += weight
		residents_proxy += density * maxf(1.0, floors) * zone_factor

	var active_overlap := 0
	var stops: Dictionary = network.get("stops", {})
	for other_id_value in stops.keys():
		var other_id := str(other_id_value)
		if other_id == stop_id:
			continue
		var other: Dictionary = stops[other_id]
		if str(other.get("status", "")) != "built":
			continue
		if position.distance_to(stop_position(network, other_id)) <= radius * 0.72:
			active_overlap += 1

	var overlap_factor := 1.0 / (1.0 + float(active_overlap) * 0.18)
	var demand_ppm := clampf(weighted_demand * 0.22 * overlap_factor, 0.35, 14.0)
	return {
		"radius": radius,
		"building_count": buildings,
		"residents_proxy": residents_proxy,
		"overlap_count": active_overlap,
		"demand_ppm": demand_ppm,
	}

static func stop_accessibility_score(
	network: Dictionary,
	point: Vector2,
	max_distance: float = 380.0
) -> float:
	var score := 0.0
	var stops: Dictionary = network.get("stops", {})
	for stop_id_value in stops.keys():
		var stop_id := str(stop_id_value)
		var stop: Dictionary = stops[stop_id]
		if str(stop.get("status", "")) != "built":
			continue
		var served: Array = stop.get("served_line_ids", [])
		if served.is_empty():
			continue
		var distance := point.distance_to(stop_position(network, stop_id))
		if distance > max_distance:
			continue
		var proximity := 1.0 - distance / max_distance
		var service_factor := 1.0 + minf(1.2, float(served.size() - 1) * 0.35)
		score += proximity * service_factor
	return minf(score, 5.0)

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

static func _custom_stop(
	stop_id: String,
	position: Vector2,
	snap: Dictionary,
	serial: int
) -> Dictionary:
	var result := {
		"id": stop_id,
		"name": "Stop %d" % serial,
		"level": 0,
		"status": "built",
		"served_line_ids": [],
		"source": "custom",
	}
	_apply_snap_to_stop(result, position, snap)
	return result

static func _apply_snap_to_stop(
	stop: Dictionary,
	position: Vector2,
	snap: Dictionary
) -> void:
	var snapped_point: Vector2 = snap.get("point", position)
	stop["x"] = snapped_point.x
	stop["y"] = snapped_point.y
	stop["road_id"] = str(snap.get("road_id", ""))
	stop["edge_id"] = str(snap.get("edge_id", ""))
	stop["edge_t"] = float(snap.get("t", 0.0))
	stop["road_class"] = str(snap.get("road_class", ""))
	stop["snap_distance"] = float(snap.get("distance", 0.0))

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
		var route_points: Array[Vector2] = []
		for point_value in route.get("points", []):
			if point_value is Vector2:
				route_points.append(point_value)
		segments.append({
			"from_stop_id": from_id,
			"to_stop_id": to_id,
			"success": bool(route.get("success", false)),
			"length_world": float(route.get("length", 0.0)),
			"road_ids": route.get("road_ids", []).duplicate(),
			"points": _serialize_points(route_points),
		})
		route_length_world += float(route.get("length", 0.0))
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
		stop["status"] = "planned" if str(stop.get("source", "")) == "legacy" else "built"
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
			if str(line.get("status", "")) == "active" and not served.has(line_id):
				served.append(line_id)
			stop["served_line_ids"] = served
			stops[stop_id] = stop
	network["stops"] = stops

static func _nearest_active_stop_id(
	stops: Dictionary,
	point: Vector2,
	radius: float
) -> String:
	var best_id := ""
	var best_distance := radius
	for stop_id_value in stops.keys():
		var stop_id := str(stop_id_value)
		var stop: Dictionary = stops[stop_id]
		if str(stop.get("status", "")) != "built":
			continue
		var stop_point := Vector2(
			float(stop.get("x", 0.0)),
			float(stop.get("y", 0.0))
		)
		var distance := point.distance_to(stop_point)
		if distance < best_distance:
			best_distance = distance
			best_id = stop_id
	return best_id

static func _prune_unused_custom_stops(network: Dictionary) -> void:
	var used: Dictionary = {}
	var lines: Dictionary = network.get("lines", {})
	for line_value in lines.values():
		var line: Dictionary = line_value
		for stop_id_value in line.get("stop_ids", []):
			used[str(stop_id_value)] = true

	var stops: Dictionary = network.get("stops", {})
	var remove_ids: Array[String] = []
	for stop_id_value in stops.keys():
		var stop_id := str(stop_id_value)
		var stop: Dictionary = stops[stop_id]
		if str(stop.get("source", "")) == "custom" and not used.has(stop_id):
			remove_ids.append(stop_id)
	for stop_id in remove_ids:
		stops.erase(stop_id)
	network["stops"] = stops

static func _zone_demand_factor(zone: String) -> float:
	match zone:
		"commercial":
			return 1.35
		"mixed":
			return 1.22
		"civic":
			return 1.28
		"industrial":
			return 0.82
		_:
			return 1.0

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
