extends RefCounted
class_name MetroSurfaceFeatures

const CUTAWAY_HALF_WIDTH := 8.4
const DEFAULT_TRACE_OFFSET := 11.4
const DEFAULT_TRACE_WIDTH := 0.72
const DEFAULT_DASH_LENGTH := 22.0
const DEFAULT_DASH_GAP := 32.0
const DEFAULT_STATION_CLEARANCE := 32.0
const DEFAULT_ROUTE_SAMPLE_SPACING := 5.0
const EPSILON := 0.000001


static func route_trace_dashes(
	route: Array[Vector2],
	trace_offset: float = DEFAULT_TRACE_OFFSET,
	dash_length: float = DEFAULT_DASH_LENGTH,
	dash_gap: float = DEFAULT_DASH_GAP,
	station_clearance: float = DEFAULT_STATION_CLEARANCE,
	sample_spacing: float = DEFAULT_ROUTE_SAMPLE_SPACING,
	station_points: Array[Vector2] = []
) -> Array[Dictionary]:
	var clean_route := _clean_route(route)
	var total_length := _route_length(clean_route)
	var safe_dash_length := maxf(1.0, dash_length)
	var start_distance := maxf(0.0, station_clearance)
	var end_distance := total_length - start_distance
	if clean_route.size() < 2 or end_distance - start_distance < safe_dash_length:
		return []

	var dash_step := safe_dash_length + maxf(0.0, dash_gap)
	var safe_sample_spacing := maxf(1.0, sample_spacing)
	var station_distances := _station_route_distances(clean_route, station_points)
	var dashes: Array[Dictionary] = []
	var distance := start_distance
	while distance + safe_dash_length <= end_distance + EPSILON and dashes.size() < 4096:
		var finish_distance := minf(distance + safe_dash_length, end_distance)
		if _overlaps_station_clearance(distance, finish_distance, station_distances, station_clearance):
			distance += dash_step
			continue
		var sample_count := maxi(1, ceili((finish_distance - distance) / safe_sample_spacing))
		var points: Array[Vector2] = []
		for sample_index in range(sample_count + 1):
			var t := float(sample_index) / float(sample_count)
			var point := _trace_point_at_distance(
				clean_route,
				lerpf(distance, finish_distance, t),
				total_length,
				trace_offset
			)
			if point == Vector2.INF:
				points.clear()
				break
			points.append(point)
		if points.size() >= 2:
			dashes.append({
				"points": points,
				"from_distance": distance,
				"to_distance": finish_distance,
			})
		distance += dash_step
	return dashes


static func _station_route_distances(route: Array[Vector2], station_points: Array[Vector2]) -> Array[float]:
	var distances: Array[float] = []
	for station_point in station_points:
		var distance := _closest_route_distance(route, station_point)
		if distance >= 0.0:
			distances.append(distance)
	return distances


static func _closest_route_distance(route: Array[Vector2], point: Vector2) -> float:
	var best_distance := INF
	var best_route_distance := -1.0
	var cumulative := 0.0
	for index in range(route.size() - 1):
		var start: Vector2 = route[index]
		var segment := route[index + 1] - start
		var segment_length := segment.length()
		if segment_length <= EPSILON:
			continue
		var t := clampf((point - start).dot(segment) / (segment_length * segment_length), 0.0, 1.0)
		var projection := start + segment * t
		var distance := point.distance_to(projection)
		if distance < best_distance:
			best_distance = distance
			best_route_distance = cumulative + segment_length * t
		cumulative += segment_length
	return best_route_distance


static func _overlaps_station_clearance(
	start_distance: float,
	end_distance: float,
	station_distances: Array[float],
	station_clearance: float
) -> bool:
	for station_distance in station_distances:
		var clearance_start := station_distance - station_clearance
		var clearance_end := station_distance + station_clearance
		if end_distance > clearance_start + EPSILON and start_distance < clearance_end - EPSILON:
			return true
	return false


static func _trace_point_at_distance(
	route: Array[Vector2],
	distance: float,
	total_length: float,
	trace_offset: float
) -> Vector2:
	if route.size() < 2:
		return Vector2.INF
	var remaining := clampf(distance, 0.0, total_length)
	for index in range(route.size() - 1):
		var start: Vector2 = route[index]
		var finish: Vector2 = route[index + 1]
		var segment := finish - start
		var segment_length := segment.length()
		if segment_length <= EPSILON:
			continue
		if remaining <= segment_length or index == route.size() - 2:
			var t := clampf(remaining / segment_length, 0.0, 1.0)
			var tangent := segment / segment_length
			var normal := Vector2(-tangent.y, tangent.x)
			var start_offset := _vertex_offset(route, index, trace_offset, normal)
			var end_offset := _vertex_offset(route, index + 1, trace_offset, normal)
			return start.lerp(finish, t) + start_offset.lerp(end_offset, t)
		remaining -= segment_length
	return Vector2.INF


static func _vertex_offset(
	route: Array[Vector2],
	vertex_index: int,
	trace_offset: float,
	fallback_normal: Vector2
) -> Vector2:
	if vertex_index <= 0 or vertex_index >= route.size() - 1:
		return fallback_normal * trace_offset
	var incoming := (route[vertex_index] - route[vertex_index - 1]).normalized()
	var outgoing := (route[vertex_index + 1] - route[vertex_index]).normalized()
	var incoming_normal := Vector2(-incoming.y, incoming.x)
	var outgoing_normal := Vector2(-outgoing.y, outgoing.x)
	var miter := incoming_normal + outgoing_normal
	if miter.length_squared() <= EPSILON:
		return fallback_normal * trace_offset
	miter = miter.normalized()
	var denominator := miter.dot(outgoing_normal)
	if denominator <= EPSILON:
		return fallback_normal * trace_offset
	var miter_length := trace_offset / denominator
	if absf(miter_length) > trace_offset * 2.5:
		miter_length = signf(miter_length) * trace_offset * 2.5
	return miter * miter_length


static func entrance_sign_layout() -> Dictionary:
	return {
		"canopy_top_y": 5.71,
		"panel_size": Vector3(6.0, 2.4, 0.36),
		"panel_position": Vector3(0.0, 6.95, -6.15),
		"support_size": Vector3(0.24, 0.42, 0.30),
		"support_positions": [
			Vector3(-2.4, 5.92, -6.15),
			Vector3(2.4, 5.92, -6.15),
		],
		"label_position": Vector3(0.0, 6.98, -6.36),
	}


static func _clean_route(route: Array[Vector2]) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for point in route:
		if result.is_empty() or result.back().distance_to(point) > EPSILON:
			result.append(point)
	return result


static func _route_length(route: Array[Vector2]) -> float:
	var total := 0.0
	for index in range(route.size() - 1):
		total += route[index].distance_to(route[index + 1])
	return total

