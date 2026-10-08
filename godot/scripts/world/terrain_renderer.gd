extends MeshInstance3D

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const PremiumTerrainShader = preload("res://scripts/world/terrain_surface.gdshader")

const DEFAULT_GRAIN_STRENGTH := 0.034
const DEFAULT_HEIGHT_TINT_STRENGTH := 0.035
const DEFAULT_SLOPE_TINT_STRENGTH := 0.16

var bounds := Rect2()

func _ready() -> void:
	var game_store := get_node_or_null("/root/GameStore")
	if game_store != null and game_store.has_signal("terrain_changed"):
		game_store.terrain_changed.connect(rebuild)
	rebuild()

func rebuild() -> void:
	var game_store := get_node_or_null("/root/GameStore")
	if game_store == null:
		return
	bounds = _world_bounds()
	mesh = _build_mesh(bounds, int(game_store.get("city_seed")))

func _world_bounds() -> Rect2:
	return TerrainSurface.world_bounds()

func _build_mesh(rect: Rect2, seed: int) -> ArrayMesh:
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

			_add_vertex(tool, x0, z0, seed)
			_add_vertex(tool, x1, z0, seed)
			_add_vertex(tool, x1, z1, seed)

			_add_vertex(tool, x0, z0, seed)
			_add_vertex(tool, x1, z1, seed)
			_add_vertex(tool, x0, z1, seed)

	tool.generate_normals()
	var result := tool.commit()

	result.surface_set_material(0, create_premium_material())
	return result

static func create_premium_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = PremiumTerrainShader
	material.set_shader_parameter("grain_strength", DEFAULT_GRAIN_STRENGTH)
	material.set_shader_parameter("height_tint_strength", DEFAULT_HEIGHT_TINT_STRENGTH)
	material.set_shader_parameter("slope_tint_strength", DEFAULT_SLOPE_TINT_STRENGTH)
	return material

func _add_vertex(tool: SurfaceTool, x: float, z: float, seed: int) -> void:
	var y := TerrainSurface.height(seed, x, z)
	tool.set_color(Terrain.terrain_color(seed, x, z))
	tool.add_vertex(Vector3(x, y, z))
