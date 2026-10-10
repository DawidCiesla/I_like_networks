extends SceneTree

const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const TerrainEditData = preload("res://scripts/world/terrain_edit_data.gd")
const TerrainRendererScript = preload("res://scripts/world/terrain_renderer.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const VisualCache = preload("res://scripts/world/region_visual_cache.gd")
const WaterRenderer = preload("res://scripts/world/water_surface_renderer.gd")

const TEST_SEED := 731942
const TEST_BOUNDS := Rect2(-1500.0, -1500.0, 3000.0, 3000.0)
const WATER_TEST_BOUNDS := Rect2(-12000.0, -12000.0, 24000.0, 24000.0)

var _failures := 0


class QuietTerrainRenderer:
	extends "res://scripts/world/terrain_renderer.gd"

	func _setup_natural_detail() -> void:
		pass


class DetachedWaterOwner:
	extends Node

	var startup_progress := 0.0
	var completed := false
	var result: ArrayMesh

	func start_build(seed: int, bounds: Rect2) -> void:
		result = await WaterSurfaceRenderer.build_mesh(
			seed,
			bounds,
			Vector2i(192, 192),
			get_tree(),
			self
		)
		completed = true


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var store: Node = root.get_node_or_null("GameStore")
	if store == null:
		_expect(false, "GameStore autoload is available")
		quit(1)
		return

	var previous_map := MapDefinition.active_definition()
	var previous_seed := int(store.get("city_seed"))
	var previous_suppress_persistence := bool(store.get("suppress_persistence"))
	var cache_directory := "/tmp/startup_cancellation_cache_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	store.set("suppress_persistence", true)
	store.set_process(false)
	store.set("city_seed", TEST_SEED)

	var edits_a := _make_edit_payload(TEST_SEED, Vector2(-900.0, -900.0))
	var map_a := _make_map(TEST_SEED, edits_a)
	MapDefinition.set_active(map_a)
	TerrainSurface.set_terrain_edit_payload(edits_a)
	map_a = MapDefinition.active_definition()
	var reference_builder := TerrainRendererScript.new()
	var reference_a: ArrayMesh = await reference_builder._build_mesh(TEST_BOUNDS, TEST_SEED)
	reference_builder.free()

	var renderer := QuietTerrainRenderer.new()
	renderer.cache_directory = cache_directory
	root.add_child(renderer)
	_expect(renderer._build_request == 1, "the initial progressive terrain request starts in _ready")
	_expect(renderer._active_builder != null, "the initial terrain request uses the progressive worker builder")

	var edits_b := _make_edit_payload(TEST_SEED, Vector2(900.0, 900.0))
	var map_b := _make_map(TEST_SEED, edits_b)
	MapDefinition.set_active(map_b)
	TerrainSurface.set_terrain_edit_payload(edits_b)
	map_b = MapDefinition.active_definition()
	var bounds := TerrainSurface.world_bounds()
	await renderer.rebuild(true)
	await process_frame

	var reference_latest: ArrayMesh = await renderer._build_mesh(bounds, TEST_SEED)
	_expect(_mesh_arrays_differ(reference_a, reference_latest), "the two terrain edit payloads produce different geometry")
	_expect(renderer.mesh is ArrayMesh, "the superseding terrain rebuild assigns an ArrayMesh")
	if renderer.mesh is ArrayMesh and reference_latest != null and reference_latest.get_surface_count() == 1:
		var actual_arrays: Array = (renderer.mesh as ArrayMesh).surface_get_arrays(0)
		var latest_arrays: Array = reference_latest.surface_get_arrays(0)
		_expect(actual_arrays == latest_arrays, "the final terrain arrays match the latest terrain edits")
	else:
		_expect(false, "the final terrain mesh has one complete surface")

	var old_key := _terrain_cache_key(map_a, TEST_SEED, bounds)
	var latest_key := _terrain_cache_key(map_b, TEST_SEED, bounds)
	var stale_cache: ArrayMesh = VisualCache.load_mesh(old_key, cache_directory)
	var latest_cache: ArrayMesh = VisualCache.load_mesh(latest_key, cache_directory)
	_expect(stale_cache == null, "the superseded terrain request does not cache its old geometry")
	_expect(latest_cache != null and latest_cache.get_surface_count() == 1, "the latest terrain geometry is cached with one surface")
	_expect(_cache_entry_count(cache_directory) == 1, "the isolated cache contains only the completed latest terrain entry")

	var water_owner := DetachedWaterOwner.new()
	root.add_child(water_owner)
	water_owner.start_build(TEST_SEED, WATER_TEST_BOUNDS)
	root.remove_child(water_owner)
	var water_start := Time.get_ticks_msec()
	while not water_owner.completed and Time.get_ticks_msec() - water_start < 15000:
		await process_frame
	_expect(water_owner.completed, "the detached water build returns after its next frame yield")
	_expect(water_owner.result == null, "a detached water progress owner cancels without returning a mesh")
	water_owner.free()

	root.remove_child(renderer)
	renderer.free()
	MapDefinition.set_active(previous_map)
	TerrainSurface.set_terrain_edit_payload(previous_map.get("terrain_edits", {}))
	store.set("city_seed", previous_seed)
	store.set("suppress_persistence", previous_suppress_persistence)

	if _failures == 0:
		print("STARTUP CANCELLATION TEST: PASS")
	else:
		push_error("STARTUP CANCELLATION TEST: FAIL (%d checks)" % _failures)
	quit(0 if _failures == 0 else 1)


func _make_map(seed: int, terrain_edits: Dictionary) -> Dictionary:
	var map := MapDefinition.create(MapDefinition.DEFAULT_MAP_ID, seed)
	map["bounds"] = {
		"x": TEST_BOUNDS.position.x,
		"y": TEST_BOUNDS.position.y,
		"width": TEST_BOUNDS.size.x,
		"height": TEST_BOUNDS.size.y,
	}
	map["terrain_edits"] = terrain_edits.duplicate(true)
	return map


func _make_edit_payload(seed: int, center: Vector2) -> Dictionary:
	var edit_data := TerrainEditData.new(seed, 58.0, TerrainEditData.SOURCE_TERRAIN_SURFACE)
	var result: Dictionary = edit_data.raise_brush(center, 420.0, 22.0)
	_expect(bool(result.get("ok", false)), "terrain edit fixture is valid")
	return edit_data.to_dict()


func _terrain_cache_key(map: Dictionary, seed: int, bounds: Rect2) -> String:
	return VisualCache.create_key("terrain", {
		"geometry_revision": 1,
		"seed": seed,
		"map_identity": {"id": map.get("id"), "generator_version": map.get("generator_version")},
		"terrain_edits": map.get("terrain_edits", {}),
		"bounds": bounds,
		"resolution": TerrainSurface.grid_steps(bounds),
	})


func _mesh_arrays_differ(first: ArrayMesh, second: ArrayMesh) -> bool:
	if first == null or second == null or first.get_surface_count() != 1 or second.get_surface_count() != 1:
		return false
	return first.surface_get_arrays(0) != second.surface_get_arrays(0)


func _cache_entry_count(directory: String) -> int:
	var access := DirAccess.open(directory)
	if access == null:
		return 0
	var count := 0
	for filename in access.get_files():
		if filename.ends_with(".cache"):
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("StartupCancellation: %s" % message)
