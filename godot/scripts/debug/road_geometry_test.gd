extends SceneTree

const Data = preload("res://scripts/core/game_data.gd")
const RoadGeometry = preload("res://scripts/render/road_geometry.gd")

var _failed := false

func _init() -> void:
	_test_arterial_ribbon_caps_cover_the_rounded_ends()
	if _failed:
		push_error("ROAD GEOMETRY TEST FAILED")
		quit(1)
		return
	print("ROAD GEOMETRY TESTS PASSED")
	quit(0)

func _test_arterial_ribbon_caps_cover_the_rounded_ends() -> void:
	const arterial_width := 31.0
	const radius := arterial_width * 0.5
	var route: Array[Vector2] = [Vector2.ZERO, Vector2(120.0, 0.0)]
	var mesh = RoadGeometry.create_ribbon_mesh(
		Data.DEFAULT_CITY_SEED,
		route,
		arterial_width,
		Color.WHITE,
		0.065,
		8.0,
		true
	)
	_expect(mesh != null, "arterial ribbon mesh is created")
	if mesh == null:
		return
	_expect(mesh.get_surface_count() == 1, "arterial ribbon has one surface")
	if mesh.get_surface_count() == 0:
		return
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_expect(not vertices.is_empty(), "arterial ribbon has triangles")

	# Sample points safely inside each rounded semicircle. This inspects the
	# actual generated triangles, so a rounded boundary without a filled cap
	# fails even if endpoint_cap_points() itself still returns a valid arc.
	for endpoint in [Vector2.ZERO, Vector2(120.0, 0.0)]:
		var outward := Vector2.LEFT if endpoint == Vector2.ZERO else Vector2.RIGHT
		var normal := Vector2(-outward.y, outward.x)
		for angle_step in range(1, 20):
			var angle := PI * float(angle_step) / 20.0
			var direction := normal * cos(angle) + outward * sin(angle)
			for radius_step in range(1, 5):
				var point: Vector2 = endpoint + direction * radius * float(radius_step) / 5.0
				_expect(
					_point_is_covered(point, vertices),
					"rounded arterial endpoint covers interior sample %s" % str(point)
				)

	# The cap must reach the road-width boundary at the end of the semicircle.
	for endpoint in [Vector2.ZERO, Vector2(120.0, 0.0)]:
		var outward := Vector2.LEFT if endpoint == Vector2.ZERO else Vector2.RIGHT
		var normal := Vector2(-outward.y, outward.x)
		for side in [-1.0, 1.0]:
			var seam: Vector2 = endpoint + normal * radius * side
			_expect(
				_point_is_covered(seam, vertices),
				"rounded arterial cap joins the ribbon at %s" % str(seam)
			)

func _point_is_covered(point: Vector2, vertices: PackedVector3Array) -> bool:
	for index in range(0, vertices.size() - 2, 3):
		var a := Vector2(vertices[index].x, vertices[index].z)
		var b := Vector2(vertices[index + 1].x, vertices[index + 1].z)
		var c := Vector2(vertices[index + 2].x, vertices[index + 2].z)
		if _point_in_triangle(point, a, b, c):
			return true
	return false

func _point_in_triangle(point: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var ab := (b - a).cross(point - a)
	var bc := (c - b).cross(point - b)
	var ca := (a - c).cross(point - c)
	return (
		(ab >= -0.0001 and bc >= -0.0001 and ca >= -0.0001)
		or (ab <= 0.0001 and bc <= 0.0001 and ca <= 0.0001)
	)

func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	push_error(message)
