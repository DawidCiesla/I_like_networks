extends SceneTree

const MetroSurfaceFeaturesScript = preload("res://scripts/render/metro_surface_features.gd")

var failures := 0


func _initialize() -> void:
	_test_short_and_straight_routes()
	_test_station_clearance_and_cutaway_margin()
	_test_bend_keeps_trace_outside_cutaway()
	_test_entrance_sign_geometry_layout()

	if failures == 0:
		print("MetroSurfaceFeatures: PASS (station entries, cutaway tracing and batching layout)")
		quit(0)
	else:
		push_error("MetroSurfaceFeatures: %d failure(s)" % failures)
		quit(1)


func _test_short_and_straight_routes() -> void:
	var short_route: Array[Vector2] = [Vector2.ZERO, Vector2(80.0, 0.0)]
	_expect(
		MetroSurfaceFeaturesScript.route_trace_dashes(short_route).is_empty(),
		"short metro routes do not get surface dashes near either entrance"
	)
	var route: Array[Vector2] = [Vector2.ZERO, Vector2(600.0, 0.0)]
	var dashes := MetroSurfaceFeaturesScript.route_trace_dashes(route)
	_expect(dashes.size() >= 5, "long metro routes produce a lightweight dashed trace")
	if dashes.is_empty():
		return
	for dash_value in dashes:
		var dash: Dictionary = dash_value
		var points: Array[Vector2] = dash.get("points", [])
		_expect(points.size() >= 2, "each route dash contains geometry samples")
		for point in points:
			_expect(
				absf(point.y - MetroSurfaceFeaturesScript.DEFAULT_TRACE_OFFSET) < 0.001,
				"straight-route marking stays parallel at the intended offset"
			)
		var from_distance := float(dash.get("from_distance", -1.0))
		var to_distance := float(dash.get("to_distance", -1.0))
		_expect(from_distance >= MetroSurfaceFeaturesScript.DEFAULT_STATION_CLEARANCE, "trace leaves clear space at the first entrance")
		_expect(to_distance <= 600.0 - MetroSurfaceFeaturesScript.DEFAULT_STATION_CLEARANCE, "trace leaves clear space at the final entrance")


func _test_station_clearance_and_cutaway_margin() -> void:
	var route: Array[Vector2] = [Vector2.ZERO, Vector2(600.0, 0.0)]
	var stations: Array[Vector2] = [Vector2(0.0, 0.0), Vector2(300.0, 0.0), Vector2(600.0, 0.0)]
	var dashes := MetroSurfaceFeaturesScript.route_trace_dashes(
		route,
		MetroSurfaceFeaturesScript.DEFAULT_TRACE_OFFSET,
		MetroSurfaceFeaturesScript.DEFAULT_DASH_LENGTH,
		MetroSurfaceFeaturesScript.DEFAULT_DASH_GAP,
		MetroSurfaceFeaturesScript.DEFAULT_STATION_CLEARANCE,
		MetroSurfaceFeaturesScript.DEFAULT_ROUTE_SAMPLE_SPACING,
		stations
	)
	var station_clearance := MetroSurfaceFeaturesScript.DEFAULT_STATION_CLEARANCE
	for dash_value in dashes:
		var dash: Dictionary = dash_value
		var from_distance := float(dash.get("from_distance", -1.0))
		var to_distance := float(dash.get("to_distance", -1.0))
		_expect(
			to_distance < 300.0 - station_clearance or from_distance > 300.0 + station_clearance,
			"intermediate station entrances clear the underground trace"
		)
	for point in _all_points(dashes):
		var outer_edge_clearance := point.y - MetroSurfaceFeaturesScript.DEFAULT_TRACE_WIDTH * 0.5
		_expect(
			outer_edge_clearance > MetroSurfaceFeaturesScript.CUTAWAY_HALF_WIDTH,
			"surface marking stays on intact terrain outside the tunnel cutaway"
		)


func _test_bend_keeps_trace_outside_cutaway() -> void:
	var route: Array[Vector2] = [Vector2.ZERO, Vector2(475.0, 0.0), Vector2(475.0, 500.0)]
	var dashes := MetroSurfaceFeaturesScript.route_trace_dashes(route)
	var points := _all_points(dashes)
	_expect(not points.is_empty(), "bent routes still receive surface traces")
	for point in points:
		_expect(
			_distance_to_route(point, route) - MetroSurfaceFeaturesScript.DEFAULT_TRACE_WIDTH * 0.5 > MetroSurfaceFeaturesScript.CUTAWAY_HALF_WIDTH,
			"mitered traces remain beyond the cutaway even through a route bend"
		)


func _test_entrance_sign_geometry_layout() -> void:
	var layout := MetroSurfaceFeaturesScript.entrance_sign_layout()
	var panel_size: Vector3 = layout["panel_size"]
	var panel_position: Vector3 = layout["panel_position"]
	var canopy_top_y := float(layout["canopy_top_y"])
	_expect(
		panel_position.y - panel_size.y * 0.5 >= canopy_top_y,
		"entrance sign panel clears the station canopy"
	)
	var supports: Array = layout["support_positions"]
	var support_size: Vector3 = layout["support_size"]
	_expect(supports.size() == 2, "surface entrance sign uses a pair of light supports")
	for support_value in supports:
		var support: Vector3 = support_value
		_expect(absf(support.x) < panel_size.x * 0.5, "sign supports align beneath the panel")
		_expect(support.y - support_size.y * 0.5 <= canopy_top_y + 0.001, "sign supports meet the canopy roof")
		_expect(support.y + support_size.y * 0.5 >= panel_position.y - panel_size.y * 0.5, "sign supports reach the panel")
	var label_position: Vector3 = layout["label_position"]
	_expect(
		absf(label_position.x - panel_position.x) <= panel_size.x * 0.5
			and label_position.y >= panel_position.y - panel_size.y * 0.5
			and label_position.y <= panel_position.y + panel_size.y * 0.5,
		"metro letter sits within the surface sign panel"
	)
	_expect(
		label_position.z < panel_position.z - panel_size.z * 0.5,
		"metro letter is visible on the panel's front face"
	)


func _all_points(dashes: Array[Dictionary]) -> Array[Vector2]:
	var points: Array[Vector2] = []
	for dash_value in dashes:
		var dash: Dictionary = dash_value
		for point in dash.get("points", []):
			points.append(point)
	return points


func _distance_to_route(point: Vector2, route: Array[Vector2]) -> float:
	var nearest := INF
	for index in range(route.size() - 1):
		var start: Vector2 = route[index]
		var segment := route[index + 1] - start
		if segment.length_squared() <= 0.000001:
			continue
		var t := clampf((point - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
		nearest = minf(nearest, point.distance_to(start + segment * t))
	return nearest


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	failures += 1
	push_error("MetroSurfaceFeatures: %s" % description)
