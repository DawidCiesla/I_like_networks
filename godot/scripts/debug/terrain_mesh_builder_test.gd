extends SceneTree

const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const TerrainEditData = preload("res://scripts/world/terrain_edit_data.gd")
const TerrainRenderer = preload("res://scripts/world/terrain_renderer.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const TerrainMeshBuilder = preload("res://scripts/world/terrain_mesh_builder.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var previous_map := MapDefinition.active_definition()
	var seed := 284731
	var map := MapDefinition.create(MapDefinition.DEFAULT_MAP_ID, seed)
	map["bounds"] = {"x": -250.0, "y": -250.0, "width": 500.0, "height": 500.0}
	MapDefinition.set_active(map)
	var bounds := TerrainSurface.world_bounds()
	var steps := TerrainSurface.grid_steps(bounds)
	var renderer := TerrainRenderer.new()

	TerrainSurface.set_terrain_edit_payload({})
	var reference_without_edits: ArrayMesh = await renderer._build_mesh(bounds, seed)
	var builder_without_edits := TerrainMeshBuilder.new()
	var built_without_edits: ArrayMesh = await builder_without_edits.build(
		seed, bounds, steps, true, {}, null
	)
	_expect_worker_count(builder_without_edits.worker_count, "unmodified terrain")
	_expect_mesh_arrays_equal(built_without_edits, reference_without_edits, "unmodified terrain")

	var edit_data := TerrainEditData.new(seed, 58.0, TerrainEditData.SOURCE_TERRAIN_SURFACE)
	var edit_result := edit_data.raise_brush(Vector2.ZERO, 116.0, 18.0)
	_expect(bool(edit_result.get("ok", false)), "terrain edit fixture is valid")
	var edit_payload := edit_data.to_dict()
	map["terrain_edits"] = edit_payload
	MapDefinition.set_active(map)
	TerrainSurface.set_terrain_edit_payload(edit_payload)
	var reference_with_edits: ArrayMesh = await renderer._build_mesh(bounds, seed)
	var builder_with_edits := TerrainMeshBuilder.new()
	var built_with_edits: ArrayMesh = await builder_with_edits.build(
		seed, bounds, steps, true, edit_payload, null
	)
	_expect_worker_count(builder_with_edits.worker_count, "edited terrain")
	_expect_mesh_arrays_equal(built_with_edits, reference_with_edits, "edited terrain")
	_expect_mesh_vertices_differ(
		built_without_edits,
		built_with_edits,
		"terrain edits affect generated worker mesh vertices"
	)

	renderer.free()
	MapDefinition.set_active(previous_map)
	TerrainSurface.set_terrain_edit_payload(previous_map.get("terrain_edits", {}))
	if _failures == 0:
		print("TERRAIN MESH BUILDER TEST: PASS")
	else:
		push_error("TERRAIN MESH BUILDER TEST: FAIL (%d checks)" % _failures)
	quit(0 if _failures == 0 else 1)


func _expect_worker_count(worker_count: int, message: String) -> void:
	_expect(worker_count >= 1 and worker_count <= 4, "%s uses 1 to 4 workers (got %d)" % [message, worker_count])


func _expect_mesh_arrays_equal(actual: ArrayMesh, expected: ArrayMesh, message: String) -> void:
	_expect(actual != null and actual.get_surface_count() == 1, "%s worker mesh has one surface" % message)
	_expect(expected != null and expected.get_surface_count() == 1, "%s reference mesh has one surface" % message)
	if actual == null or expected == null or actual.get_surface_count() != 1 or expected.get_surface_count() != 1:
		return
	var actual_arrays: Array = actual.surface_get_arrays(0)
	var expected_arrays: Array = expected.surface_get_arrays(0)
	_expect(actual_arrays.size() == Mesh.ARRAY_MAX, "%s worker arrays have the expected layout" % message)
	_expect(actual_arrays == expected_arrays, "%s packed mesh arrays match renderer output" % message)


func _expect_mesh_vertices_differ(before: ArrayMesh, after: ArrayMesh, message: String) -> void:
	if before.get_surface_count() != 1 or after.get_surface_count() != 1:
		_expect(false, message)
		return
	var before_vertices: PackedVector3Array = before.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var after_vertices: PackedVector3Array = after.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_expect(before_vertices.size() == after_vertices.size(), "%s keeps the same vertex count" % message)
	var changed := false
	for index in range(mini(before_vertices.size(), after_vertices.size())):
		if not is_equal_approx(before_vertices[index].y, after_vertices[index].y):
			changed = true
			break
	_expect(changed, message)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("TerrainMeshBuilder: %s" % message)
