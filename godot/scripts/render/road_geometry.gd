extends RefCounted
class_name RoadGeometry

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")

const DEFAULT_SAMPLE_SPACING := 8.0
const DEFAULT_MITER_LIMIT := 2.2
const EPSILON := 0.000001

static func resample_polyline(
	source_points: Array[Vector2],
	spacing: float = DEFAULT_SAMPLE_SPACING
) -> Array[Vector2]:
	var result: Array[Vector2] = []
	if source_points.is_empty():
		return result

	result.append(source_points[0])
	if source_points.size() == 1:
		return result

	var target_spacing := maxf(0.25, spacing)
	for index in range(source_points.size() - 1):
		var start := source_points[index]
		var finish := source_points[index + 1]
		var segment := finish - start
		var length := segment.length()
		if length <= EPSILON:
			continue

		var steps := maxi(1, ceili(length / target_spacing))
		for step in range(1, steps + 1):
			var point := start.lerp(finish, float(step) / float(steps))
			if result.back().distance_to(point) > EPSILON:
				result.append(point)

	return result

static func create_ribbon_mesh(
	seed: int,
	source_points: Array[Vector2],
	width: float,
	color: Color,
	height_offset: float,
	sample_spacing: float = DEFAULT_SAMPLE_SPACING,
	rounded_caps: bool = true,
	emissive: bool = false,
	emission_energy: float = 0.0
):
	if source_points.size() < 2 or width <= EPSILON:
		return null

	var points := resample_polyline(source_points, sample_spacing)
	if points.size() < 2:
		return null

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.96
	if color.a < 0.99:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emissive:
		material.emission_enabled = true
		material.emission = Color(color.r, color.g, color.b)
		material.emission_energy_multiplier = emission_energy

	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)

	var half_width := width * 0.5
	var left: Array[Vector2] = []
	var right: Array[Vector2] = []
	for index in range(points.size()):
		var offset := _join_offset(points, index, half_width)
		left.append(points[index] + offset)
		right.append(points[index] - offset)

	for index in range(points.size() - 1):
		append_triangle_above_terrain(mesh, seed, left[index], left[index + 1], right[index], height_offset)
		append_triangle_above_terrain(mesh, seed, right[index], left[index + 1], right[index + 1], height_offset)

	if rounded_caps:
		var last_index := points.size() - 1
		var start_point: Vector2 = points[0]
		var end_point: Vector2 = points[last_index]
		var start_outward: Vector2 = (start_point - points[1]).normalized()
		var end_outward: Vector2 = (end_point - points[last_index - 1]).normalized()
		_append_endpoint_cap(
			mesh,
			seed,
			start_point,
			start_outward,
			half_width,
			height_offset
		)
		_append_endpoint_cap(
			mesh,
			seed,
			end_point,
			end_outward,
			half_width,
			height_offset
		)

	mesh.surface_end()
	return mesh

static func create_junction_patch_mesh(
	seed: int,
	center: Vector2,
	arms: Array,
	color: Color,
	height_offset: float
):
	var polygon := junction_polygon(center, arms)
	if polygon.size() < 3:
		return null

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.96

	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)

	var anchor := polygon[0]
	for index in range(1, polygon.size() - 1):
		append_triangle_above_terrain(
			mesh,
			seed,
			anchor,
			polygon[index],
			polygon[index + 1],
			height_offset
		)

	mesh.surface_end()
	return mesh

static func junction_polygon(center: Vector2, arms: Array) -> PackedVector2Array:
	var candidates := PackedVector2Array()
	var max_half_width := 0.0

	for arm_value in arms:
		if typeof(arm_value) != TYPE_DICTIONARY:
			continue
		var arm: Dictionary = arm_value
		var direction: Vector2 = arm.get("direction", Vector2.ZERO)
		var width := float(arm.get("width", 0.0))
		if direction.length_squared() <= EPSILON or width <= EPSILON:
			continue

		direction = direction.normalized()
		var normal := Vector2(-direction.y, direction.x)
		var half_width := width * 0.5
		max_half_width = maxf(max_half_width, half_width)
		# The road ribbons already overlap through the node. The patch only has
		# to close the inside corner, so keep it compact instead of building a
		# large diamond around every crossing.
		var extension := maxf(3.0, half_width * 0.72)

		candidates.append(center + direction * extension + normal * half_width)
		candidates.append(center + direction * extension - normal * half_width)

	if candidates.size() < 3:
		return PackedVector2Array()

	# Round the centre of the junction slightly. This keeps T/Y junctions
	# closed while avoiding the oversized diamond-like patches from V2.
	if max_half_width > EPSILON:
		var center_pad := max_half_width * 0.42
		for index in range(8):
			var angle := TAU * float(index) / 8.0
			candidates.append(
				center + Vector2(cos(angle), sin(angle)) * center_pad
			)

	var hull := Geometry2D.convex_hull(candidates)
	if hull.size() >= 2 and hull[0].distance_to(hull[hull.size() - 1]) <= EPSILON:
		hull.resize(hull.size() - 1)
	return hull

static func _join_offset(
	points: Array[Vector2],
	index: int,
	half_width: float
) -> Vector2:
	if points.size() < 2:
		return Vector2.ZERO

	if index <= 0:
		return _normal(points[1] - points[0]) * half_width
	if index >= points.size() - 1:
		return _normal(points[index] - points[index - 1]) * half_width

	var incoming := (points[index] - points[index - 1]).normalized()
	var outgoing := (points[index + 1] - points[index]).normalized()
	if incoming.length_squared() <= EPSILON:
		return _normal(outgoing) * half_width
	if outgoing.length_squared() <= EPSILON:
		return _normal(incoming) * half_width

	var normal_in := _normal(incoming)
	var normal_out := _normal(outgoing)
	var miter := normal_in + normal_out
	if miter.length_squared() <= EPSILON:
		return normal_out * half_width

	miter = miter.normalized()
	var denominator := absf(miter.dot(normal_out))
	if denominator <= 0.20:
		return normal_out * half_width

	var length := minf(
		half_width / denominator,
		half_width * DEFAULT_MITER_LIMIT
	)
	return miter * length

static func endpoint_cap_points(
	center: Vector2,
	outward: Vector2,
	radius: float,
	segments: int = 10
) -> PackedVector2Array:
	var result := PackedVector2Array()
	if radius <= EPSILON:
		return result

	var safe_outward := outward.normalized()
	if safe_outward.length_squared() <= EPSILON:
		safe_outward = Vector2.RIGHT
	var normal := Vector2(-safe_outward.y, safe_outward.x)
	var safe_segments := maxi(4, segments)

	result.append(center + normal * radius)
	for index in range(1, safe_segments):
		var angle := PI * float(index) / float(safe_segments)
		var offset := normal * cos(angle) + safe_outward * sin(angle)
		result.append(center + offset * radius)
	result.append(center - normal * radius)
	return result

static func _append_endpoint_cap(
	mesh: ImmediateMesh,
	seed: int,
	center: Vector2,
	outward: Vector2,
	radius: float,
	height_offset: float
) -> void:
	var arc := endpoint_cap_points(center, outward, radius)
	if arc.size() < 2:
		return
	for index in range(arc.size() - 1):
		append_triangle_above_terrain(
			mesh,
			seed,
			center,
			arc[index],
			arc[index + 1],
			height_offset
		)

static func append_triangle_above_terrain(
	mesh: ImmediateMesh,
	seed: int,
	a: Vector2,
	b: Vector2,
	c: Vector2,
	height_offset: float
) -> void:
	# Godot treats clockwise triangle winding as front-facing. In the X/Z
	# plane used by the city, a positive Vector2 cross product matches the
	# winding used by terrain_renderer.gd when viewed from above.
	var cross := (b - a).cross(c - a)
	if cross < 0.0:
		var temporary := b
		b = c
		c = temporary

	_add_vertex(mesh, seed, a, height_offset)
	_add_vertex(mesh, seed, b, height_offset)
	_add_vertex(mesh, seed, c, height_offset)

static func _add_vertex(
	mesh: ImmediateMesh,
	seed: int,
	point: Vector2,
	height_offset: float
) -> void:
	mesh.surface_set_normal(Vector3.UP)
	mesh.surface_add_vertex(Vector3(
		point.x,
		TerrainSurface.height(seed, point.x, point.y) + height_offset,
		point.y
	))

static func _normal(direction: Vector2) -> Vector2:
	if direction.length_squared() <= EPSILON:
		return Vector2.UP
	var normalized := direction.normalized()
	return Vector2(-normalized.y, normalized.x)
