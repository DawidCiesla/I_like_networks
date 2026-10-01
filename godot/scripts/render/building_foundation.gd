extends RefCounted

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TERRAIN_SAMPLE_STEP := 8.0
const TOP_CLEARANCE := 0.7

static func height_range(
	seed: int,
	center: Vector2,
	rotation_radians: float,
	width: float,
	depth: float
) -> Vector2:
	var half_width := maxf(0.5, width) * 0.5
	var half_depth := maxf(0.5, depth) * 0.5
	var steps_x := maxi(1, ceili((half_width * 2.0) / TERRAIN_SAMPLE_STEP))
	var steps_z := maxi(1, ceili((half_depth * 2.0) / TERRAIN_SAMPLE_STEP))
	var cosine := cos(rotation_radians)
	var sine := sin(rotation_radians)
	var minimum := INF
	var maximum := -INF

	for z_index in range(steps_z + 1):
		var local_z := -half_depth + (2.0 * half_depth * float(z_index) / float(steps_z))
		for x_index in range(steps_x + 1):
			var local_x := -half_width + (2.0 * half_width * float(x_index) / float(steps_x))
			var world_point := Vector2(
				center.x + cosine * local_x - sine * local_z,
				center.y + sine * local_x + cosine * local_z
			)
			var height := Terrain.height(seed, world_point.x, world_point.y)
			minimum = minf(minimum, height)
			maximum = maxf(maximum, height)

	return Vector2(minimum, maximum)

static func box_transform(
	center: Vector2,
	width: float,
	depth: float,
	rotation_radians: float,
	minimum_ground: float,
	maximum_ground: float,
	clearance: float = TOP_CLEARANCE
) -> Transform3D:
	var top := maximum_ground + clearance
	var thickness := maxf(clearance, top - minimum_ground)
	var rotation_basis := Basis(Vector3.UP, -rotation_radians)
	var basis := Basis(
		rotation_basis.x * width,
		rotation_basis.y * thickness,
		rotation_basis.z * depth
	)
	return Transform3D(
		basis,
		Vector3(center.x, top - thickness * 0.5, center.y)
	)
