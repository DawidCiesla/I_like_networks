extends SceneTree

const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const BridgeDetailRenderer = preload("res://scripts/render/bridge_detail_renderer.gd")
const BuildingHlodRenderer = preload("res://scripts/render/building_hlod_renderer.gd")
const BuildingWindowRenderer = preload("res://scripts/render/building_window_renderer.gd")
const CloudLayerRenderer = preload("res://scripts/render/cloud_layer_renderer.gd")
const RegionalRoadsideRenderer = preload("res://scripts/render/regional_roadside_renderer.gd")
const RoadsidePropsRenderer = preload("res://scripts/render/roadside_props_renderer.gd")
const ForestHlodRenderer = preload("res://scripts/world/forest_hlod_renderer.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var previous_map := MapDefinition.active_definition()
	var previous_suppress := bool(GameStore.suppress_persistence)
	GameStore.suppress_persistence = true
	var seed := 731945
	MapDefinition.set_active(MapDefinition.create(MapDefinition.DEFAULT_MAP_ID, seed))
	GameStore.city_seed = seed
	GameStore.reset_state(false)

	var root_3d := Node3D.new()
	root_3d.name = "RegionalVisualRendererTestRoot"
	root.add_child(root_3d)

	var clouds := CloudLayerRenderer.new()
	root_3d.add_child(clouds)
	var building_hlod := BuildingHlodRenderer.new()
	root_3d.add_child(building_hlod)
	var building_windows := BuildingWindowRenderer.new()
	root_3d.add_child(building_windows)
	var shoulders := RegionalRoadsideRenderer.new()
	root_3d.add_child(shoulders)
	var roadside := RoadsidePropsRenderer.new()
	root_3d.add_child(roadside)
	var bridges := BridgeDetailRenderer.new()
	root_3d.add_child(bridges)
	var forest_hlod := ForestHlodRenderer.new()
	root_3d.add_child(forest_hlod)

	await process_frame
	await process_frame

	var low_clouds := clouds.get_node_or_null("CloudLayerLow") as MeshInstance3D
	var high_clouds := clouds.get_node_or_null("CloudLayerHigh") as MeshInstance3D
	_expect(low_clouds != null and high_clouds != null, "cloud renderer creates two animated atmosphere layers")
	if low_clouds != null:
		_expect(low_clouds.mesh != null and low_clouds.mesh.material is ShaderMaterial, "low cloud layer owns its procedural shader material")

	var building_hlod_instance := building_hlod.get_node_or_null("RegionalBuildingHLOD") as MultiMeshInstance3D
	_expect(building_hlod_instance != null, "building HLOD creates its MultiMesh instance")
	if building_hlod_instance != null:
		_expect(building_hlod_instance.multimesh != null, "building HLOD owns a MultiMesh")
		if building_hlod_instance.multimesh != null:
			_expect(building_hlod_instance.multimesh.instance_count > 0, "regional starter produces distant building HLOD instances")

	var windows_instance := building_windows.get_node_or_null("BuildingWindows") as MultiMeshInstance3D
	_expect(windows_instance != null, "building window renderer creates its MultiMesh instance")
	if windows_instance != null and windows_instance.multimesh != null:
		_expect(windows_instance.multimesh.instance_count > 0, "regional buildings produce procedural facade windows")

	var delineators := roadside.get_node_or_null("RoadsideDelineators") as MultiMeshInstance3D
	_expect(delineators != null, "roadside props create delineator renderer")
	if delineators != null and delineators.multimesh != null:
		_expect(delineators.multimesh.instance_count > 0, "regional roads produce delineator posts")

	_expect(shoulders.get_child_count() > 0, "regional roads produce blended shoulder meshes")

	var bridge_count := _bridge_crossing_count(GameStore.city)
	var girders := bridges.get_node_or_null("BridgeGirders") as MultiMeshInstance3D
	var abutments := bridges.get_node_or_null("BridgeAbutments") as MultiMeshInstance3D
	_expect(girders != null and abutments != null, "bridge detail renderer creates structural MultiMeshes")
	if bridge_count > 0:
		_expect(girders != null and girders.multimesh != null and girders.multimesh.instance_count > 0, "regional bridge crossings produce side girders")
		_expect(abutments != null and abutments.multimesh != null and abutments.multimesh.instance_count > 0, "regional bridge crossings produce abutments")

	var forest_instance := forest_hlod.get_node_or_null("ForestHLOD") as MultiMeshInstance3D
	_expect(forest_instance != null, "forest HLOD creates its MultiMesh instance")
	if forest_instance != null and forest_instance.multimesh != null:
		_expect(forest_instance.multimesh.instance_count > 0, "regional landscape produces distant forest HLOD masses")

	root_3d.queue_free()
	await process_frame
	MapDefinition.set_active(previous_map)
	GameStore.suppress_persistence = previous_suppress

	if _failures == 0:
		print("REGIONAL VISUAL RENDERERS TEST: PASS")
		quit(0)
		return
	push_error("REGIONAL VISUAL RENDERERS TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _bridge_crossing_count(city: Dictionary) -> int:
	var count := 0
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("status", "")) != "built":
			continue
		count += (road.get("bridgeCrossings", []) as Array).size()
	return count


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("RegionalVisualRenderers: %s" % message)
