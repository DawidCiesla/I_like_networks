extends SceneTree

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const Terrain = preload("res://scripts/world/terrain_model.gd")

func _init() -> void:
	_test_shared_interchanges()
	_test_route_geometry()
	_test_terrain_determinism()
	print("GODOT PORT SELF-TEST: PASS")
	quit(0)

func _test_shared_interchanges() -> void:
	assert(Data.STATION_IDS.line1[2] == Data.STATION_IDS.line2[0])
	assert(Data.STATION_IDS.line1[3] == Data.STATION_IDS.line3[0])
	assert(Data.STATION_IDS.line2[3] == Data.STATION_IDS.line4[0])
	assert(Data.STATION_IDS.line1[4] == Data.STATION_IDS.line4[4])

func _test_route_geometry() -> void:
	for line_key in Data.LINE_KEYS:
		var max_stops := int(Data.LINE_CONFIG[line_key].max_stops)
		var route := Layout.built_route(line_key, max_stops)
		assert(route.size() >= 2)
		assert(Layout.route_length(route) > 300.0)

	for line_key in ["line3", "line4"]:
		var segments: Array = Layout.BASE_SEGMENTS[line_key]
		for segment_index in range(segments.size()):
			var points := Layout.segment_points(line_key, segment_index)
			var distance := Layout.route_length(points)
			assert(distance >= 350.0)
			assert(distance <= 1250.0)

func _test_terrain_determinism() -> void:
	var samples := [
		Vector2.ZERO,
		Vector2(420.0, -180.0),
		Vector2(-900.0, 700.0),
		Vector2(1400.0, -600.0),
	]

	for point in samples:
		var first := Terrain.height(Data.DEFAULT_CITY_SEED, point.x, point.y)
		var second := Terrain.height(Data.DEFAULT_CITY_SEED, point.x, point.y)
		assert(is_equal_approx(first, second))

		var slope := Terrain.slope_degrees(Data.DEFAULT_CITY_SEED, point.x, point.y)
		assert(is_finite(slope))
		assert(slope >= 0.0)

		var forest := Terrain.forest_potential(Data.DEFAULT_CITY_SEED, point.x, point.y)
		assert(forest >= 0.0 and forest <= 1.0)
