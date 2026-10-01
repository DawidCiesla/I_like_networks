extends Node3D

const Terrain = preload("res://scripts/world/terrain_model.gd")
const LIGHT_SCENE: PackedScene = preload("res://assets/kenney/roads/models/light-curved.glb")

const LIGHT_SPACING := 96.0
const LIGHT_SCALE := 14.0
const SIDEWALK_WIDTH := {
	"arterial": 42.0,
	"collector": 31.0,
}

var _lights: MultiMeshInstance3D
var _signature := ""

func _ready() -> void:
	GameStore.city_changed.connect(sync_lights)
	GameStore.state_changed.connect(sync_lights)
	sync_lights()

func sync_lights() -> void:
	var signature := _lighting_signature()
	if signature == _signature:
		return
	_signature = signature
	if _lights != null:
		_lights.queue_free()
		_lights = null

	var transforms := _collect_light_transforms()
	if transforms.is_empty():
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
	add_child(_lights)

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
					var ground := Terrain.height(GameStore.city_seed, position_2d.x, position_2d.y)
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
