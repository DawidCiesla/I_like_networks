extends Node3D

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const TREE_SCENES := {
	"small": preload("res://assets/kenney/suburban/models/tree-small.glb"),
	"large": preload("res://assets/kenney/suburban/models/tree-large.glb"),
}
const TREE_MODEL_SCALE := {
	"small": 20.0,
	"large": 28.0,
}

@export var spacing := 92.0
@export var margin := 560.0

var _tree_multimeshes: Dictionary = {}
var _tree_model_transforms: Dictionary = {}
var _tree_data: Array[Dictionary] = []
var _occupancy_signature := ""

func _ready() -> void:
	rebuild()
	GameStore.city_changed.connect(_sync_city_occupancy)
	GameStore.state_changed.connect(_sync_city_occupancy)
	GameStore.terrain_changed.connect(rebuild)

func rebuild() -> void:
	for child in get_children():
		child.queue_free()

	_tree_data.clear()
	_tree_multimeshes.clear()
	_tree_model_transforms.clear()
	var bounds := _world_bounds()
	var tree_spacing := maxf(spacing, minf(bounds.size.x, bounds.size.y) / 56.0)

	var x := bounds.position.x
	while x <= bounds.end.x:
		var z := bounds.position.y
		while z <= bounds.end.y:
			var jitter_x := (_pseudo(x, z, 1) - 0.5) * tree_spacing * 0.68
			var jitter_z := (_pseudo(x, z, 2) - 0.5) * tree_spacing * 0.68
			var px := x + jitter_x
			var pz := z + jitter_z

			if _should_place_tree(px, pz):
				var tree_type := "large" if _pseudo(px, pz, 6) > 0.56 else "small"
				_tree_data.append({
					"x": px,
					"z": pz,
					"type": tree_type,
					"scale": 0.75 + _pseudo(px, pz, 4) * 0.75,
					"rotation": _pseudo(px, pz, 5) * TAU,
					"ground": TerrainSurface.height(GameStore.city_seed, px, pz),
				})
			z += tree_spacing
		x += tree_spacing

	var counts := {"small": 0, "large": 0}
	for tree in _tree_data:
		var tree_type := str(tree["type"])
		tree["instance_index"] = int(counts[tree_type])
		counts[tree_type] = int(counts[tree_type]) + 1

	for tree_type in counts:
		var count := int(counts[tree_type])
		if count <= 0:
			continue

		var source_root: Node = TREE_SCENES[tree_type].instantiate()
		var mesh_data := _find_tree_mesh(source_root, Transform3D.IDENTITY)
		if mesh_data.is_empty():
			source_root.free()
			continue

		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = mesh_data["mesh"]
		multi.instance_count = count
		_tree_multimeshes[tree_type] = multi
		_tree_model_transforms[tree_type] = mesh_data["transform"]

		var tree_instances := MultiMeshInstance3D.new()
		tree_instances.name = "KenneyTrees%s" % tree_type.capitalize()
		tree_instances.multimesh = multi
		tree_instances.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(tree_instances)
		source_root.free()

	_occupancy_signature = ""
	_sync_city_occupancy(true)

func _sync_city_occupancy(force: bool = false) -> void:
	if _tree_multimeshes.is_empty():
		return

	var signature := _city_occupancy_signature()
	if not force and signature == _occupancy_signature:
		return
	_occupancy_signature = signature

	var active_roads: Array = []
	if not GameStore.city.is_empty():
		for road in GameStore.city.get("roads", []):
			if str(road.get("status", "")) in ["built", "constructing"]:
				active_roads.append(road)

	var parcel_lookup: Dictionary = {}
	if not GameStore.city.is_empty():
		for parcel in GameStore.city.get("parcels", []):
			parcel_lookup[str(parcel["id"])] = parcel

	var occupied_parcels: Array = []
	if not GameStore.city.is_empty():
		for building in GameStore.city.get("buildings", []):
			var parcel: Dictionary = parcel_lookup.get(str(building.get("parcelId", "")), {})
			if not parcel.is_empty():
				occupied_parcels.append(parcel)

	for index in range(_tree_data.size()):
		var tree: Dictionary = _tree_data[index]
		var point := Vector2(float(tree["x"]), float(tree["z"]))
		var blocked := false

		for road in active_roads:
			if _point_near_road(point, road, 13.0):
				blocked = true
				break

		if not blocked:
			for parcel in occupied_parcels:
				if _point_in_parcel(point, parcel, 8.0):
					blocked = true
					break

		var scale := 0.0001 if blocked else float(tree["scale"])
		var tree_type := str(tree["type"])
		var multimesh: MultiMesh = _tree_multimeshes.get(tree_type)
		if multimesh == null:
			continue
		var asset_scale := scale * float(TREE_MODEL_SCALE[tree_type])
		var basis := Basis(Vector3.UP, float(tree["rotation"])).scaled(Vector3.ONE * asset_scale)
		var transform := Transform3D(
			basis,
			Vector3(float(tree["x"]), float(tree["ground"]), float(tree["z"]))
		)
		multimesh.set_instance_transform(
			int(tree["instance_index"]),
			transform * _tree_model_transforms[tree_type]
		)

func _find_tree_mesh(node: Node, parent_transform: Transform3D) -> Dictionary:
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
		var result := _find_tree_mesh(child, transform)
		if not result.is_empty():
			return result
	return {}

func _city_occupancy_signature() -> String:
	if GameStore.city.is_empty():
		return "empty"

	var road_parts: Array[String] = []
	for road in GameStore.city.get("roads", []):
		if str(road.get("status", "")) in ["built", "constructing"]:
			road_parts.append(str(road["id"]))
	road_parts.sort()

	var building_parts: Array[String] = []
	for building in GameStore.city.get("buildings", []):
		building_parts.append(str(building["parcelId"]))
	building_parts.sort()

	return "%s::%s" % ["|".join(road_parts), "|".join(building_parts)]

func _point_near_road(point: Vector2, road: Dictionary, extra: float) -> bool:
	var width := 15.0
	match str(road.get("class", "local")):
		"arterial":
			width = 31.0
		"collector":
			width = 21.0
		"service":
			width = 12.0

	var points: Array = road.get("points", [])
	for index in range(points.size() - 1):
		var a_raw: Dictionary = points[index]
		var b_raw: Dictionary = points[index + 1]
		var a := Vector2(float(a_raw["x"]), float(a_raw["y"]))
		var b := Vector2(float(b_raw["x"]), float(b_raw["y"]))
		if _distance_to_segment(point, a, b) < width * 0.5 + extra:
			return true
	return false

func _point_in_parcel(point: Vector2, parcel: Dictionary, padding: float) -> bool:
	var half_w := float(parcel.get("w", 0.0)) * 0.5 + padding
	var half_h := float(parcel.get("h", 0.0)) * 0.5 + padding
	return (
		abs(point.x - float(parcel["x"])) <= half_w
		and abs(point.y - float(parcel["y"])) <= half_h
	)

func _should_place_tree(x: float, z: float) -> bool:
	var forest := Terrain.forest_potential(GameStore.city_seed, x, z)
	if forest < 0.59:
		return false
	# A low-frequency mask gathers instances into groves and leaves clearings.
	# Keep a separate small-scale rejection so individual trees do not form rows.
	if _grove_noise(x, z) < 0.45:
		return false
	if _pseudo(x, z, 3) < 0.09:
		return false

	for line_key in ["line1", "line2", "line3", "line4"]:
		for segment_index in range(Layout.BASE_SEGMENTS[line_key].size()):
			var points := Layout.segment_points(line_key, segment_index)
			for index in range(points.size() - 1):
				if _distance_to_segment(Vector2(x, z), points[index], points[index + 1]) < 30.0:
					return false

	return true

func _grove_noise(x: float, z: float) -> float:
	const GROVE_SCALE := 430.0
	var grid_x := floori(x / GROVE_SCALE)
	var grid_z := floori(z / GROVE_SCALE)
	var fraction_x := _smoothstep(x / GROVE_SCALE - float(grid_x))
	var fraction_z := _smoothstep(z / GROVE_SCALE - float(grid_z))
	var top := lerpf(
		_pseudo(float(grid_x), float(grid_z), 11),
		_pseudo(float(grid_x + 1), float(grid_z), 11),
		fraction_x
	)
	var bottom := lerpf(
		_pseudo(float(grid_x), float(grid_z + 1), 11),
		_pseudo(float(grid_x + 1), float(grid_z + 1), 11),
		fraction_x
	)
	return lerpf(top, bottom, fraction_z)

func _smoothstep(value: float) -> float:
	var clamped := clampf(value, 0.0, 1.0)
	return clamped * clamped * (3.0 - 2.0 * clamped)

func _distance_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq <= 0.000001:
		return point.distance_to(a)
	var t: float = clampf((point - a).dot(ab) / length_sq, 0.0, 1.0)
	return point.distance_to(a + ab * t)

func _pseudo(x: float, z: float, channel: int) -> float:
	var value := sin(
		x * 12.9898
		+ z * 78.233
		+ float(GameStore.city_seed) * 0.00317
		+ float(channel) * 19.19
	) * 43758.5453
	return value - floor(value)

func _world_bounds() -> Rect2:
	var map_definition := MapDefinition.active_definition()
	if str(map_definition.get("id", MapDefinition.LEGACY_CITY_MAP_ID)) != MapDefinition.LEGACY_CITY_MAP_ID:
		return TerrainSurface.world_bounds()
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for line_key in ["line1", "line2", "line3", "line4"]:
		for point in Layout.line_stops(line_key):
			min_x = minf(min_x, point.x)
			max_x = maxf(max_x, point.x)
			min_z = minf(min_z, point.y)
			max_z = maxf(max_z, point.y)
	return Rect2(
		Vector2(min_x - margin, min_z - margin),
		Vector2(max_x - min_x + margin * 2.0, max_z - min_z + margin * 2.0)
	)
