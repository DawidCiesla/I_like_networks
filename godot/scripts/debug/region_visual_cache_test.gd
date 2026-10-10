extends SceneTree

const RegionVisualCache = preload("res://scripts/world/region_visual_cache.gd")

var _failures: int = 0
var _cache_directory: String = ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_cache_directory = "/tmp/region_visual_cache_test_%d" % OS.get_process_id()
	_remove_test_directory()
	var context: Dictionary = _make_context()
	var key: String = RegionVisualCache.create_key("terrain_surface", context)
	_expect(key.length() == 64, "valid geometry context creates a SHA-256 key")
	_expect(RegionVisualCache.load_data(key, _cache_directory) == null, "missing tree payload is a cache miss")
	_expect(RegionVisualCache.load_mesh(key, _cache_directory) == null, "missing mesh payload is a cache miss")
	_test_key_invalidation(context, key)
	_test_tree_data(key)
	_test_mesh_round_trip(key)
	_test_corrupt_fallback(key)
	_remove_test_directory()
	if _failures == 0:
		print("REGION VISUAL CACHE TEST: PASS")
	quit(0 if _failures == 0 else 1)


func _make_context() -> Dictionary:
	return {
		"geometry_revision": 3,
		"terrain_edits": {"version": 1, "edits": [[2, -4, 1.25]]},
		"seed": 731,
		"map_identity": "test_map",
		"bounds": Rect2(Vector2(-40.0, -20.0), Vector2(80.0, 40.0)),
		"resolution": Vector2i(8, 4),
		"artifact_settings": {"surface_detail": 2, "shoreline": true},
	}


func _test_key_invalidation(context: Dictionary, base_key: String) -> void:
	var reordered: Dictionary = {}
	var context_keys: Array = context.keys()
	context_keys.reverse()
	for context_key in context_keys:
		reordered[context_key] = context[context_key]
	_expect(
		RegionVisualCache.create_key("terrain_surface", reordered) == base_key,
		"dictionary insertion order does not alter the cache key"
	)
	_expect(
		RegionVisualCache.create_key("water_surface", context) != base_key,
		"artifact kind invalidates the cache key"
	)
	var changed_context: Dictionary = context.duplicate(true)
	changed_context["geometry_revision"] = 4
	_expect(RegionVisualCache.create_key("terrain_surface", changed_context) != base_key, "geometry revision invalidates the cache key")
	changed_context = context.duplicate(true)
	changed_context["terrain_edits"]["edits"].append([3, 1, -0.5])
	_expect(RegionVisualCache.create_key("terrain_surface", changed_context) != base_key, "terrain edits invalidate the cache key")
	changed_context = context.duplicate(true)
	changed_context["seed"] = 732
	_expect(RegionVisualCache.create_key("terrain_surface", changed_context) != base_key, "seed invalidates the cache key")
	changed_context = context.duplicate(true)
	changed_context["map_identity"] = "other_map"
	_expect(RegionVisualCache.create_key("terrain_surface", changed_context) != base_key, "map identity invalidates the cache key")
	changed_context = context.duplicate(true)
	changed_context["bounds"] = Rect2(Vector2(-39.0, -20.0), Vector2(80.0, 40.0))
	_expect(RegionVisualCache.create_key("terrain_surface", changed_context) != base_key, "world bounds invalidate the cache key")
	changed_context = context.duplicate(true)
	changed_context["resolution"] = Vector2i(16, 8)
	_expect(RegionVisualCache.create_key("terrain_surface", changed_context) != base_key, "sampling resolution invalidates the cache key")
	changed_context = context.duplicate(true)
	changed_context["artifact_settings"]["surface_detail"] = 3
	_expect(RegionVisualCache.create_key("terrain_surface", changed_context) != base_key, "artifact-specific settings invalidate the cache key")
	var incomplete_context: Dictionary = context.duplicate(true)
	incomplete_context.erase("terrain_edits")
	_expect(RegionVisualCache.create_key("terrain_surface", incomplete_context).is_empty(), "incomplete geometry context is rejected")


func _test_tree_data(key: String) -> void:
	var tree_data: Dictionary = {
		"positions": PackedVector3Array([Vector3(1.0, 2.0, 3.0), Vector3(-4.0, 0.5, 8.0)]),
		"scales": PackedFloat32Array([0.75, 1.25]),
		"indices": PackedInt32Array([0, 1]),
		"groups": [{"species": "oak", "count": 2}],
	}
	_expect(RegionVisualCache.save_data(key, tree_data, _cache_directory), "tree arrays and dictionaries save to the isolated cache")
	var restored: Variant = RegionVisualCache.load_data(key, _cache_directory)
	_expect(typeof(restored) == TYPE_DICTIONARY, "tree dictionary reads back")
	if typeof(restored) == TYPE_DICTIONARY:
		_expect(restored == tree_data, "tree dictionary values and packed array types round-trip exactly")
		_expect(
			typeof(restored["positions"]) == TYPE_PACKED_VECTOR3_ARRAY,
			"packed tree positions retain their typed array representation"
		)
	_expect(not RegionVisualCache.save_data(key, RefCounted.new(), _cache_directory), "Object-bearing tree data is rejected")


func _test_mesh_round_trip(key: String) -> void:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(2.0, 0.0, 0.0),
		Vector3(0.0, 0.0, 2.0),
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.UP,
		Vector3.UP,
		Vector3.UP,
	])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(1.0, 0.0),
		Vector2(0.0, 1.0),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var source_mesh: ArrayMesh = ArrayMesh.new()
	source_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var source_arrays: Array = source_mesh.surface_get_arrays(0)
	var material: StandardMaterial3D = StandardMaterial3D.new()
	source_mesh.surface_set_material(0, material)
	_expect(RegionVisualCache.save_mesh(key, source_mesh, _cache_directory), "mesh arrays save without serializing the material")
	var restored_mesh: ArrayMesh = RegionVisualCache.load_mesh(key, _cache_directory)
	_expect(restored_mesh != null, "saved mesh is reconstructed")
	if restored_mesh == null:
		return
	_expect(restored_mesh.get_surface_count() == 1, "surface count is preserved")
	if restored_mesh.get_surface_count() == 1:
		var restored_arrays: Array = restored_mesh.surface_get_arrays(0)
		_expect(restored_arrays == source_arrays, "typed packed mesh arrays round-trip exactly")
		_expect(restored_mesh.surface_get_material(0) == null, "materials remain assigned by the caller")


func _test_corrupt_fallback(key: String) -> void:
	var corrupt_key: String = RegionVisualCache.create_key("tree_data", _make_context())
	var tree_data: Dictionary = {"instances": PackedVector3Array([Vector3(5.0, 0.0, 9.0)])}
	_expect(RegionVisualCache.save_data(corrupt_key, tree_data, _cache_directory), "corruption fixture is written")
	var entry_path: String = RegionVisualCache.get_entry_path(corrupt_key, _cache_directory)
	var corrupt_file: FileAccess = FileAccess.open(entry_path, FileAccess.WRITE)
	_expect(corrupt_file != null, "corruption fixture can be opened in the isolated cache")
	if corrupt_file == null:
		return
	corrupt_file.store_buffer(PackedByteArray([0, 1, 2, 3, 4, 5]))
	corrupt_file.close()
	_expect(RegionVisualCache.load_data(corrupt_key, _cache_directory) == null, "corrupt entry falls back to a cache miss")
	_expect(RegionVisualCache.save_data(corrupt_key, tree_data, _cache_directory), "valid payload atomically replaces corrupt entry")
	_expect(RegionVisualCache.load_data(corrupt_key, _cache_directory) == tree_data, "rewritten entry reads successfully")
	_expect(not RegionVisualCache.save_data("../unsafe", tree_data, _cache_directory), "path-like cache keys are rejected")
	_expect(not key.is_empty(), "mesh cache key fixture remains valid")


func _remove_test_directory() -> void:
	var directory: DirAccess = DirAccess.open(_cache_directory)
	if directory != null:
		for file_name in directory.get_files():
			DirAccess.remove_absolute(_cache_directory.path_join(str(file_name)))
		DirAccess.remove_absolute(_cache_directory)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("RegionVisualCache: %s" % message)
