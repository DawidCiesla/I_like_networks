extends MeshInstance3D

const Terrain = preload("res://scripts/world/terrain_model.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")

@export var sample_step := 58.0
@export var margin := 620.0

var bounds := Rect2()

func _ready() -> void:
	rebuild()

func rebuild() -> void:
	bounds = _world_bounds()
	mesh = _build_mesh(bounds)

func _world_bounds() -> Rect2:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF

	for line_key in ["line1", "line2", "line3", "line4"]:
		for point in Layout.line_stops(line_key):
			min_x = min(min_x, point.x)
			max_x = max(max_x, point.x)
			min_z = min(min_z, point.y)
			max_z = max(max_z, point.y)

	var depot := Layout.depot_position()
	min_x = min(min_x, depot.x)
	max_x = max(max_x, depot.x)
	min_z = min(min_z, depot.y)
	max_z = max(max_z, depot.y)

	return Rect2(
		Vector2(min_x - margin, min_z - margin),
		Vector2(max_x - min_x + margin * 2.0, max_z - min_z + margin * 2.0)
	)

func _build_mesh(rect: Rect2) -> ArrayMesh:
	var x_steps := maxi(2, ceili(rect.size.x / sample_step))
	var z_steps := maxi(2, ceili(rect.size.y / sample_step))
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	for z_index in range(z_steps):
		for x_index in range(x_steps):
			var x0 := rect.position.x + rect.size.x * float(x_index) / float(x_steps)
			var x1 := rect.position.x + rect.size.x * float(x_index + 1) / float(x_steps)
			var z0 := rect.position.y + rect.size.y * float(z_index) / float(z_steps)
			var z1 := rect.position.y + rect.size.y * float(z_index + 1) / float(z_steps)

			_add_vertex(tool, x0, z0)
			_add_vertex(tool, x1, z0)
			_add_vertex(tool, x1, z1)

			_add_vertex(tool, x0, z0)
			_add_vertex(tool, x1, z1)
			_add_vertex(tool, x0, z1)

	tool.generate_normals()
	var result := tool.commit()

	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	material.metallic = 0.0
	result.surface_set_material(0, material)
	return result

func _add_vertex(tool: SurfaceTool, x: float, z: float) -> void:
	var y := Terrain.height(GameStore.city_seed, x, z)
	tool.set_color(Terrain.terrain_color(GameStore.city_seed, x, z))
	tool.add_vertex(Vector3(x, y, z))
