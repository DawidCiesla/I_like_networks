extends RefCounted

static func frontage_yaw_adjustment(
	rotation_radians: float,
	building_point: Vector2,
	road_points: Array[Vector2],
	local_front_side: float
) -> float:
	if road_points.size() < 2:
		return 0.0

	var closest_point := Vector2.ZERO
	var best_distance_squared := INF
	for index in range(road_points.size() - 1):
		var start := road_points[index]
		var end := road_points[index + 1]
		var tangent := end - start
		var length_squared := tangent.length_squared()
		if length_squared <= 0.000001:
			continue
		var amount := clampf((building_point - start).dot(tangent) / length_squared, 0.0, 1.0)
		var projected := start + tangent * amount
		var distance_squared := building_point.distance_squared_to(projected)
		if distance_squared < best_distance_squared:
			best_distance_squared = distance_squared
			closest_point = projected

	if best_distance_squared == INF:
		return 0.0

	var road_tangent := Vector2(cos(rotation_radians), sin(rotation_radians))
	var parcel_offset := building_point - closest_point
	var side := road_tangent.x * parcel_offset.y - road_tangent.y * parcel_offset.x
	if absf(side) <= 0.0001:
		return 0.0

	# Root yaw is -rotationRadians: local +Z points to the tangent's left side.
	var road_side_in_local_z := -signf(side)
	return 0.0 if is_equal_approx(road_side_in_local_z, signf(local_front_side)) else PI
