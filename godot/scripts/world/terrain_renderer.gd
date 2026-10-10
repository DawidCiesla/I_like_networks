extends MeshInstance3D

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const GroundCoverRenderer = preload("res://scripts/world/ground_cover_renderer.gd")
const LandscapeDetailRenderer = preload("res://scripts/world/landscape_detail_renderer.gd")
const RiparianDetailRenderer = preload("res://scripts/world/riparian_detail_renderer.gd")
const PremiumTerrainShader = preload("res://scripts/world/terrain_surface.gdshader")
const VisualCache = preload("res://scripts/world/region_visual_cache.gd")
const TerrainMeshBuilder = preload("res://scripts/world/terrain_mesh_builder.gd")
const GEOMETRY_REVISION := 1

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
var startup_loading := true
var startup_progress := 0.0
var cache_directory := ""
var cache_hit := false
var build_duration_ms := 0
var worker_count := 0
var _active_builder: RefCounted
var _build_request := 0


func _ready() -> void:
	var game_store := get_node_or_null("/root/GameStore")
	if game_store != null and game_store.has_signal("terrain_changed"):
		game_store.terrain_changed.connect(rebuild)
	_setup_natural_detail()
	await rebuild(true)


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


func rebuild(progressive: bool = false) -> void:
	_build_request += 1
	var request := _build_request
	if _active_builder != null:
		_active_builder.cancel_and_wait()
		_active_builder = null
	var started := Time.get_ticks_msec()
	var game_store := get_node_or_null("/root/GameStore")
	if game_store == null:
		return
	bounds = _world_bounds()
	var seed := int(game_store.get("city_seed"))
	var map := MapDefinition.active_definition()
	var steps := TerrainSurface.grid_steps(bounds)
	var key := VisualCache.create_key("terrain", {
		"geometry_revision": GEOMETRY_REVISION,
		"seed": seed,
		"map_identity": {"id": map.get("id"), "generator_version": map.get("generator_version")},
		"terrain_edits": map.get("terrain_edits", {}),
		"bounds": bounds, "resolution": steps,
	})
	var result := VisualCache.load_mesh(key, cache_directory)
	cache_hit = result != null and result.get_surface_count() > 0
	worker_count = 0
	if not cache_hit:
		if progressive and _is_regional_map():
			var builder := TerrainMeshBuilder.new()
			_active_builder = builder
			result = await builder.build(seed, bounds, steps, true, map.get("terrain_edits", {}), self)
			if request != _build_request or not is_inside_tree():
				return
			worker_count = builder.worker_count
			_active_builder = null
		else:
			result = await _build_mesh(bounds, seed, progressive)
		if request != _build_request or not is_inside_tree() or result == null or result.get_surface_count() == 0:
			return
		VisualCache.save_mesh(key, result, cache_directory)
	mesh = result
	if mesh != null and mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, create_premium_material())
	startup_progress = 1.0
	startup_loading = false
	build_duration_ms = Time.get_ticks_msec() - started
	if _is_regional_map():
		_setup_natural_detail()
	print("[RegionLoad] terrain cache=%s workers=%d elapsed_ms=%d" % ["hit" if cache_hit else "miss", worker_count, build_duration_ms])


func _exit_tree() -> void:
	_build_request += 1
	if _active_builder != null:
		_active_builder.cancel_and_wait()


func _is_regional_map() -> bool:
	return MapDefinition.active_map_id() != MapDefinition.LEGACY_CITY_MAP_ID


func _world_bounds() -> Rect2:
	return TerrainSurface.world_bounds()


func _build_mesh(rect: Rect2, seed: int, progressive: bool = false) -> ArrayMesh:
	var steps := TerrainSurface.grid_steps(rect)
	var x_steps := steps.x
	var z_steps := steps.y
	var stride := x_steps + 1
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var slice_start := Time.get_ticks_msec()

	# Indexed world grid: expensive regional biome/hydrology sampling is done once
	# per terrain vertex instead of once for every triangle corner.
	for z_index in range(z_steps + 1):
		var world_z := rect.position.y + rect.size.y * float(z_index) / float(z_steps)
		for x_index in range(x_steps + 1):
			var world_x := rect.position.x + rect.size.x * float(x_index) / float(x_steps)
			_add_vertex(tool, world_x, world_z, seed)
			if progressive and Time.get_ticks_msec() - slice_start >= 8:
				startup_progress = float(z_index * stride + x_index + 1) / float(stride * (z_steps + 1))
				await get_tree().process_frame
				slice_start = Time.get_ticks_msec()

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
			if progressive and Time.get_ticks_msec() - slice_start >= 8:
				await get_tree().process_frame
				slice_start = Time.get_ticks_msec()

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
	var sample: Dictionary = Terrain.regional_surface_sample(seed, x, z) if regional else {}
	var color: Color = sample["color"] if regional else Terrain.terrain_color(seed, x, z)
	var moisture := float(sample["moisture"]) if regional else 0.45
	var ground_cover := float(sample["ground_cover"]) if regional else 0.5
	tool.set_color(color)
	# UV2 is used as compact material metadata rather than texture coordinates:
	# x = local moisture, y = vegetation/ground-cover potential.
	tool.set_uv2(Vector2(clampf(moisture, 0.0, 1.0), clampf(ground_cover, 0.0, 1.0)))
	tool.add_vertex(Vector3(x, y, z))
