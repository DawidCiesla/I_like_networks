extends Node3D

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const VisualCache = preload("res://scripts/world/region_visual_cache.gd")
const RoadSpatialIndex = preload("res://scripts/world/detail_road_spatial_index.gd")
const GEOMETRY_REVISION := 1
const TREE_SCENES := {
	"small": preload("res://assets/kenney/suburban/models/tree-small.glb"),
	"large": preload("res://assets/kenney/suburban/models/tree-large.glb"),
}
const TREE_MODEL_SCALE := {
	"small": 20.0,
	"large": 28.0,
}
const REGIONAL_TREE_GRID_DIVISOR := 228.0
const REGIONAL_MIN_SPACING := 82.0
const REGIONAL_TILE_SIZE := 900.0
const REGIONAL_VISIBILITY_END := 2200.0
const PARCEL_INDEX_CELL_SIZE := 220.0

@export var spacing := 78.0
@export var margin := 560.0

var _tree_multimeshes: Dictionary = {}
var _tree_model_transforms: Dictionary = {}
var _tree_batch_origins: Dictionary = {}
var _tree_data: Array[Dictionary] = []
var _occupancy_signature := ""
var startup_loading := true
var startup_progress := 0.0
var cache_directory := ""
var cache_hit := false
var build_duration_ms := 0
var _build_request := 0


func _ready() -> void:
	await rebuild(true)
	GameStore.city_changed.connect(_sync_city_occupancy)
	GameStore.state_changed.connect(_sync_city_occupancy)
	GameStore.terrain_changed.connect(rebuild)


func rebuild(progressive: bool = false) -> void:
	_build_request += 1
	var request := _build_request
	var started := Time.get_ticks_msec()
	for child in get_children():
		child.queue_free()
	_tree_data.clear()
	_tree_multimeshes.clear()
	_tree_model_transforms.clear()
	_tree_batch_origins.clear()
	var bounds := _world_bounds()
	var regional := _is_regional_map()
	var tree_spacing := (
		maxf(REGIONAL_MIN_SPACING, minf(bounds.size.x, bounds.size.y) / REGIONAL_TREE_GRID_DIVISOR)
		if regional
		else maxf(spacing, minf(bounds.size.x, bounds.size.y) / 112.0)
	)
	var map := MapDefinition.active_definition()
	var key := VisualCache.create_key("vegetation", {
		"geometry_revision": GEOMETRY_REVISION,
		"seed": GameStore.city_seed,
		"map_identity": {"id": map.get("id"), "generator_version": map.get("generator_version")},
		"terrain_edits": map.get("terrain_edits", {}),
		"bounds": bounds, "resolution": Vector2(tree_spacing, tree_spacing),
	})
	var cached: Variant = VisualCache.load_data(key, cache_directory)
	cache_hit = _valid_cached_trees(cached)
	if cache_hit:
		_tree_data.assign(cached)
	else:
		var x := bounds.position.x
		var slice_start := Time.get_ticks_msec()
		while x <= bounds.end.x:
			var z := bounds.position.y
			while z <= bounds.end.y:
				var jitter_x := (_pseudo(x, z, 1) - 0.5) * tree_spacing * 0.88
				var jitter_z := (_pseudo(x, z, 2) - 0.5) * tree_spacing * 0.88
				var px := x + jitter_x
				var pz := z + jitter_z
				var forest := _forest_potential(px, pz)
				if _should_place_tree(px, pz, forest):
					var large_threshold := lerpf(0.68, 0.39, clampf((forest - 0.46) / 0.46, 0.0, 1.0))
					var tree_type := "large" if _pseudo(px, pz, 6) > large_threshold else "small"
					_tree_data.append({
						"x": px,
						"z": pz,
						"type": tree_type,
						"scale": (0.62 + _pseudo(px, pz, 4) * 0.94) if regional else (0.72 + _pseudo(px, pz, 4) * 0.68),
						"rotation": _pseudo(px, pz, 5) * TAU,
						"ground": TerrainSurface.height(GameStore.city_seed, px, pz),
					})
				z += tree_spacing
				if progressive and Time.get_ticks_msec() - slice_start >= 8:
					startup_progress = clampf((x - bounds.position.x) / bounds.size.x, 0.0, 1.0) * 0.86
					await get_tree().process_frame
					if request != _build_request or not is_inside_tree():
						return
					slice_start = Time.get_ticks_msec()
			x += tree_spacing
		VisualCache.save_data(key, _tree_data, cache_directory)

	_build_tree_batches(regional)
	if request != _build_request or not is_inside_tree():
		return
	_occupancy_signature = ""
	_sync_city_occupancy(true)
	startup_progress = 1.0
	startup_loading = false
	build_duration_ms = Time.get_ticks_msec() - started
	print("[RegionLoad] vegetation cache=%s batches=%d elapsed_ms=%d" % [
		"hit" if cache_hit else "miss", _tree_multimeshes.size(), build_duration_ms
	])


func _build_tree_batches(regional: bool) -> void:
	var mesh_data_by_type: Dictionary = {}
	for tree_type in TREE_SCENES.keys():
		var source_root: Node = TREE_SCENES[tree_type].instantiate()
		var mesh_data := _find_tree_mesh(source_root, Transform3D.IDENTITY)
		source_root.free()
		if not mesh_data.is_empty():
			mesh_data_by_type[tree_type] = mesh_data
			_tree_model_transforms[tree_type] = mesh_data["transform"]

	var groups: Dictionary = {}
	for tree_index in range(_tree_data.size()):
		var tree: Dictionary = _tree_data[tree_index]
		var tree_type := str(tree.get("type", "small"))
		if not mesh_data_by_type.has(tree_type):
			continue
		var tile := Vector2i.ZERO
		if regional:
			tile = Vector2i(
				floori(float(tree["x"]) / REGIONAL_TILE_SIZE),
				floori(float(tree["z"]) / REGIONAL_TILE_SIZE)
			)
		var batch_key := "%d:%d:%s" % [tile.x, tile.y, tree_type]
		var group: Dictionary = groups.get(batch_key, {
			"type": tree_type,
			"tile": tile,
			"indices": [],
		})
		var indices: Array = group["indices"]
		tree["batch_key"] = batch_key
		tree["instance_index"] = indices.size()
		indices.append(tree_index)
		group["indices"] = indices
		groups[batch_key] = group

	var group_keys: Array = groups.keys()
	group_keys.sort()
	for batch_key_value in group_keys:
		var batch_key := str(batch_key_value)
		var group: Dictionary = groups[batch_key]
		var tree_type := str(group["type"])
		var tile: Vector2i = group["tile"]
		var indices: Array = group["indices"]
		if indices.is_empty():
			continue
		var origin := Vector2.ZERO
		if regional:
			origin = Vector2(float(tile.x) * REGIONAL_TILE_SIZE, float(tile.y) * REGIONAL_TILE_SIZE)
		_tree_batch_origins[batch_key] = origin
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = (mesh_data_by_type[tree_type] as Dictionary)["mesh"]
		multi.instance_count = indices.size()
		_tree_multimeshes[batch_key] = multi
		var tree_instances := MultiMeshInstance3D.new()
		tree_instances.name = "TreeTile_%s" % batch_key.replace(":", "_")
		tree_instances.position = Vector3(origin.x, 0.0, origin.y)
		tree_instances.multimesh = multi
		tree_instances.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if regional else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		)
		tree_instances.visibility_range_end = REGIONAL_VISIBILITY_END if regional else 5200.0
		tree_instances.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(tree_instances)

		var model_transform: Transform3D = _tree_model_transforms[tree_type]
		for tree_index_value in indices:
			var tree: Dictionary = _tree_data[int(tree_index_value)]
			var asset_scale := float(tree["scale"]) * float(TREE_MODEL_SCALE[tree_type])
			var basis := Basis(Vector3.UP, float(tree["rotation"])).scaled(Vector3.ONE * asset_scale)
			var local_transform := Transform3D(
				basis,
				Vector3(float(tree["x"]) - origin.x, float(tree["ground"]), float(tree["z"]) - origin.y)
			)
			multi.set_instance_transform(int(tree["instance_index"]), local_transform * model_transform)


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
	var road_index := RoadSpatialIndex.new()
	road_index.rebuild(active_roads)

	var parcel_lookup: Dictionary = {}
	if not GameStore.city.is_empty():
		for parcel in GameStore.city.get("parcels", []):
			parcel_lookup[str(parcel["id"])] = parcel
	var occupied_parcel_index: Dictionary = {}
	if not GameStore.city.is_empty():
		for building in GameStore.city.get("buildings", []):
			var parcel: Dictionary = parcel_lookup.get(str(building.get("parcelId", "")), {})
			if not parcel.is_empty():
				_index_occupied_parcel(occupied_parcel_index, parcel)

	for tree_index in range(_tree_data.size()):
		var tree: Dictionary = _tree_data[tree_index]
		var point := Vector2(float(tree["x"]), float(tree["z"]))
		var blocked := road_index.point_near_road(point, 16.0)
		if not blocked:
			blocked = _point_in_indexed_parcel(point, occupied_parcel_index, 10.0)
		var scale := 0.0001 if blocked else float(tree["scale"])
		var tree_type := str(tree["type"])
		var batch_key := str(tree.get("batch_key", ""))
		var multimesh: MultiMesh = _tree_multimeshes.get(batch_key)
		if multimesh == null:
			continue
		var origin: Vector2 = _tree_batch_origins.get(batch_key, Vector2.ZERO)
		var asset_scale := scale * float(TREE_MODEL_SCALE[tree_type])
		var basis := Basis(Vector3.UP, float(tree["rotation"])).scaled(Vector3.ONE * asset_scale)
		var transform := Transform3D(
			basis,
			Vector3(float(tree["x"]) - origin.x, float(tree["ground"]), float(tree["z"]) - origin.y)
		)
		multimesh.set_instance_transform(
			int(tree["instance_index"]),
			transform * (_tree_model_transforms[tree_type] as Transform3D)
		)


func _index_occupied_parcel(index: Dictionary, parcel: Dictionary) -> void:
	var half_w := float(parcel.get("w", 0.0)) * 0.5 + 12.0
	var half_h := float(parcel.get("h", 0.0)) * 0.5 + 12.0
	var min_x := floori((float(parcel.get("x", 0.0)) - half_w) / PARCEL_INDEX_CELL_SIZE)
	var max_x := floori((float(parcel.get("x", 0.0)) + half_w) / PARCEL_INDEX_CELL_SIZE)
	var min_y := floori((float(parcel.get("y", 0.0)) - half_h) / PARCEL_INDEX_CELL_SIZE)
	var max_y := floori((float(parcel.get("y", 0.0)) + half_h) / PARCEL_INDEX_CELL_SIZE)
	for cell_y in range(min_y, max_y + 1):
		for cell_x in range(min_x, max_x + 1):
			var key := Vector2i(cell_x, cell_y)
			var bucket: Array = index.get(key, [])
			bucket.append(parcel)
			index[key] = bucket


func _point_in_indexed_parcel(point: Vector2, index: Dictionary, padding: float) -> bool:
	var key := Vector2i(
		floori(point.x / PARCEL_INDEX_CELL_SIZE),
		floori(point.y / PARCEL_INDEX_CELL_SIZE)
	)
	for parcel_value in index.get(key, []):
		var parcel: Dictionary = parcel_value
		if _point_in_parcel(point, parcel, padding):
			return true
	return false


func _find_tree_mesh(node: Node, parent_transform: Transform3D) -> Dictionary:
	var transform := parent_transform
	if node is Node3D:
		transform = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			return {"mesh": mesh_instance.mesh, "transform": transform}
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


func _point_in_parcel(point: Vector2, parcel: Dictionary, padding: float) -> bool:
	var half_w := float(parcel.get("w", 0.0)) * 0.5 + padding
	var half_h := float(parcel.get("h", 0.0)) * 0.5 + padding
	return abs(point.x - float(parcel["x"])) <= half_w and abs(point.y - float(parcel["y"])) <= half_h


func _is_regional_map() -> bool:
	return MapDefinition.active_map_id() != MapDefinition.LEGACY_CITY_MAP_ID


func _forest_potential(x: float, z: float) -> float:
	return (
		Terrain.regional_forest_potential(GameStore.city_seed, x, z)
		if _is_regional_map()
		else Terrain.forest_potential(GameStore.city_seed, x, z)
	)


func _should_place_tree(x: float, z: float, forest: float = -1.0) -> bool:
	if forest < 0.0:
		forest = _forest_potential(x, z)
	var threshold := 0.49 if _is_regional_map() else 0.59
	if forest < threshold:
		return false
	var grove_threshold := 0.34 if _is_regional_map() else 0.45
	if _grove_noise(x, z) < grove_threshold:
		return false
	if _pseudo(x, z, 3) < (0.035 if _is_regional_map() else 0.09):
		return false
	for line_key in ["line1", "line2", "line3", "line4"]:
		for segment_index in range(Layout.BASE_SEGMENTS[line_key].size()):
			var points := Layout.segment_points(line_key, segment_index)
			for index in range(points.size() - 1):
				if _distance_to_segment(Vector2(x, z), points[index], points[index + 1]) < 30.0:
					return false
	return true


func _grove_noise(x: float, z: float) -> float:
	var grove_scale := 720.0 if _is_regional_map() else 430.0
	var grid_x := floori(x / grove_scale)
	var grid_z := floori(z / grove_scale)
	var fraction_x := _smoothstep(x / grove_scale - float(grid_x))
	var fraction_z := _smoothstep(z / grove_scale - float(grid_z))
	var top := lerpf(_pseudo(float(grid_x), float(grid_z), 11), _pseudo(float(grid_x + 1), float(grid_z), 11), fraction_x)
	var bottom := lerpf(_pseudo(float(grid_x), float(grid_z + 1), 11), _pseudo(float(grid_x + 1), float(grid_z + 1), 11), fraction_x)
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
	var value := sin(x * 12.9898 + z * 78.233 + float(GameStore.city_seed) * 0.00317 + float(channel) * 19.19) * 43758.5453
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


func _valid_cached_trees(value: Variant) -> bool:
	if typeof(value) != TYPE_ARRAY or value.size() > 100000:
		return false
	for tree in value:
		if typeof(tree) != TYPE_DICTIONARY or tree.get("type", "") not in ["small", "large"]:
			return false
		for field in ["x", "z", "scale", "rotation", "ground"]:
			if typeof(tree.get(field)) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(tree[field])):
				return false
	return true


func _exit_tree() -> void:
	_build_request += 1
