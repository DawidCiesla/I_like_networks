extends SceneTree

const CityRuntime = preload("res://scripts/city/city_runtime.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const WaterRenderer = preload("res://scripts/world/water_surface_renderer.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var store := root.get_node("GameStore")
	store.suppress_persistence = true
	var payload: Dictionary = store._current_save_payload().duplicate(true)
	var map := MapDefinition.create(MapDefinition.LEGACY_CITY_MAP_ID, 42)
	map["bounds"] = {"x": -100.0, "y": -100.0, "width": 500.0, "height": 500.0}
	payload["city_seed"] = 42
	payload["world_map"] = map
	payload["city"] = CityRuntime.create_initial_city(42, MapDefinition.LEGACY_CITY_MAP_ID)
	store._apply_payload(payload)
	_expect(TerrainSurface.world_bounds().size == Vector2(500.0, 500.0), "map changes invalidate cached terrain bounds")
	var scene: PackedScene = load("res://scenes/main.tscn")
	var game := scene.instantiate()
	for renderer_name in ["Terrain", "Water", "Vegetation"]:
		game.get_node(renderer_name).cache_directory = "/tmp/startup_rendering_cache_%d" % OS.get_process_id()
	root.add_child(game)
	_expect(not store.is_processing(), "simulation waits for visual initialization")
	var frames := 0
	var start := Time.get_ticks_msec()
	while bool(game.get("startup_loading")) and Time.get_ticks_msec() - start < 30000:
		await process_frame
		frames += 1
	_expect(frames > 0, "render initialization yields to the frame loop")
	_expect(not bool(game.get("startup_loading")), "gameplay starts after visual initialization")
	_expect(store.is_processing(), "simulation resumes after loading")
	_expect(game.get_node("Terrain").mesh != null, "terrain mesh finishes building")
	for node_name in ["Terrain", "Water", "Vegetation"]:
		_expect(not bool(game.get_node(node_name).get("startup_loading")), node_name + " finishes loading")
	store.set_process(false)
	var terrain := game.get_node("Terrain")
	var reference_terrain: ArrayMesh = await terrain.call("_build_mesh", TerrainSurface.world_bounds(), store.city_seed)
	_expect(terrain.mesh.surface_get_arrays(0) == reference_terrain.surface_get_arrays(0), "progressive terrain preserves mesh geometry and material data")
	var reference_water: ArrayMesh = await WaterRenderer.build_mesh(store.city_seed, TerrainSurface.world_bounds())
	var water_mesh: ArrayMesh = game.get_node("Water").mesh
	_expect(water_mesh.get_surface_count() == reference_water.get_surface_count(), "progressive water preserves mesh surface count")
	if water_mesh.get_surface_count() > 0:
		_expect(water_mesh.surface_get_arrays(0) == reference_water.surface_get_arrays(0), "progressive water preserves mesh geometry and colors")
	for node_name in ["Terrain", "Water", "Vegetation"]:
		if node_name == "Water":
			await game.get_node(node_name).rebuild(store.city_seed, TerrainSurface.world_bounds())
		else:
			await game.get_node(node_name).rebuild()
		_expect(game.get_node(node_name).cache_hit, node_name + " reuses persisted geometry")
	game.queue_free()
	await process_frame
	if _failures == 0:
		print("STARTUP RENDERING TEST: PASS (%d frames during loading)" % frames)
	quit(0 if _failures == 0 else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error(message)
