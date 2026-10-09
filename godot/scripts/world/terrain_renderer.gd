extends MeshInstance3D

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const GroundCoverRenderer = preload("res://scripts/world/ground_cover_renderer.gd")
const PremiumTerrainShader = preload("res://scripts/world/terrain_surface.gdshader")

const DEFAULT_GRAIN_STRENGTH := 0.046
const DEFAULT_HEIGHT_TINT_STRENGTH := 0.052
const DEFAULT_SLOPE_TINT_STRENGTH := 0.24
const DEFAULT_MACRO_VARIATION_STRENGTH := 0.075
const DEFAULT_MICRO_VARIATION_STRENGTH := 0.055
const DEFAULT_ROCK_SLOPE_STRENGTH := 0.42

var bounds := Rect2()
var _ground_cover: GroundCoverRenderer


func _ready() -> void:
	var game_store := get_node_or_null("/root/GameStore")
	if game_store != null and game_store.has_signal("terrain_changed"):
		game_store.terrain_changed.connect(rebuild)
	_setup_ground_cover()
	rebuild()


func _setup_ground_cover() -> void:
	if _ground_cover != null or not _is_regional_map():
		return
	_ground_cover = GroundCoverRenderer.new()
	_ground_cover.name = "GroundCover"
	add_child(_ground_cover)


func rebuild() -> void:
	var game_store := get_node_or_null("/root/GameStore")
	if game_store == null:
		return
	bounds = _world_bounds()
	mesh = _build_mesh(bounds, int(game_store.get("city_seed")))
	if _is_regional_map():
		_setup_ground_cover()


func _is_regional_map() -> bool:
	return str(MapDefinition.active_definition().get("id", MapDefinition.LEGACY_CITY_MAP_ID)) != MapDefinition.LEGACY_CITY_MAP_ID


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
	material.set_shader_parameter("macro_variation_strength", DEFAULT_MACRO_VARIATION_STRENGTH)
	material.set_shader_parameter("micro_variation_strength", DEFAULT_MICRO_VARIATION_STRENGTH)
	material.set_shader_parameter("rock_slope_strength", DEFAULT_ROCK_SLOPE_STRENGTH)
	return material


func _add_vertex(tool: SurfaceTool, x: float, z: float, seed: int) -> void:
	var y := TerrainSurface.height(seed, x, z)
	var color := Terrain.regional_terrain_color(seed, x, z) if _is_regional_map() else Terrain.terrain_color(seed, x, z)
	tool.set_color(color)
	tool.add_vertex(Vector3(x, y, z))
