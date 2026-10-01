extends RefCounted
class_name TransportLayout

const SPACING_SCALE := 3.2
const ANCHOR := Vector2(-205.0, -20.0)

const BASE_STOPS := {
	"line1": [
		Vector2(-430, 90), Vector2(-315, 90), Vector2(-205, -20),
		Vector2(-25, -85), Vector2(190, -140),
	],
	"line2": [
		Vector2(-205, -20), Vector2(-115, 120), Vector2(45, 185), Vector2(245, 125),
	],
	"line3": [
		Vector2(-25, -85), Vector2(60, -250), Vector2(-40, -390),
		Vector2(-190, -455), Vector2(-340, -410),
	],
	"line4": [
		Vector2(245, 125), Vector2(390, 220), Vector2(520, 130),
		Vector2(455, -20), Vector2(190, -140),
	],
}

const BASE_SEGMENTS := {
	"line1": [
		[Vector2(-430, 90), Vector2(-315, 90)],
		[Vector2(-315, 90), Vector2(-255, 90), Vector2(-255, -20), Vector2(-205, -20)],
		[Vector2(-205, -20), Vector2(-110, -20), Vector2(-110, -85), Vector2(-25, -85)],
		[Vector2(-25, -85), Vector2(70, -85), Vector2(70, -140), Vector2(190, -140)],
	],
	"line2": [
		[Vector2(-205, -20), Vector2(-205, 55), Vector2(-115, 55), Vector2(-115, 120)],
		[Vector2(-115, 120), Vector2(-55, 120), Vector2(-55, 185), Vector2(45, 185)],
		[Vector2(45, 185), Vector2(140, 185), Vector2(140, 125), Vector2(245, 125)],
	],
	"line3": [
		[Vector2(-25, -85), Vector2(-25, -175), Vector2(60, -175), Vector2(60, -250)],
		[Vector2(60, -250), Vector2(20, -250), Vector2(20, -390), Vector2(-40, -390)],
		[Vector2(-40, -390), Vector2(-110, -390), Vector2(-110, -455), Vector2(-190, -455)],
		[Vector2(-190, -455), Vector2(-270, -455), Vector2(-270, -410), Vector2(-340, -410)],
	],
	"line4": [
		[Vector2(245, 125), Vector2(330, 125), Vector2(330, 220), Vector2(390, 220)],
		[Vector2(390, 220), Vector2(455, 220), Vector2(455, 130), Vector2(520, 130)],
		[Vector2(520, 130), Vector2(520, 50), Vector2(455, 50), Vector2(455, -20)],
		[Vector2(455, -20), Vector2(350, -20), Vector2(350, -140), Vector2(190, -140)],
	],
}

const BASE_DEPOT := Vector2(-355, 180)
const BASE_DEPOT_SPUR := [
	Vector2(-205, -20), Vector2(-300, -20), Vector2(-300, 120), Vector2(-355, 137),
]

static func spread(point: Vector2) -> Vector2:
	return ANCHOR + (point - ANCHOR) * SPACING_SCALE

static func stop_position(line_key: String, index: int) -> Vector2:
	return spread(BASE_STOPS[line_key][index])

static func line_stops(line_key: String) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for point in BASE_STOPS[line_key]:
		result.append(spread(point))
	return result

static func depot_position() -> Vector2:
	return spread(BASE_DEPOT)

static func _point_toward(from: Vector2, to: Vector2, amount: float) -> Vector2:
	var total := from.distance_to(to)
	if total <= 0.000001:
		return from
	return from.lerp(to, amount / total)

static func _rounded_polyline(points: Array, radius: float = 38.0, steps: int = 5) -> Array[Vector2]:
	var result: Array[Vector2] = []
	if points.size() <= 2:
		for point in points:
			result.append(spread(point))
		return result

	var spread_points: Array[Vector2] = []
	for point in points:
		spread_points.append(spread(point))

	result.append(spread_points[0])
	for index in range(1, spread_points.size() - 1):
		var previous := spread_points[index - 1]
		var corner := spread_points[index]
		var next := spread_points[index + 1]
		var incoming := previous.distance_to(corner)
		var outgoing := corner.distance_to(next)
		var effective_radius: float = minf(radius, minf(incoming * 0.38, outgoing * 0.38))
		var entry := _point_toward(corner, previous, effective_radius)
		var exit := _point_toward(corner, next, effective_radius)
		result.append(entry)

		for step in range(1, steps + 1):
			var t := float(step) / float(steps)
			var inv := 1.0 - t
			result.append(
				entry * (inv * inv)
				+ corner * (2.0 * inv * t)
				+ exit * (t * t)
			)

	result.append(spread_points[spread_points.size() - 1])
	return result

static func segment_points(line_key: String, segment_index: int) -> Array[Vector2]:
	var segments: Array = BASE_SEGMENTS[line_key]
	if segment_index < 0 or segment_index >= segments.size():
		return []
	return _rounded_polyline(segments[segment_index])

static func built_route(line_key: String, stop_count: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var segment_count: int = maxi(0, stop_count - 1)
	if segment_count == 0:
		if stop_count > 0:
			result.append(stop_position(line_key, 0))
		return result

	for segment_index in range(segment_count):
		var segment := segment_points(line_key, segment_index)
		for point_index in range(segment.size()):
			if segment_index > 0 and point_index == 0:
				continue
			result.append(segment[point_index])
	return result

static func future_segment(line_key: String, built_stop_count: int) -> Array[Vector2]:
	if built_stop_count <= 0:
		return []
	return segment_points(line_key, built_stop_count - 1)

static func depot_spur() -> Array[Vector2]:
	return _rounded_polyline(BASE_DEPOT_SPUR)

static func route_length(points: Array[Vector2]) -> float:
	var total := 0.0
	for index in range(points.size() - 1):
		total += points[index].distance_to(points[index + 1])
	return total

static func point_on_route(points: Array[Vector2], distance_along: float) -> Dictionary:
	if points.is_empty():
		return {"position": Vector2.ZERO, "tangent": Vector2.RIGHT}
	if points.size() == 1:
		return {"position": points[0], "tangent": Vector2.RIGHT}

	var total := route_length(points)
	if total <= 0.000001:
		return {"position": points[0], "tangent": Vector2.RIGHT}

	var remaining := fposmod(distance_along, total)
	for index in range(points.size() - 1):
		var a := points[index]
		var b := points[index + 1]
		var length := a.distance_to(b)
		if remaining <= length or index == points.size() - 2:
			var t := 0.0 if length <= 0.000001 else remaining / length
			return {
				"position": a.lerp(b, t),
				"tangent": (b - a).normalized(),
			}
		remaining -= length

	return {"position": points[points.size() - 1], "tangent": Vector2.RIGHT}
