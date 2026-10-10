extends MeshInstance3D

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const GroundCoverRenderer = preload("res://scripts/world/ground_cover_renderer.gd")
const LandscapeDetailRenderer = preload("res://scripts/world/landscape_detail_renderer.gd")
const RiparianDetailRenderer = preload("res://scripts/world/riparian_detail_renderer.gd")
const NearTerrainShader = preload("res://scripts/world/terrain_surface.gdshader")
const MediumTerrainShader = preload("res://scripts/world/terrain_surface_medium.gdshader")
const FarTerrainShader = preload("res://scripts/world/terrain_surface_far.gdshader")
const VisualCache = preload("res://scripts/world/region_visual_cache.gd")
const TerrainMeshBuilder = preload("res://scripts/world/terrain_mesh_builder.gd")
const GEOMETRY_REVISION := 1

# All LODs use the same ~1.8 km spatial tiles so their AABB centres match.
# Geometry density and shader cost drop with distance. A short downward skirt on
# every tile edge hides T-junction cracks when adjacent chunks use different LODs.
const CHUNK_CELLS := 32
const NEAR_SAMPLE_FACTOR := 1
const MEDIUM_SAMPLE_FACTOR := 2
const FAR_SAMPLE_FACTOR := 4
const NEAR_END_METERS := 2200.0
const MEDIUM_END_METERS := 5200.0
# A zero end range disables the far-distance cutoff in Godot. The far layer is
# already very cheap and must remain available at maximum region zoom.
const FAR_END_METERS := 0.0
const TERRAIN_SKIRT_DEPTH := 36.0
const CHUNK_BUILD_BUDGET_USEC := 2500
const TERRAIN_EDIT_BUDGET_USEC := 1200

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
var _natural_detail_enabled := true

var _chunks_root: Node3D
var _source_arrays: Array = []
var _source_steps := Vector2i.ZERO
var _source_seed := 0
var _near_material: ShaderMaterial
var _medium_material: ShaderMaterial
var _far_material: ShaderMaterial
var _terrain_edit_refresh_running := false
var _terrain_edit_refresh_pending := false


func _ready() -> void:
	var game_store := get_node_or_null("/root/GameStore")
	if game_store != null and game_store.has_signal("terrain_changed"):
		game_store.terrain_changed.connect(_on_terrain_changed)
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
	_apply_natural_detail_enabled()


func set_natural_detail_enabled(enabled: bool) -> void:
	_natural_detail_enabled = enabled
	_apply_natural_detail_enabled()


func _apply_natural_detail_enabled() -> void:
	for renderer in [_ground_cover, _landscape_detail, _riparian_detail]:
		if not is_instance_valid(renderer):
			continue
		renderer.visible = _natural_detail_enabled
		renderer.set_process(_natural_detail_enabled)
		if _natural_detail_enabled and renderer.has_method("_mark_dirty"):
			renderer.call("_mark_dirty")


func _on_terrain_changed() -> void:
	if not _is_regional_map() or _source_arrays.is_empty():
		rebuild(false)
		return
	_terrain_edit_refresh_pending = true
	if not _terrain_edit_refresh_running:
		call_deferred("_refresh_chunked_terrain_after_edit")


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
		"bounds": bounds,
		"resolution": steps,
	})
	var result: ArrayMesh = VisualCache.load_mesh(key, cache_directory)
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

	if _is_regional_map():
		_source_arrays = result.surface_get_arrays(0)
		_source_steps = steps
		_source_seed = seed
		mesh = null
		material_override = null
		_ensure_lod_materials()
		await _rebuild_chunk_layers(progressive, request)
		if request != _build_request or not is_inside_tree():
			return
	else:
		_clear_chunk_root()
		mesh = result
		if mesh != null and mesh.get_surface_count() > 0:
			mesh.surface_set_material(0, create_premium_material())

	startup_progress = 1.0
	startup_loading = false
	build_duration_ms = Time.get_ticks_msec() - started
	if _is_regional_map():
		_setup_natural_detail()
	print("[RegionLoad] terrain cache=%s workers=%d chunked=%s elapsed_ms=%d" % [
		"hit" if cache_hit else "miss",
		worker_count,
		str(_is_regional_map()),
		build_duration_ms,
	])


func _ensure_lod_materials() -> void:
	if _near_material == null:
		_near_material = ShaderMaterial.new()
		_near_material.shader = NearTerrainShader
	if _medium_material == null:
		_medium_material = ShaderMaterial.new()
		_medium_material.shader = MediumTerrainShader
	if _far_material == null:
		_far_material = ShaderMaterial.new()
		_far_material.shader = FarTerrainShader


func _rebuild_chunk_layers(progressive: bool, request: int) -> void:
	var new_root := Node3D.new()
	new_root.name = "TerrainChunks"
	var layer_specs: Array[Dictionary] = [
		{
			"name": "Near",
			"factor": NEAR_SAMPLE_FACTOR,
			"begin": 0.0,
			"end": NEAR_END_METERS,
			"material": _near_material,
		},
		{
			"name": "Medium",
			"factor": MEDIUM_SAMPLE_FACTOR,
			"begin": NEAR_END_METERS,
			"end": MEDIUM_END_METERS,
			"material": _medium_material,
		},
		{
			"name": "Far",
			"factor": FAR_SAMPLE_FACTOR,
			"begin": MEDIUM_END_METERS,
			"end": FAR_END_METERS,
			"material": _far_material,
		},
	]
	var chunks_x := ceili(float(_source_steps.x) / float(CHUNK_CELLS))
	var chunks_z := ceili(float(_source_steps.y) / float(CHUNK_CELLS))
	var total_chunks := chunks_x * chunks_z * layer_specs.size()
	var built_chunks := 0
	var slice_started := Time.get_ticks_usec()
	for spec in layer_specs:
		var layer := Node3D.new()
		layer.name = "LOD%s" % str(spec["name"])
		new_root.add_child(layer)
		var factor := int(spec["factor"])
		for z0 in range(0, _source_steps.y, CHUNK_CELLS):
			var z1 := mini(z0 + CHUNK_CELLS, _source_steps.y)
			for x0 in range(0, _source_steps.x, CHUNK_CELLS):
				var x1 := mini(x0 + CHUNK_CELLS, _source_steps.x)
				var instance := _create_terrain_chunk(x0, z0, x1, z1, factor, spec)
				if instance != null:
					layer.add_child(instance)
				built_chunks += 1
				if progressive and Time.get_ticks_usec() - slice_started >= CHUNK_BUILD_BUDGET_USEC:
					startup_progress = 0.90 + 0.095 * float(built_chunks) / float(maxi(1, total_chunks))
					await get_tree().process_frame
					if request != _build_request or not is_inside_tree():
						new_root.free()
						return
					slice_started = Time.get_ticks_usec()
	if request != _build_request or not is_inside_tree():
		new_root.free()
		return
	_swap_chunk_root(new_root)


func _create_terrain_chunk(
	x0: int,
	z0: int,
	x1: int,
	z1: int,
	factor: int,
	spec: Dictionary
) -> MeshInstance3D:
	var source_vertices: PackedVector3Array = _source_arrays[Mesh.ARRAY_VERTEX]
	if source_vertices.is_empty():
		return null
	var x_indices := _sample_indices(x0, x1, factor)
	var z_indices := _sample_indices(z0, z1, factor)
	if x_indices.size() < 2 or z_indices.size() < 2:
		return null
	var source_stride := _source_steps.x + 1
	var first_position: Vector3 = source_vertices[z0 * source_stride + x0]
	var last_position: Vector3 = source_vertices[z1 * source_stride + x1]
	var origin := Vector2(
		(first_position.x + last_position.x) * 0.5,
		(first_position.z + last_position.z) * 0.5
	)
	var chunk_mesh := _build_chunk_mesh(x_indices, z_indices, origin)
	if chunk_mesh == null:
		return null
	chunk_mesh.surface_set_material(0, spec["material"])
	var instance := MeshInstance3D.new()
	instance.name = "%s_%d_%d" % [str(spec["name"]), x0, z0]
	instance.position = Vector3(origin.x, 0.0, origin.y)
	instance.mesh = chunk_mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.visibility_range_begin = float(spec["begin"])
	instance.visibility_range_end = float(spec["end"])
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	return instance


func _build_chunk_mesh(x_indices: Array[int], z_indices: Array[int], origin: Vector2) -> ArrayMesh:
	var source_vertices: PackedVector3Array = _source_arrays[Mesh.ARRAY_VERTEX]
	var source_normals: PackedVector3Array = _source_arrays[Mesh.ARRAY_NORMAL]
	var source_colors: PackedColorArray = _source_arrays[Mesh.ARRAY_COLOR]
	var source_uv2: PackedVector2Array = _source_arrays[Mesh.ARRAY_TEX_UV2]
	var source_stride := _source_steps.x + 1
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uv2 := PackedVector2Array()
	var local_count := x_indices.size() * z_indices.size()
	vertices.resize(local_count)
	normals.resize(local_count)
	colors.resize(local_count)
	uv2.resize(local_count)
	var local_index := 0
	for global_z in z_indices:
		for global_x in x_indices:
			var source_index := int(global_z) * source_stride + int(global_x)
			var position: Vector3 = source_vertices[source_index]
			vertices[local_index] = Vector3(position.x - origin.x, position.y, position.z - origin.y)
			normals[local_index] = source_normals[source_index] if source_index < source_normals.size() else Vector3.UP
			colors[local_index] = source_colors[source_index] if source_index < source_colors.size() else Color.WHITE
			uv2[local_index] = source_uv2[source_index] if source_index < source_uv2.size() else Vector2(0.45, 0.5)
			local_index += 1
	var indices := PackedInt32Array()
	var width := x_indices.size()
	var height := z_indices.size()
	for local_z in range(height - 1):
		for local_x in range(width - 1):
			var top_left := local_z * width + local_x
			var top_right := top_left + 1
			var bottom_left := top_left + width
			var bottom_right := bottom_left + 1
			indices.append(top_left)
			indices.append(top_right)
			indices.append(bottom_right)
			indices.append(top_left)
			indices.append(bottom_right)
			indices.append(bottom_left)

	var north: Array[int] = []
	var south: Array[int] = []
	var west: Array[int] = []
	var east: Array[int] = []
	for x in range(width):
		# Reverse north so clockwise front faces point out of the tile.
		north.append(width - 1 - x)
		south.append((height - 1) * width + x)
	for z in range(height):
		west.append(z * width)
		# Reverse east for the same reason.
		east.append((height - 1 - z) * width + width - 1)
	_append_skirt(north, Vector3(0.0, 0.0, -1.0), vertices, normals, colors, uv2, indices)
	_append_skirt(south, Vector3(0.0, 0.0, 1.0), vertices, normals, colors, uv2, indices)
	_append_skirt(west, Vector3(-1.0, 0.0, 0.0), vertices, normals, colors, uv2, indices)
	_append_skirt(east, Vector3(1.0, 0.0, 0.0), vertices, normals, colors, uv2, indices)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = indices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result


func _append_skirt(
	edge: Array[int],
	outward_normal: Vector3,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uv2: PackedVector2Array,
	indices: PackedInt32Array
) -> void:
	if edge.size() < 2:
		return
	var skirt_start := vertices.size()
	for top_index in edge:
		var bottom := vertices[top_index]
		bottom.y -= TERRAIN_SKIRT_DEPTH
		vertices.append(bottom)
		normals.append(outward_normal)
		colors.append(colors[top_index])
		uv2.append(uv2[top_index])
	for segment in range(edge.size() - 1):
		var top_a := edge[segment]
		var top_b := edge[segment + 1]
		var bottom_a := skirt_start + segment
		var bottom_b := bottom_a + 1
		indices.append(top_a)
		indices.append(bottom_a)
		indices.append(top_b)
		indices.append(top_b)
		indices.append(bottom_a)
		indices.append(bottom_b)


func _sample_indices(start_index: int, end_index: int, factor: int) -> Array[int]:
	var result: Array[int] = []
	var current := start_index
	while current < end_index:
		result.append(current)
		current += maxi(1, factor)
	if result.is_empty() or result.back() != end_index:
		result.append(end_index)
	return result


func _refresh_chunked_terrain_after_edit() -> void:
	if _terrain_edit_refresh_running:
		return
	_terrain_edit_refresh_running = true
	while _terrain_edit_refresh_pending and is_inside_tree():
		_terrain_edit_refresh_pending = false
		_build_request += 1
		var request := _build_request
		var vertices: PackedVector3Array = _source_arrays[Mesh.ARRAY_VERTEX]
		var slice_started := Time.get_ticks_usec()
		for index in range(vertices.size()):
			var position := vertices[index]
			position.y = TerrainSurface.height(_source_seed, position.x, position.z)
			vertices[index] = position
			if Time.get_ticks_usec() - slice_started >= TERRAIN_EDIT_BUDGET_USEC:
				await get_tree().process_frame
				if request != _build_request or not is_inside_tree():
					break
				slice_started = Time.get_ticks_usec()
		if request == _build_request and is_inside_tree():
			_source_arrays[Mesh.ARRAY_VERTEX] = vertices
			await _rebuild_chunk_layers(true, request)
	_terrain_edit_refresh_running = false


func _swap_chunk_root(new_root: Node3D) -> void:
	if is_instance_valid(_chunks_root):
		remove_child(_chunks_root)
		_chunks_root.free()
	_chunks_root = new_root
	add_child(_chunks_root)


func _clear_chunk_root() -> void:
	if is_instance_valid(_chunks_root):
		remove_child(_chunks_root)
		_chunks_root.free()
	_chunks_root = null


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
	if result == null:
		return ArrayMesh.new()
	return result


static func create_premium_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = NearTerrainShader
	return material


func _add_vertex(tool: SurfaceTool, x: float, z: float, seed: int) -> void:
	var y := TerrainSurface.height(seed, x, z)
	var regional := _is_regional_map()
	var sample: Dictionary = Terrain.regional_surface_sample(seed, x, z) if regional else {}
	var color: Color = sample["color"] if regional else Terrain.terrain_color(seed, x, z)
	var moisture := float(sample["moisture"]) if regional else 0.45
	var ground_cover := float(sample["ground_cover"]) if regional else 0.5
	tool.set_color(color)
	tool.set_uv2(Vector2(clampf(moisture, 0.0, 1.0), clampf(ground_cover, 0.0, 1.0)))
	tool.add_vertex(Vector3(x, y, z))
