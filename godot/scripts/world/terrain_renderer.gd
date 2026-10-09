extends MeshInstance3D

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const GroundCoverRenderer = preload("res://scripts/world/ground_cover_renderer.gd")
const LandscapeDetailRenderer = preload("res://scripts/world/landscape_detail_renderer.gd")
const RiparianDetailRenderer = preload("res://scripts/world/riparian_detail_renderer.gd")
const PremiumTerrainShader = preload("res://scripts/world/terrain_surface.gdshader")

const DEFAULT_GRAIN_STRENGTH := 0.046
const DEFAULT_HEIGHT_TINT_STRENGTH := 0.052
const DEFAULT_SLOPE_TINT_STRENGTH := 0.24
const DEFAULT_MACRO_VARIATION_STRENGTH := 0.075
const DEFAULT_MICRO_VARIATION_STRENGTH := 0.055
const DEFAULT_ROCK_SLOPE_STRENGTH := 0.42
const DEFAULT_MICRO_NORMAL_STRENGTH := 0.32
const DEFAULT_WETNESS_STRENGTH := 0.44
const DEFAULT_CAVITY_STRENGTH := 0.26

var bounds := Rect2()
var _ground_cover: GroundCoverRenderer
var _landscape_detail: LandscapeDetailRenderer
var _riparian_detail: RiparianDetailRenderer


func _ready() -> void:
	var game_store := get_node_or_null("/root/GameStore")
	if game_store != null and game_store.has_signal("terrain_changed"):
		game_store.terrain_changed.connect(rebuild)
	_setup_natural_detail()
	rebuild()


func _setup_natural_detail() -> void:
	if not _is_regional_map():
		return
	if _ground_cover == null:
		_ground_cover = GroundCoverRenderer.new()
		_ground_cover.name = "GroundCover"
		add_child(_ground_cover)
	if _landscape_detail == null:
		_landscape_detail = LandscapeDetailRenderer.new()
		_landscape_detail.name = "LandscapeDetail"
		add_child(_landscape_detail)
	if _riparian_detail == null:
		_riparian_detail = RiparianDetailRenderer.new()
		_riparian_detail.name = "RiparianDetail"
		add_child(_riparian_detail)


func rebuild() -> void:
	var game_store := get_node_or_null("/root/GameStore")
	if game_store == null:
		return
	bounds = _world_bounds()
	mesh = _build_mesh(bounds, int(game_store.get("city_seed")))
	if _is_regional_map():
		_setup_natural_detail()


func _is_regional_map() -> bool:
	return str(MapDefinition.active_definition().get("id", MapDefinition.LEGACY_CITY_MAP_ID)) != MapDefinition.LEGACY_CITY_MAP_ID


func _world_bounds() -> Rect2:
	return TerrainSurface.world_bounds()


func _build_mesh(rect: Rect2, seed: int) -> ArrayMesh:
	var steps := TerrainSurface.grid_steps(rect)
	var x_steps := steps.x
	var z_steps := steps.y
	var stride := x_steps + 1
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Indexed world grid: expensive regional biome/hydrology sampling is done once
	# per terrain vertex instead of once for every triangle corner.
	for z_index in range(z_steps + 1):
		var world_z := rect.position.y + rect.size.y * float(z_index) / float(z_steps)
		for x_index in range(x_steps + 1):
			var world_x := rect.position.x + rect.size.x * float(x_index) / float(x_steps)
			_add_vertex(tool, world_x, world_z, seed)

	for z_index in range(z_steps):
		for x_index in range(x_steps):
			var top_left := z_index * stride + x_index
			var top_right := top_left + 1
			var bottom_left := top_left + stride
			var bottom_right := bottom_left + 1
			tool.add_index(top_left)
			tool.add_index(top_right)
			tool.add_index(bottom_right)
			tool.add_index(top_left)
			tool.add_index(bottom_right)
			tool.add_index(bottom_left)

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
	material.set_shader_parameter("micro_normal_strength", DEFAULT_MICRO_NORMAL_STRENGTH)
	material.set_shader_parameter("wetness_strength", DEFAULT_WETNESS_STRENGTH)
	material.set_shader_parameter("cavity_strength", DEFAULT_CAVITY_STRENGTH)
	return material


func _add_vertex(tool: SurfaceTool, x: float, z: float, seed: int) -> void:
	var y := TerrainSurface.height(seed, x, z)
	var regional := _is_regional_map()
	var color := Terrain.regional_terrain_color(seed, x, z) if regional else Terrain.terrain_color(seed, x, z)
	var moisture := Terrain.regional_moisture(seed, x, z) if regional else 0.45
	var ground_cover := Terrain.regional_ground_cover_potential(seed, x, z) if regional else 0.5
	tool.set_color(color)
	# UV2 is used as compact material metadata rather than texture coordinates:
	# x = local moisture, y = vegetation/ground-cover potential.
	tool.set_uv2(Vector2(clampf(moisture, 0.0, 1.0), clampf(ground_cover, 0.0, 1.0)))
	tool.add_vertex(Vector3(x, y, z))
