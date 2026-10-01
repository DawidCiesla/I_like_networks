extends MeshInstance3D

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")

var bounds := Rect2()

func _ready() -> void:
	rebuild()

func rebuild() -> void:
	bounds = _world_bounds()
	mesh = _build_mesh(bounds)

func _world_bounds() -> Rect2:
	return TerrainSurface.world_bounds()

func _build_mesh(rect: Rect2) -> ArrayMesh:
	var steps := TerrainSurface.grid_steps(rect)
	var x_steps := steps.x
	var z_steps := steps.y
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
