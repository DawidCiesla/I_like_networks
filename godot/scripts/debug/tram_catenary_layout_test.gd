extends SceneTree

const TramCatenaryLayoutScript = preload("res://scripts/render/tram_catenary_layout.gd")
const TramPantographMeshScript = preload("res://scripts/render/tram_pantograph_mesh.gd")

var failures := 0


func _initialize() -> void:
	_test_empty_and_degenerate_routes()
	_test_straight_route_support_spacing()
	_test_curved_route_frames_and_wire_samples()
	_test_pantograph_mesh_surfaces()

	if failures == 0:
		print("TramCatenaryLayout: PASS (terrain-ready poles, spans, curved route sampling)")
		quit(0)
	else:
		push_error("TramCatenaryLayout: %d failure(s)" % failures)
		quit(1)


func _test_empty_and_degenerate_routes() -> void:
	var empty: Array[Vector2] = []
	var empty_layout := TramCatenaryLayoutScript.build_layout(empty)
	_expect((empty_layout.get("pole_frames", []) as Array).is_empty(), "empty tram routes have no poles")
	_expect((empty_layout.get("spans", []) as Array).is_empty(), "empty tram routes have no wires")

	var degenerate: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
	var degenerate_layout := TramCatenaryLayoutScript.build_layout(degenerate)
	_expect((degenerate_layout.get("pole_frames", []) as Array).is_empty(), "zero-length routes do not produce catenary geometry")


func _test_straight_route_support_spacing() -> void:
	var route: Array[Vector2] = [Vector2.ZERO, Vector2(280.0, 0.0)]
	var layout := TramCatenaryLayoutScript.build_layout(route)
	var poles: Array = layout.get("pole_frames", [])
	var spans: Array = layout.get("spans", [])
	_expect(poles.size() == 3, "a 280 metre route gets three regularly spaced poles")
	_expect(spans.size() == 2, "adjacent pole pairs form two wire spans")
	if poles.size() != 3 or spans.size() != 2:
		return
	_expect(float(poles[0].get("distance", -1.0)) > 0.0, "the first pole stays clear of the stop")
	_expect(float(poles[-1].get("distance", INF)) < 280.0, "the final pole stays clear of the stop")
	_expect(float(poles[0].get("side", 0.0)) == 1.0, "the first support has a stable side")
	_expect(float(poles[1].get("side", 0.0)) == -1.0, "supports alternate sides along the corridor")
	for span_value in spans:
		var samples: Array = span_value
		for index in range(samples.size() - 1):
			var current: Dictionary = samples[index]
			var next: Dictionary = samples[index + 1]
			var distance := float(next.get("distance", 0.0)) - float(current.get("distance", 0.0))
			_expect(distance <= TramCatenaryLayoutScript.DEFAULT_WIRE_SAMPLE_SPACING + 0.001, "wire samples stay within the target spacing")


func _test_curved_route_frames_and_wire_samples() -> void:
	var route: Array[Vector2] = [Vector2.ZERO, Vector2(100.0, 0.0), Vector2(100.0, 100.0)]
	var layout := TramCatenaryLayoutScript.build_layout(route)
	var poles: Array = layout.get("pole_frames", [])
	var spans: Array = layout.get("spans", [])
	_expect(poles.size() == 2 and spans.size() == 1, "a bend keeps one continuous overhead span")
	if poles.size() != 2 or spans.size() != 1:
		return
	var first: Dictionary = poles[0]
	var last: Dictionary = poles[1]
	var first_point: Vector2 = first.get("point", Vector2.ZERO)
	var last_point: Vector2 = last.get("point", Vector2.ZERO)
	var first_tangent: Vector2 = first.get("tangent", Vector2.ZERO)
	var last_tangent: Vector2 = last.get("tangent", Vector2.ZERO)
	_expect(first_point.x > 0.0 and first_point.x < 50.0 and is_zero_approx(first_point.y), "first pole follows cumulative route distance before the bend")
	_expect(is_equal_approx(last_point.x, 100.0) and last_point.y > 50.0, "last pole follows cumulative route distance after the bend")
	_expect(first_tangent.is_equal_approx(Vector2.RIGHT), "pole frame follows the first route segment")
	_expect(last_tangent.is_equal_approx(Vector2.DOWN), "pole frame follows the bent route segment")
	var samples: Array = spans[0]
	var sample_start: Vector2 = samples.front().get("point", Vector2.ZERO)
	var sample_end: Vector2 = samples.back().get("point", Vector2.ZERO)
	_expect(sample_start.is_equal_approx(first_point), "wire span starts at the first pole")
	_expect(sample_end.is_equal_approx(last_point), "wire span ends at the next pole")


func _test_pantograph_mesh_surfaces() -> void:
	var mesh := ArrayMesh.new()
	TramPantographMeshScript.append_surfaces(mesh)
	_expect(mesh.get_surface_count() == 2, "pantograph frame and collector bar are batched as two mesh surfaces")
	if mesh.get_surface_count() >= 2:
		var collector_vertices: PackedVector3Array = mesh.surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
		_expect(not collector_vertices.is_empty(), "pantograph has a distinct collector contact bar")


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	failures += 1
	push_error("TramCatenaryLayout: %s" % description)
