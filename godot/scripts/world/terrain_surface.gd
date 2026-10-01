extends RefCounted
class_name TerrainSurface

const Terrain = preload("res://scripts/world/terrain_model.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")

# These constants define the actual triangulated surface rendered by
# terrain_renderer.gd. Anything that must sit flush on the visible terrain
# should query this class instead of sampling TerrainModel.height() directly.
const SAMPLE_STEP := 58.0
const MARGIN := 620.0

static func world_bounds() -> Rect2:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF

	for line_key in ["line1", "line2", "line3", "line4"]:
		for point in Layout.line_stops(line_key):
			min_x = minf(min_x, point.x)
			max_x = maxf(max_x, point.x)
			min_z = minf(min_z, point.y)
			max_z = maxf(max_z, point.y)

	var depot := Layout.depot_position()
	min_x = minf(min_x, depot.x)
	max_x = maxf(max_x, depot.x)
	min_z = minf(min_z, depot.y)
	max_z = maxf(max_z, depot.y)

	return Rect2(
		Vector2(min_x - MARGIN, min_z - MARGIN),
		Vector2(max_x - min_x + MARGIN * 2.0, max_z - min_z + MARGIN * 2.0)
	)

static func grid_steps(rect: Rect2) -> Vector2i:
	return Vector2i(
		maxi(2, ceili(rect.size.x / SAMPLE_STEP)),
		maxi(2, ceili(rect.size.y / SAMPLE_STEP))
	)

static func height(seed: int, x: float, z: float) -> float:
	var rect := world_bounds()
	var rect_end := rect.position + rect.size
	if (
		x < rect.position.x
		or x > rect_end.x
		or z < rect.position.y
		or z > rect_end.y
	):
		return Terrain.height(seed, x, z)

	var steps := grid_steps(rect)
	var step_x := rect.size.x / float(steps.x)
	var step_z := rect.size.y / float(steps.y)
	var local_x := (x - rect.position.x) / step_x
	var local_z := (z - rect.position.y) / step_z

	var x_index := clampi(floori(local_x), 0, steps.x - 1)
	var z_index := clampi(floori(local_z), 0, steps.y - 1)
	var tx := clampf(local_x - float(x_index), 0.0, 1.0)
	var tz := clampf(local_z - float(z_index), 0.0, 1.0)

	var x0 := rect.position.x + step_x * float(x_index)
	var x1 := x0 + step_x
	var z0 := rect.position.y + step_z * float(z_index)
	var z1 := z0 + step_z

	var h00 := Terrain.height(seed, x0, z0)
	var h10 := Terrain.height(seed, x1, z0)
	var h01 := Terrain.height(seed, x0, z1)
	var h11 := Terrain.height(seed, x1, z1)

	# terrain_renderer.gd triangulates each cell along the (x0,z0)->(x1,z1)
	# diagonal. Interpolate over the exact same two triangles.
	if tz <= tx:
		return h00 + tx * (h10 - h00) + tz * (h11 - h10)
	return h00 + tx * (h11 - h01) + tz * (h01 - h00)
