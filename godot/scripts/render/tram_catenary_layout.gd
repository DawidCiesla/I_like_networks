extends RefCounted
class_name TramCatenaryLayout

const DEFAULT_POLE_SPACING := 88.0
const DEFAULT_WIRE_SAMPLE_SPACING := 12.0
const EPSILON := 0.000001


static func build_layout(
	route: Array[Vector2],
	pole_spacing: float = DEFAULT_POLE_SPACING,
	wire_sample_spacing: float = DEFAULT_WIRE_SAMPLE_SPACING
) -> Dictionary:
	var clean_route := _clean_route(route)
	var total_length := _route_length(clean_route)
	if clean_route.size() < 2 or total_length <= EPSILON:
		return {"pole_frames": [], "spans": [], "route_length": total_length}

	var safe_pole_spacing := maxf(1.0, pole_spacing)
	var end_margin := minf(safe_pole_spacing * 0.48, total_length * 0.24)
	var usable_length := maxf(0.0, total_length - end_margin * 2.0)
	var span_count := maxi(1, roundi(usable_length / safe_pole_spacing))
	var pole_frames: Array[Dictionary] = []
	for index in range(span_count + 1):
		var distance := end_margin + usable_length * float(index) / float(span_count)
		var frame := _frame_at_distance(clean_route, distance)
		if frame.is_empty():
			continue
		frame["distance"] = distance
		frame["side"] = 1.0 if index % 2 == 0 else -1.0
		pole_frames.append(frame)

	var spans: Array[Array] = []
	var sample_spacing := maxf(1.0, wire_sample_spacing)
	for index in range(pole_frames.size() - 1):
		var start_distance := float(pole_frames[index].get("distance", 0.0))
		var end_distance := float(pole_frames[index + 1].get("distance", 0.0))
		var span_length := end_distance - start_distance
		var sample_count := maxi(1, ceili(span_length / sample_spacing))
		var samples: Array[Dictionary] = []
		for sample_index in range(sample_count + 1):
			var t := float(sample_index) / float(sample_count)
			var distance := lerpf(start_distance, end_distance, t)
			var frame := _frame_at_distance(clean_route, distance)
			if frame.is_empty():
				continue
			frame["distance"] = distance
			frame["span_t"] = t
			samples.append(frame)
		if samples.size() >= 2:
			spans.append(samples)

	return {
		"pole_frames": pole_frames,
		"spans": spans,
		"route_length": total_length,
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


static func _frame_at_distance(route: Array[Vector2], distance: float) -> Dictionary:
	if route.size() < 2:
		return {}
	var remaining := clampf(distance, 0.0, _route_length(route))
	for index in range(route.size() - 1):
		var start: Vector2 = route[index]
		var finish: Vector2 = route[index + 1]
		var segment := finish - start
		var segment_length := segment.length()
		if segment_length <= EPSILON:
			continue
		if remaining <= segment_length or index == route.size() - 2:
			var point := start.lerp(finish, clampf(remaining / segment_length, 0.0, 1.0))
			var tangent := segment / segment_length
			return {
				"point": point,
				"tangent": tangent,
				"normal": Vector2(-tangent.y, tangent.x),
			}
		remaining -= segment_length
	return {}
