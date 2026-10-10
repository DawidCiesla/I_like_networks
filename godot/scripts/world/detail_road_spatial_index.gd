extends RefCounted
class_name DetailRoadSpatialIndex

const CELL_SIZE := 192.0
const INDEX_PADDING := 64.0

var _cells: Dictionary = {}


func rebuild(roads: Array) -> void:
	_cells.clear()
	for road_value in roads:
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		var half_width := _road_half_width(road)
		var points: Array = road.get("points", [])
		for index in range(points.size() - 1):
			var a := _road_point(points[index])
			var b := _road_point(points[index + 1])
			var min_x := minf(a.x, b.x) - half_width - INDEX_PADDING
			var max_x := maxf(a.x, b.x) + half_width + INDEX_PADDING
			var min_y := minf(a.y, b.y) - half_width - INDEX_PADDING
			var max_y := maxf(a.y, b.y) + half_width + INDEX_PADDING
			var min_cell_x := floori(min_x / CELL_SIZE)
			var max_cell_x := floori(max_x / CELL_SIZE)
			var min_cell_y := floori(min_y / CELL_SIZE)
			var max_cell_y := floori(max_y / CELL_SIZE)
			var segment := {"a": a, "b": b, "half_width": half_width}
			for cell_y in range(min_cell_y, max_cell_y + 1):
				for cell_x in range(min_cell_x, max_cell_x + 1):
					var key := Vector2i(cell_x, cell_y)
					var bucket: Array = _cells.get(key, [])
					bucket.append(segment)
					_cells[key] = bucket


func point_near_road(point: Vector2, extra_clearance: float) -> bool:
	var key := Vector2i(floori(point.x / CELL_SIZE), floori(point.y / CELL_SIZE))
	var bucket: Array = _cells.get(key, [])
	for segment_value in bucket:
		var segment: Dictionary = segment_value
		if _distance_to_segment(point, segment["a"], segment["b"]) < float(segment["half_width"]) + extra_clearance:
			return true
	return false


func is_empty() -> bool:
	return _cells.is_empty()


static func _road_half_width(road: Dictionary) -> float:
	var width := 15.0
	match str(road.get("class", "local")):
		"arterial": width = 31.0
		"collector": width = 21.0
		"service": width = 12.0
	return width * 0.5


static func _road_point(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if typeof(value) == TYPE_DICTIONARY:
		var point: Dictionary = value
		return Vector2(float(point.get("x", 0.0)), float(point.get("y", 0.0)))
	return Vector2.ZERO


static func _distance_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq <= 0.000001:
		return point.distance_to(a)
	var t: float = clampf((point - a).dot(ab) / length_sq, 0.0, 1.0)
	return point.distance_to(a + ab * t)
