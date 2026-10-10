extends MeshInstance3D
class_name WaterSurfaceRenderer

const WorldLayers = preload("res://scripts/world/world_layers.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const GameData = preload("res://scripts/core/game_data.gd")
const WaterShader = preload("res://scripts/world/water_surface.gdshader")
const FarWaterShader = preload("res://scripts/world/water_surface_far.gdshader")
const VisualCache = preload("res://scripts/world/region_visual_cache.gd")
const GEOMETRY_REVISION := 1

const DEFAULT_RESOLUTION := Vector2i(96, 96)
const REGIONAL_RESOLUTION := Vector2i(192, 192)
const MAX_GRID_STEPS := 192
const WATER_SURFACE_OFFSET := 0.24
const RIVER_SHALLOWS_COLOR := Color(0.16, 0.53, 0.56, 1.0)
const RIVER_DEEP_COLOR := Color(0.026, 0.14, 0.235, 1.0)
const LAKE_SHALLOWS_COLOR := Color(0.20, 0.57, 0.64, 1.0)
const LAKE_DEEP_COLOR := Color(0.018, 0.105, 0.245, 1.0)
const RIVER_MAX_DEPTH := 7.5
const LAKE_MAX_DEPTH := 9.0
const NEAR_CHUNK_SIZE_METERS := 1800.0
const FAR_CHUNK_SIZE_METERS := 4200.0
const NEAR_END_METERS := 3200.0
const FAR_END_METERS := 9800.0
const CHUNK_BUILD_BUDGET_USEC := 1800
const EDIT_REFRESH_BUDGET_USEC := 900

var startup_loading := true
var startup_progress := 0.0
var cache_directory := ""
var cache_hit := false
var build_duration_ms := 0
var _build_request := 0
var _chunks_root: Node3D
var _source_arrays: Array = []
var _source_seed := 0
var _near_material: ShaderMaterial
var _far_material: ShaderMaterial
var _terrain_edit_refresh_running := false
var _terrain_edit_refresh_pending := false


func _ready() -> void:
	var active_map := MapDefinition.active_definition()
	var seed := int(active_map.get("seed", GameData.DEFAULT_CITY_SEED))
	var store := get_node_or_null("/root/GameStore")
	if store != null and store.has_signal("terrain_changed"):
		store.terrain_changed.connect(_on_terrain_changed)
	var regional := str(active_map.get("id", "")) != MapDefinition.LEGACY_CITY_MAP_ID
	var resolution := REGIONAL_RESOLUTION if regional else DEFAULT_RESOLUTION
	await rebuild(seed, TerrainSurface.world_bounds(), resolution, true)


func _on_terrain_changed() -> void:
	if _is_regional_map() and not _source_arrays.is_empty():
		_terrain_edit_refresh_pending = true
		if not _terrain_edit_refresh_running:
			call_deferred("_refresh_chunked_water_after_edit")
		return
	var active_map := MapDefinition.active_definition()
	var resolution := REGIONAL_RESOLUTION if str(active_map.get("id", "")) != MapDefinition.LEGACY_CITY_MAP_ID else DEFAULT_RESOLUTION
	rebuild(
		int(active_map.get("seed", GameData.DEFAULT_CITY_SEED)),
		TerrainSurface.world_bounds(),
		resolution
	)


func rebuild(
	seed: int,
	bounds: Rect2,
	resolution: Vector2i = DEFAULT_RESOLUTION,
	progressive: bool = false
) -> void:
	_build_request += 1
	var request := _build_request
	var started := Time.get_ticks_msec()
	var map := MapDefinition.active_definition()
	var key := VisualCache.create_key("water", {
		"geometry_revision": GEOMETRY_REVISION,
		"seed": seed,
		"map_identity": {"id": map.get("id"), "generator_version": map.get("generator_version")},
		"terrain_edits": map.get("terrain_edits", {}),
		"bounds": bounds,
		"resolution": resolution,
	})
	var result: ArrayMesh = VisualCache.load_mesh(key, cache_directory)
	cache_hit = result != null
	if not cache_hit:
		result = await build_mesh(seed, bounds, resolution, get_tree() if progressive else null, self if progressive else null)
		if request != _build_request or not is_inside_tree() or result == null:
			return
		VisualCache.save_mesh(key, result, cache_directory)

	if _is_regional_map():
		_source_seed = seed
		_source_arrays = result.surface_get_arrays(0) if result.get_surface_count() > 0 else []
		mesh = null
		material_override = null
		_ensure_materials()
		await _rebuild_water_chunks(progressive, request)
		if request != _build_request or not is_inside_tree():
			return
	else:
		_clear_chunk_root()
		mesh = result
		material_override = create_water_material()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	startup_progress = 1.0
	startup_loading = false
	build_duration_ms = Time.get_ticks_msec() - started
	print("[RegionLoad] water cache=%s chunked=%s elapsed_ms=%d" % [
		"hit" if cache_hit else "miss",
		str(_is_regional_map()),
		build_duration_ms,
	])


func _ensure_materials() -> void:
	if _near_material == null:
		_near_material = create_water_material()
	if _far_material == null:
		_far_material = ShaderMaterial.new()
		_far_material.shader = FarWaterShader


func _rebuild_water_chunks(progressive: bool, request: int) -> void:
	var new_root := Node3D.new()
	new_root.name = "WaterChunks"
	if _source_arrays.is_empty():
		_swap_chunk_root(new_root)
		return
	var specs: Array[Dictionary] = [
		{
			"name": "Near",
			"chunk_size": NEAR_CHUNK_SIZE_METERS,
			"begin": 0.0,
			"end": NEAR_END_METERS,
			"material": _near_material,
		},
		{
			"name": "Far",
			"chunk_size": FAR_CHUNK_SIZE_METERS,
			"begin": NEAR_END_METERS,
			"end": FAR_END_METERS,
			"material": _far_material,
		},
	]
	var slice_started := Time.get_ticks_usec()
	for spec in specs:
		var layer := Node3D.new()
		layer.name = "LOD%s" % str(spec["name"])
		new_root.add_child(layer)
		var buckets := _partition_triangles(float(spec["chunk_size"]))
		var keys: Array = buckets.keys()
		keys.sort_custom(func(a: Vector2i, b: Vector2i):
			return a.y < b.y or (a.y == b.y and a.x < b.x)
		)
		for key_value in keys:
			var key: Vector2i = key_value
			var source_indices: Array = buckets[key]
			var instance := _create_water_chunk(key, source_indices, spec)
			if instance != null:
				layer.add_child(instance)
			if progressive and Time.get_ticks_usec() - slice_started >= CHUNK_BUILD_BUDGET_USEC:
				await get_tree().process_frame
				if request != _build_request or not is_inside_tree():
					new_root.free()
					return
				slice_started = Time.get_ticks_usec()
	if request != _build_request or not is_inside_tree():
		new_root.free()
		return
	_swap_chunk_root(new_root)


func _partition_triangles(chunk_size: float) -> Dictionary:
	var result: Dictionary = {}
	var vertices: PackedVector3Array = _source_arrays[Mesh.ARRAY_VERTEX]
	var triangle_end := vertices.size() - vertices.size() % 3
	for first in range(0, triangle_end, 3):
		var centroid := (vertices[first] + vertices[first + 1] + vertices[first + 2]) / 3.0
		var key := Vector2i(floori(centroid.x / chunk_size), floori(centroid.z / chunk_size))
		var bucket: Array = result.get(key, [])
		bucket.append(first)
		bucket.append(first + 1)
		bucket.append(first + 2)
		result[key] = bucket
	return result


func _create_water_chunk(key: Vector2i, source_indices: Array, spec: Dictionary) -> MeshInstance3D:
	if source_indices.is_empty():
		return null
	var chunk_size := float(spec["chunk_size"])
	var origin := Vector2((float(key.x) + 0.5) * chunk_size, (float(key.y) + 0.5) * chunk_size)
	var source_vertices: PackedVector3Array = _source_arrays[Mesh.ARRAY_VERTEX]
	var source_normals: PackedVector3Array = _source_arrays[Mesh.ARRAY_NORMAL]
	var source_colors: PackedColorArray = _source_arrays[Mesh.ARRAY_COLOR]
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(source_indices.size())
	normals.resize(source_indices.size())
	colors.resize(source_indices.size())
	for local_index in range(source_indices.size()):
		var source_index := int(source_indices[local_index])
		var position: Vector3 = source_vertices[source_index]
		vertices[local_index] = Vector3(position.x - origin.x, position.y, position.z - origin.y)
		normals[local_index] = source_normals[source_index] if source_index < source_normals.size() else Vector3.UP
		colors[local_index] = source_colors[source_index] if source_index < source_colors.size() else Color.TRANSPARENT
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var chunk_mesh := ArrayMesh.new()
	chunk_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	chunk_mesh.surface_set_material(0, spec["material"])
	var instance := MeshInstance3D.new()
	instance.name = "%s_%d_%d" % [str(spec["name"]), key.x, key.y]
	instance.position = Vector3(origin.x, 0.0, origin.y)
	instance.mesh = chunk_mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.visibility_range_begin = float(spec["begin"])
	instance.visibility_range_end = float(spec["end"])
	return instance


func _refresh_chunked_water_after_edit() -> void:
	if _terrain_edit_refresh_running:
		return
	_terrain_edit_refresh_running = true
	while _terrain_edit_refresh_pending and is_inside_tree():
		_terrain_edit_refresh_pending = false
		_build_request += 1
		var request := _build_request
		if _source_arrays.is_empty():
			break
		var vertices: PackedVector3Array = _source_arrays[Mesh.ARRAY_VERTEX]
		var slice_started := Time.get_ticks_usec()
		for index in range(vertices.size()):
			var position := vertices[index]
			position.y = TerrainSurface.height(_source_seed, position.x, position.z) + WATER_SURFACE_OFFSET
			vertices[index] = position
			if Time.get_ticks_usec() - slice_started >= EDIT_REFRESH_BUDGET_USEC:
				await get_tree().process_frame
				if request != _build_request or not is_inside_tree():
					break
				slice_started = Time.get_ticks_usec()
		if request == _build_request and is_inside_tree():
			_source_arrays[Mesh.ARRAY_VERTEX] = vertices
			await _rebuild_water_chunks(true, request)
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


static func build_mesh(
	seed: int,
	bounds: Rect2,
	resolution: Vector2i = DEFAULT_RESOLUTION,
	frame_tree: SceneTree = null,
	progress_owner: Node = null
) -> ArrayMesh:
	var empty_mesh := ArrayMesh.new()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return empty_mesh
	var steps := Vector2i(
		clampi(resolution.x, 1, MAX_GRID_STEPS),
		clampi(resolution.y, 1, MAX_GRID_STEPS)
	)
	var point_count := (steps.x + 1) * (steps.y + 1)
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(point_count)
	colors.resize(point_count)
	var stride := steps.x + 1
	var slice_start := Time.get_ticks_msec()
	for grid_z in range(steps.y + 1):
		var tz := float(grid_z) / float(steps.y)
		var world_z := bounds.position.y + bounds.size.y * tz
		for grid_x in range(steps.x + 1):
			var tx := float(grid_x) / float(steps.x)
			var world_x := bounds.position.x + bounds.size.x * tx
			var world_point := Vector2(world_x, world_z)
			var layer_sample: Dictionary = WorldLayers.sample_water(seed, world_point)
			var water_depth := float(layer_sample["water_depth"])
			var water_kind := str(layer_sample["water_kind"])
			var vertex_index := grid_z * stride + grid_x
			vertices[vertex_index] = Vector3(
				world_x,
				TerrainSurface.height(seed, world_x, world_z) + WATER_SURFACE_OFFSET,
				world_z
			)
			colors[vertex_index] = water_color_for_depth(water_kind, water_depth)
			if frame_tree != null and Time.get_ticks_msec() - slice_start >= 8:
				progress_owner.set("startup_progress", float(vertex_index + 1) / float(point_count))
				await frame_tree.process_frame
				if not is_instance_valid(progress_owner) or not progress_owner.is_inside_tree():
					return null
				slice_start = Time.get_ticks_msec()
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var has_geometry := false
	for grid_z in range(steps.y):
		for grid_x in range(steps.x):
			var top_left := grid_z * stride + grid_x
			var top_right := top_left + 1
			var bottom_left := top_left + stride
			var bottom_right := bottom_left + 1
			has_geometry = _append_triangle(tool, vertices, colors, top_left, bottom_left, top_right) or has_geometry
			has_geometry = _append_triangle(tool, vertices, colors, top_right, bottom_left, bottom_right) or has_geometry
			if frame_tree != null and Time.get_ticks_msec() - slice_start >= 8:
				await frame_tree.process_frame
				if not is_instance_valid(progress_owner) or not progress_owner.is_inside_tree():
					return null
				slice_start = Time.get_ticks_msec()
	if not has_geometry:
		return empty_mesh
	tool.generate_normals()
	var generated := tool.commit()
	return generated if generated != null else empty_mesh


static func create_water_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = WaterShader
	material.set_shader_parameter("wave_strength", 0.070)
	material.set_shader_parameter("wave_speed", 0.68)
	material.set_shader_parameter("fresnel_strength", 0.54)
	material.set_shader_parameter("refraction_strength", 0.013)
	material.set_shader_parameter("shore_foam_strength", 0.28)
	return material


static func _append_triangle(
	tool: SurfaceTool,
	vertices: PackedVector3Array,
	colors: PackedColorArray,
	first: int,
	second: int,
	third: int
) -> bool:
	if maxf(colors[first].a, maxf(colors[second].a, colors[third].a)) <= 0.0:
		return false
	tool.set_color(colors[first])
	tool.add_vertex(vertices[first])
	tool.set_color(colors[second])
	tool.add_vertex(vertices[second])
	tool.set_color(colors[third])
	tool.add_vertex(vertices[third])
	return true


static func water_color_for_depth(kind: String, depth: float) -> Color:
	if not is_finite(depth) or depth <= 0.0 or kind == "none":
		return Color(1.0, 1.0, 1.0, 0.0)
	var is_lake := kind == "lake"
	var max_depth := LAKE_MAX_DEPTH if is_lake else RIVER_MAX_DEPTH
	var depth_ratio := clampf(depth / max_depth, 0.0, 1.0)
	var shade := _smoothstep(0.08, 0.78, depth_ratio)
	var shallows := LAKE_SHALLOWS_COLOR if is_lake else RIVER_SHALLOWS_COLOR
	var deep_water := LAKE_DEEP_COLOR if is_lake else RIVER_DEEP_COLOR
	var water_color := shallows.lerp(deep_water, shade)
	water_color.a = lerpf(0.30, 0.66, _smoothstep(0.04, 0.70, depth_ratio))
	return water_color


static func _smoothstep(edge_low: float, edge_high: float, value: float) -> float:
	var weight := clampf((value - edge_low) / (edge_high - edge_low), 0.0, 1.0)
	return weight * weight * (3.0 - 2.0 * weight)


func _is_regional_map() -> bool:
	return MapDefinition.active_map_id() != MapDefinition.LEGACY_CITY_MAP_ID


func _exit_tree() -> void:
	_build_request += 1
