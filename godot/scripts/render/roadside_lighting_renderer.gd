extends Node3D

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const LIGHT_SCENE: PackedScene = preload("res://assets/kenney/roads/models/light-curved.glb")

const LIGHT_SPACING := 96.0
const LIGHT_SCALE := 14.0
const SIDEWALK_WIDTH := {
	"arterial": 42.0,
	"collector": 31.0,
}
const PHYSICAL_LIGHT_COUNT := 24
const PHYSICAL_LIGHT_SEARCH_RADIUS := 920.0
const PHYSICAL_LIGHT_HEIGHT := 7.4
const PHYSICAL_LIGHT_RANGE := 34.0
const PHYSICAL_LIGHT_ENERGY := 1.45
const PHYSICAL_LIGHT_COLOR := Color(1.0, 0.77, 0.49)

var _lights: MultiMeshInstance3D
var _physical_lights_root: Node3D
var _light_positions: Array[Vector3] = []
var _signature := ""
var _physical_signature := ""
var _physical_elapsed := 0.0


func _ready() -> void:
	_physical_lights_root = Node3D.new()
	_physical_lights_root.name = "PhysicalStreetLights"
	add_child(_physical_lights_root)
	GameStore.city_changed.connect(sync_lights)
	GameStore.state_changed.connect(sync_lights)
	GameStore.terrain_changed.connect(_on_terrain_changed)
	sync_lights()


func _process(delta: float) -> void:
	_physical_elapsed += delta
	if _physical_elapsed < 0.55:
		return
	_physical_elapsed = 0.0
	_sync_physical_lights()


func _on_terrain_changed() -> void:
	_signature = ""
	_physical_signature = ""
	sync_lights()


func sync_lights() -> void:
	var signature := _lighting_signature()
	if signature == _signature:
		return
	_signature = signature
	_physical_signature = ""
	if _lights != null:
		_lights.queue_free()
		_lights = null

	var transforms := _collect_light_transforms()
	_light_positions.clear()
	for transform_value in transforms:
		var transform: Transform3D = transform_value
		_light_positions.append(transform.origin + Vector3.UP * PHYSICAL_LIGHT_HEIGHT)
	if transforms.is_empty():
		_clear_physical_lights()
		return

	var source_root := LIGHT_SCENE.instantiate()
	var mesh_data := _find_mesh(source_root, Transform3D.IDENTITY)
	if mesh_data.is_empty():
		source_root.free()
		return

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh_data["mesh"]
	multimesh.instance_count = transforms.size()
	var mesh_transform: Transform3D = mesh_data["transform"]
	for index in range(transforms.size()):
		multimesh.set_instance_transform(index, transforms[index] * mesh_transform)
	source_root.free()

	_lights = MultiMeshInstance3D.new()
	_lights.name = "KenneyRoadsideLights"
	_lights.multimesh = multimesh
	_lights.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_lights.visibility_range_end = 5200.0
	_lights.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_lights)
	_sync_physical_lights()


func _sync_physical_lights() -> void:
	if _physical_lights_root == null:
		return
	var hour := fposmod(8.0 + maxf(0.0, float(GameStore.city.get("time_seconds", 0.0))) / 3600.0, 24.0)
	var night_strength := _night_strength(hour)
	var camera := get_viewport().get_camera_3d()
	if camera == null or night_strength <= 0.001 or _light_positions.is_empty():
		if not _physical_lights_root.get_children().is_empty():
			_clear_physical_lights()
		_physical_signature = "off"
		return

	var camera_position := camera.global_position
	var candidates: Array[Dictionary] = []
	for index in range(_light_positions.size()):
		var position := _light_positions[index]
		var planar_distance := Vector2(position.x, position.z).distance_to(Vector2(camera_position.x, camera_position.z))
		if planar_distance > PHYSICAL_LIGHT_SEARCH_RADIUS:
			continue
		candidates.append({
			"index": index,
			"distance": planar_distance,
			"position": position,
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance"]) < float(b["distance"]))
	if candidates.size() > PHYSICAL_LIGHT_COUNT:
		candidates.resize(PHYSICAL_LIGHT_COUNT)

	var signature_parts: Array[String] = ["%.2f" % night_strength]
	for candidate in candidates:
		signature_parts.append(str(candidate["index"]))
	var signature := ":".join(signature_parts)
	if signature == _physical_signature:
		return
	_physical_signature = signature
	_clear_physical_lights()

	for candidate in candidates:
		var light := OmniLight3D.new()
		light.name = "StreetGlow_%d" % int(candidate["index"])
		light.position = candidate["position"]
		light.light_color = PHYSICAL_LIGHT_COLOR
		light.light_energy = PHYSICAL_LIGHT_ENERGY * night_strength
		light.omni_range = PHYSICAL_LIGHT_RANGE
		light.light_specular = 0.32
		light.light_volumetric_fog_energy = 0.38 * night_strength
		light.shadow_enabled = false
		_physical_lights_root.add_child(light)


func _clear_physical_lights() -> void:
	if _physical_lights_root == null:
		return
	for child in _physical_lights_root.get_children():
		child.queue_free()


static func _night_strength(hour: float) -> float:
	if hour >= 20.0 or hour < 5.0:
		return 1.0
	if hour >= 18.0:
		return smoothstep(18.0, 20.0, hour)
	if hour < 7.0:
		return 1.0 - smoothstep(5.0, 7.0, hour)
	return 0.0


func _lighting_signature() -> String:
	if GameStore.city.is_empty():
		return "empty"

	var roads: Array[String] = []
	for road in GameStore.city.get("roads", []):
		var road_class := str(road.get("class", "local"))
		if road_class not in ["arterial", "collector"]:
			continue
		var status := str(road.get("status", ""))
		if status == "built":
			roads.append("%s:%s" % [str(road.get("id", "")), road_class])
	roads.sort()
	return "%d|%s" % [GameStore.city_seed, "|".join(roads)]


func _collect_light_transforms() -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	if GameStore.city.is_empty():
		return result

	var occupied_cells: Dictionary = {}
	for road in GameStore.city.get("roads", []):
		var road_class := str(road.get("class", "local"))
		if road_class not in ["arterial", "collector"] or str(road.get("status", "")) != "built":
			continue

		var points: Array[Vector2] = []
		for raw_point in road.get("points", []):
			points.append(Vector2(float(raw_point.get("x", 0.0)), float(raw_point.get("y", 0.0))))
		if points.size() < 2:
			continue

		var lateral_offset := maxf(5.0, float(SIDEWALK_WIDTH.get(road_class, 23.0)) * 0.5 - 1.8)
		var distance_to_next_light := LIGHT_SPACING * 0.5
		var travelled := 0.0
		var light_index := 0
		for segment_index in range(points.size() - 1):
			var start := points[segment_index]
			var finish := points[segment_index + 1]
			var segment := finish - start
			var segment_length := segment.length()
			if segment_length <= 0.001:
				continue

			while distance_to_next_light < travelled + segment_length:
				var along_segment := distance_to_next_light - travelled
				var centerline_position := start + segment * (along_segment / segment_length)
				var direction := segment / segment_length
				var normal := Vector2(-direction.y, direction.x)
				var side := 1.0 if light_index % 2 == 0 else -1.0
				var position_2d := centerline_position + normal * side * lateral_offset
				var cell := Vector2i(roundi(position_2d.x / 12.0), roundi(position_2d.y / 12.0))
				if not occupied_cells.has(cell):
					occupied_cells[cell] = true
					var toward_road := -normal * side
					var yaw := atan2(-toward_road.x, -toward_road.y)
					var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * LIGHT_SCALE)
					var ground := TerrainSurface.height(GameStore.city_seed, position_2d.x, position_2d.y)
					result.append(Transform3D(
						basis,
						Vector3(position_2d.x, ground, position_2d.y)
					))
				light_index += 1
				distance_to_next_light += LIGHT_SPACING
			travelled += segment_length

	return result


func _find_mesh(node: Node, parent_transform: Transform3D) -> Dictionary:
	var transform := parent_transform
	if node is Node3D:
		transform = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			return {
				"mesh": mesh_instance.mesh,
				"transform": transform,
			}
	for child in node.get_children():
		var result := _find_mesh(child, transform)
		if not result.is_empty():
			return result
	return {}
