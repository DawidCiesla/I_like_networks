extends Node3D

const Terrain = preload("res://scripts/world/terrain_model.gd")
const RoadGeometry = preload("res://scripts/render/road_geometry.gd")
const BuildingAssets = preload("res://scripts/render/building_asset_library.gd")
const BuildingFoundation = preload("res://scripts/render/building_foundation.gd")
const BuildingOrientation = preload("res://scripts/render/building_orientation.gd")

const ROAD_WIDTH := {
	"arterial": 31.0,
	"collector": 21.0,
	"local": 15.0,
	"service": 12.0,
}

const FOUNDATION_TOP_CLEARANCE := BuildingFoundation.TOP_CLEARANCE
const FOUNDATION_FOOTPRINT_MARGIN := 1.0

const SIDEWALK_WIDTH := {
	"arterial": 42.0,
	"collector": 31.0,
	"local": 23.0,
	"service": 19.0,
}

const SIDEWALK_SURFACE_HEIGHT := 0.045
const ROAD_SURFACE_HEIGHT := 0.065
const CURB_SURFACE_HEIGHT := 0.082
const MARKING_SURFACE_HEIGHT := 0.095

const BUILDING_COLORS := {
	"residential": Color("#b5a98e"),
	"mixed": Color("#9f9a88"),
	"commercial": Color("#b8aa7c"),
	"civic": Color("#a4aaa9"),
	"industrial": Color("#8d8d82"),
}

var _roads_root: Node3D
var _road_markings_root: Node3D
var _junction_root: Node3D
var _buildings_root: Node3D
var _foundation_instance: MultiMeshInstance3D
var _foundation_multimesh: MultiMesh
var _foundation_signature := ""

var _road_cache: Dictionary = {}
var _building_cache: Dictionary = {}
var _junction_signature := ""
var _active_junctions_cache: Array[Dictionary] = []
var _active_junctions_source_signature := ""

func _ready() -> void:
	_roads_root = Node3D.new()
	_roads_root.name = "Roads"
	add_child(_roads_root)
	_road_markings_root = Node3D.new()
	_road_markings_root.name = "RoadMarkings"
	add_child(_road_markings_root)

	_junction_root = Node3D.new()
	_junction_root.name = "Junctions"
	add_child(_junction_root)

	_buildings_root = Node3D.new()
	_buildings_root.name = "Buildings"
	add_child(_buildings_root)
	_setup_foundations()

	GameStore.city_changed.connect(sync_city)
	GameStore.state_changed.connect(_on_state_changed)
	sync_city()

func _on_state_changed() -> void:
	sync_city()

func sync_city() -> void:
	if GameStore.city.is_empty():
		return
	_sync_roads()
	_sync_junctions()
	_sync_buildings()

func _road_signature(road: Dictionary) -> String:
	var status := str(road.get("status", "planned"))
	if status == "constructing":
		var bucket := clampi(floori(float(road.get("constructionProgress", 0.0)) * 20.0), 1, 20)
		return "constructing:%d" % bucket
	if status == "planned":
		return "planned:%s" % _road_planned_visible(road)
	return status

func _road_planned_visible(road: Dictionary) -> bool:
	var district_id := str(road.get("districtId", ""))
	for district in GameStore.city["districts"]:
		if str(district.get("id", "")) == district_id:
			return str(district.get("status", "")) == "active"
	return false

func _sync_roads() -> void:
	var live: Dictionary = {}
	var roads_changed := false

	for road in GameStore.city["roads"]:
		var road_id := str(road["id"])
		live[road_id] = true
		var signature := _road_signature(road)
		var previous: Dictionary = _road_cache.get(road_id, {})

		if not previous.is_empty() and str(previous.get("signature", "")) == signature:
			continue

		if not previous.is_empty():
			var old_node: Node = previous.get("node")
			if old_node:
				old_node.queue_free()
			_road_cache.erase(road_id)
			roads_changed = true

		var node := _create_road_node(road, signature)
		if node != null:
			_roads_root.add_child(node)
			_road_cache[road_id] = {
				"signature": signature,
				"node": node,
			}
			roads_changed = true

	for road_id in _road_cache.keys():
		if not live.has(road_id):
			var entry: Dictionary = _road_cache[road_id]
			var node: Node = entry.get("node")
			if node:
				node.queue_free()
			_road_cache.erase(road_id)
			roads_changed = true

	if roads_changed:
		_rebuild_road_markings()

func _create_road_node(road: Dictionary, signature: String) -> Node3D:
	if signature == "planned:false":
		return null

	var points := _road_points(road)
	if points.size() < 2:
		return null

	var root := Node3D.new()
	root.name = str(road["id"])

	if signature.begins_with("constructing:"):
		var bucket := int(signature.get_slice(":", 1))
		points = _polyline_prefix(points, float(bucket) / 20.0)

	if signature == "planned:true":
		_add_ribbon(
			root,
			points,
			3.0,
			Color(0.55, 0.57, 0.54, 0.30),
			MARKING_SURFACE_HEIGHT
		)
		return root

	var road_class := str(road.get("class", "local"))
	_add_ribbon(
		root,
		points,
		float(SIDEWALK_WIDTH.get(road_class, 23.0)),
		Color("#777a74"),
		SIDEWALK_SURFACE_HEIGHT
	)
	_add_ribbon(
		root,
		points,
		float(ROAD_WIDTH.get(road_class, 15.0)),
		Color("#3b3d3b"),
		ROAD_SURFACE_HEIGHT
	)
	return root

func _add_ribbon(
	parent: Node3D,
	points: Array[Vector2],
	width: float,
	color: Color,
	height_offset: float
) -> void:
	if points.size() < 2:
		return

	var mesh = RoadGeometry.create_ribbon_mesh(
		GameStore.city_seed,
		points,
		width,
		color,
		height_offset,
		RoadGeometry.DEFAULT_SAMPLE_SPACING,
		true
	)
	if mesh == null:
		return

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)

func _road_points(road: Dictionary) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for raw in road.get("points", []):
		result.append(Vector2(float(raw["x"]), float(raw["y"])))
	return result

func _rebuild_road_markings() -> void:
	for child in _road_markings_root.get_children():
		child.queue_free()
	var junction_positions_by_road: Dictionary = {}
	for junction_data in _active_junctions():
		var junction: Dictionary = junction_data["junction"]
		var position := Vector2(float(junction["x"]), float(junction["y"]))
		for road in junction_data["roads"]:
			var road_id := str(road["id"])
			if not junction_positions_by_road.has(road_id):
				junction_positions_by_road[road_id] = []
			junction_positions_by_road[road_id].append(position)

	for road_class in ["arterial", "collector", "local", "service"]:
		var road_details: Array[Dictionary] = []
		var marking_roads: Array[Dictionary] = []
		for road in GameStore.city.get("roads", []):
			var status := str(road.get("status", ""))
			if status not in ["built", "constructing"]:
				continue
			if str(road.get("class", "local")) != road_class:
				continue
			var points := _road_points(road)
			if status == "constructing":
				var signature := _road_signature(road)
				var bucket := int(signature.get_slice(":", 1))
				points = _polyline_prefix(points, float(bucket) / 20.0)
			points = RoadGeometry.resample_polyline(points)
			if points.size() < 2:
				continue
			road_details.append({"road": road, "points": points})
			if status == "built" and _polyline_length(points) > 30.0:
				marking_roads.append({"road": road, "points": points})
		if road_details.is_empty():
			continue

		var mesh := ImmediateMesh.new()
		var curb_material := StandardMaterial3D.new()
		curb_material.albedo_color = Color("#969991")
		curb_material.roughness = 1.0
		mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, curb_material)
		for road_detail in road_details:
			var points: Array[Vector2] = road_detail["points"]
			var road: Dictionary = road_detail["road"]
			var road_id := str(road["id"])
			var curb_paths := _curb_paths(
				points,
				float(ROAD_WIDTH[road_class]) * 0.5,
				junction_positions_by_road.get(road_id, [])
			)
			for curb_path_value in curb_paths:
				var curb_path: Array[Vector2] = curb_path_value
				_append_curb_strips(mesh, curb_path, float(ROAD_WIDTH[road_class]), 1.4)
		mesh.surface_end()

		if road_class in ["arterial", "collector"] and not marking_roads.is_empty():
			var marking_material := StandardMaterial3D.new()
			marking_material.albedo_color = Color("#cbbc7f") if road_class == "arterial" else Color("#c7c7b5")
			marking_material.roughness = 1.0
			mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, marking_material)
			for marking_road in marking_roads:
				var points: Array[Vector2] = marking_road["points"]
				_append_centerline_dashes(mesh, points, road_class)
			mesh.surface_end()

		var markings := MeshInstance3D.new()
		markings.name = "%sRoadDetails" % road_class.capitalize()
		markings.mesh = mesh
		markings.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_road_markings_root.add_child(markings)

	_rebuild_crosswalks()

func _rebuild_crosswalks() -> void:
	var node_lookup: Dictionary = {}
	for node in GameStore.city.get("nodes", []):
		node_lookup[str(node["id"])] = Vector2(float(node["x"]), float(node["y"]))
	if node_lookup.is_empty():
		return

	var road_lookup: Dictionary = {}
	for road in GameStore.city.get("roads", []):
		if str(road.get("status", "")) == "built":
			road_lookup[str(road["id"])] = road

	var edges_by_node: Dictionary = {}
	for edge in GameStore.city.get("graph_edges", []):
		var first_id := str(edge.get("a", ""))
		var second_id := str(edge.get("b", ""))
		if not edges_by_node.has(first_id):
			edges_by_node[first_id] = []
		if not edges_by_node.has(second_id):
			edges_by_node[second_id] = []
		edges_by_node[first_id].append({"edge": edge, "neighbor": second_id})
		edges_by_node[second_id].append({"edge": edge, "neighbor": first_id})

	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#d8d2be")
	material.roughness = 1.0
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
	var has_crosswalks := false
	for junction_data in _active_junctions():
		var junction: Dictionary = junction_data["junction"]
		var node_id := str(junction.get("nodeId", ""))
		var junction_position := Vector2(float(junction["x"]), float(junction["y"]))
		for arm in edges_by_node.get(node_id, []):
			var edge: Dictionary = arm["edge"]
			var road: Dictionary = road_lookup.get(str(edge.get("roadId", "")), {})
			if road.is_empty():
				continue
			var road_class := str(road.get("class", "local"))
			if road_class == "service":
				continue
			var neighbor_position: Vector2 = node_lookup.get(str(arm["neighbor"]), junction_position)
			var direction := (neighbor_position - junction_position).normalized()
			if direction.length_squared() <= 0.000001:
				continue
			_append_crosswalk(mesh, junction_position, direction, float(ROAD_WIDTH[road_class]))
			has_crosswalks = true
	mesh.surface_end()
	if not has_crosswalks:
		return

	var instance := MeshInstance3D.new()
	instance.name = "PedestrianCrosswalks"
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_road_markings_root.add_child(instance)

func _append_crosswalk(
	mesh: ImmediateMesh,
	junction_position: Vector2,
	direction: Vector2,
	road_width: float
) -> void:
	var across := Vector2(-direction.y, direction.x)
	var center := junction_position + direction * (road_width * 0.5 + 6.0)
	var across_half_width := road_width * 0.5 - 1.5
	var across_offset := -across_half_width + 1.2
	while across_offset <= across_half_width:
		var stripe_center := center + across * across_offset
		var along_half_width := 0.62
		var across_half_stripe := 0.58
		var near_start := stripe_center - direction * along_half_width - across * across_half_stripe
		var far_start := stripe_center - direction * along_half_width + across * across_half_stripe
		var near_end := stripe_center + direction * along_half_width - across * across_half_stripe
		var far_end := stripe_center + direction * along_half_width + across * across_half_stripe
		_add_marking_triangle(mesh, near_start, far_start, near_end)
		_add_marking_triangle(mesh, near_end, far_start, far_end)
		across_offset += 2.5

func _curb_paths(
	points: Array[Vector2],
	endpoint_trim: float,
	junction_positions: Array
) -> Array:
	var result: Array = []
	var total_length := _polyline_length(points)
	if points.size() < 2 or total_length <= 1.0:
		return result

	var spans: Array[Vector2] = [Vector2(0.0, total_length)]
	for junction_position_value in junction_positions:
		var junction_position: Vector2 = junction_position_value
		var projection := _project_point_onto_polyline(junction_position, points)
		if float(projection["distance_to_path"]) > 1.5:
			continue
		var cut_start := maxf(0.0, float(projection["distance_along"]) - endpoint_trim)
		var cut_end := minf(total_length, float(projection["distance_along"]) + endpoint_trim)
		var next_spans: Array[Vector2] = []
		for span in spans:
			if cut_end <= span.x or cut_start >= span.y:
				next_spans.append(span)
				continue
			if cut_start - span.x > 1.0:
				next_spans.append(Vector2(span.x, cut_start))
			if span.y - cut_end > 1.0:
				next_spans.append(Vector2(cut_end, span.y))
		spans = next_spans

	for span in spans:
		var path := _polyline_slice(points, span.x, span.y)
		if path.size() >= 2:
			result.append(path)
	return result

func _polyline_slice(points: Array[Vector2], start_distance: float, end_distance: float) -> Array[Vector2]:
	var result: Array[Vector2] = []
	if points.size() < 2 or end_distance <= start_distance:
		return result
	result.append(_point_on_polyline(points, start_distance))
	var travelled := 0.0
	for index in range(points.size() - 1):
		travelled += points[index].distance_to(points[index + 1])
		if travelled > start_distance and travelled < end_distance:
			result.append(points[index + 1])
	var end_point := _point_on_polyline(points, end_distance)
	if result.back().distance_to(end_point) > 0.01:
		result.append(end_point)
	return result

func _project_point_onto_polyline(point: Vector2, points: Array[Vector2]) -> Dictionary:
	var travelled := 0.0
	var nearest_distance := INF
	var nearest_along := 0.0
	for index in range(points.size() - 1):
		var start := points[index]
		var finish := points[index + 1]
		var segment := finish - start
		var segment_length := segment.length()
		if segment_length <= 0.000001:
			continue
		var t: float = clampf((point - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
		var projected := start + segment * t
		var distance := point.distance_to(projected)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_along = travelled + segment_length * t
		travelled += segment_length
	return {"distance_along": nearest_along, "distance_to_path": nearest_distance}

func _append_curb_strips(
	mesh: ImmediateMesh,
	points: Array[Vector2],
	road_width: float,
	strip_width: float
) -> void:
	if points.size() < 2:
		return

	for side in [-1.0, 1.0]:
		var inner_edges: Array[Vector2] = []
		var outer_edges: Array[Vector2] = []
		for index in range(points.size()):
			var previous := points[maxi(0, index - 1)]
			var next := points[mini(points.size() - 1, index + 1)]
			var direction := (next - previous).normalized()
			var normal := Vector2(-direction.y, direction.x)
			var center: Vector2 = points[index] + normal * road_width * 0.5 * side
			inner_edges.append(center - normal * strip_width * 0.5)
			outer_edges.append(center + normal * strip_width * 0.5)

		for index in range(points.size() - 1):
			_add_curb_triangle(mesh, inner_edges[index], outer_edges[index], inner_edges[index + 1])
			_add_curb_triangle(mesh, inner_edges[index + 1], outer_edges[index], outer_edges[index + 1])

func _add_curb_triangle(mesh: ImmediateMesh, a: Vector2, b: Vector2, c: Vector2) -> void:
	RoadGeometry.append_triangle_above_terrain(
		mesh,
		GameStore.city_seed,
		a,
		b,
		c,
		CURB_SURFACE_HEIGHT
	)

func _append_centerline_dashes(
	mesh: ImmediateMesh,
	points: Array[Vector2],
	road_class: String
) -> void:
	var total_length := _polyline_length(points)
	var end_distance := total_length - 12.0
	var dash_length := 8.0 if road_class == "arterial" else 5.5
	var gap_length := 8.0 if road_class == "arterial" else 7.0
	var marking_width := 0.72 if road_class == "arterial" else 0.48
	var distance := 12.0
	while distance < end_distance:
		var dash_end := minf(distance + dash_length, end_distance)
		var start := _point_on_polyline(points, distance)
		var finish := _point_on_polyline(points, dash_end)
		var direction := (finish - start).normalized()
		if direction.length_squared() > 0.0:
			var normal := Vector2(-direction.y, direction.x) * marking_width * 0.5
			var left_start := start + normal
			var right_start := start - normal
			var left_end := finish + normal
			var right_end := finish - normal
			_add_marking_triangle(mesh, left_start, left_end, right_start)
			_add_marking_triangle(mesh, left_end, right_end, right_start)
		distance += dash_length + gap_length

func _add_marking_triangle(mesh: ImmediateMesh, a: Vector2, b: Vector2, c: Vector2) -> void:
	RoadGeometry.append_triangle_above_terrain(
		mesh,
		GameStore.city_seed,
		a,
		b,
		c,
		MARKING_SURFACE_HEIGHT
	)

func _polyline_length(points: Array[Vector2]) -> float:
	var result := 0.0
	for index in range(points.size() - 1):
		result += points[index].distance_to(points[index + 1])
	return result

func _point_on_polyline(points: Array[Vector2], distance: float) -> Vector2:
	var remaining := distance
	for index in range(points.size() - 1):
		var start := points[index]
		var finish := points[index + 1]
		var segment_length := start.distance_to(finish)
		if remaining <= segment_length:
			return start.lerp(finish, 0.0 if segment_length <= 0.000001 else remaining / segment_length)
		remaining -= segment_length
	return points.back() if not points.is_empty() else Vector2.ZERO

func _polyline_prefix(points: Array[Vector2], progress: float) -> Array[Vector2]:
	var clamped: float = clampf(progress, 0.0, 1.0)
	if clamped >= 1.0:
		return points.duplicate()
	if clamped <= 0.0 or points.size() < 2:
		return []

	var lengths: Array[float] = []
	var total := 0.0
	for index in range(points.size() - 1):
		var length := points[index].distance_to(points[index + 1])
		lengths.append(length)
		total += length

	var target: float = total * clamped
	var travelled := 0.0
	var result: Array[Vector2] = [points[0]]

	for index in range(lengths.size()):
		var length := lengths[index]
		if travelled + length <= target:
			result.append(points[index + 1])
			travelled += length
			continue

		var local: float = 0.0 if length <= 0.000001 else (target - travelled) / length
		result.append(points[index].lerp(points[index + 1], local))
		break

	return result

func _active_junctions() -> Array[Dictionary]:
	var source_parts: Array[String] = []
	for road in GameStore.city.get("roads", []):
		var status := str(road.get("status", ""))
		if status in ["built", "constructing"]:
			source_parts.append("%s:%s" % [str(road["id"]), _road_signature(road)])
	source_parts.sort()
	var source_signature := "%d::%s" % [GameStore.city_seed, "|".join(source_parts)]
	if source_signature == _active_junctions_source_signature:
		return _active_junctions_cache
	_active_junctions_source_signature = source_signature
	_active_junctions_cache.clear()

	var visible_roads: Dictionary = {}
	for road in GameStore.city.get("roads", []):
		var status := str(road.get("status", ""))
		if status not in ["built", "constructing"]:
			continue
		var points := _road_points(road)
		if status == "constructing":
			var signature := _road_signature(road)
			var bucket := int(signature.get_slice(":", 1))
			points = _polyline_prefix(points, float(bucket) / 20.0)
		if points.size() >= 2:
			visible_roads[str(road["id"])] = {"road": road, "points": points}

	for junction in GameStore.city.get("junctions", []):
		var position := Vector2(float(junction["x"]), float(junction["y"]))
		var visible_arms: Array[Dictionary] = []
		for road_id_value in junction.get("roadIds", []):
			var road_id := str(road_id_value)
			if not visible_roads.has(road_id):
				continue
			var road_entry: Dictionary = visible_roads[road_id]
			var points: Array[Vector2] = road_entry["points"]
			var projection := _project_point_onto_polyline(position, points)
			if float(projection["distance_to_path"]) <= 1.5:
				visible_arms.append(road_entry["road"])
		if visible_arms.size() >= 2:
			_active_junctions_cache.append({"junction": junction, "roads": visible_arms})

	return _active_junctions_cache

func _sync_junctions() -> void:
	var active_junctions := _active_junctions()
	var signature_parts: Array[String] = []
	for junction_data in active_junctions:
		var junction: Dictionary = junction_data["junction"]
		var road_ids: Array[String] = []
		for road in junction_data["roads"]:
			road_ids.append(str(road["id"]))
		road_ids.sort()
		signature_parts.append("%s:%s" % [str(junction["id"]), "|".join(road_ids)])
	signature_parts.sort()
	var signature := "|".join(signature_parts)
	if signature == _junction_signature:
		return
	_junction_signature = signature

	for child in _junction_root.get_children():
		child.queue_free()

	var node_lookup: Dictionary = {}
	for node in GameStore.city.get("nodes", []):
		node_lookup[str(node["id"])] = Vector2(float(node["x"]), float(node["y"]))

	var edges_by_node: Dictionary = {}
	for edge in GameStore.city.get("graph_edges", []):
		var first_id := str(edge.get("a", ""))
		var second_id := str(edge.get("b", ""))
		if not edges_by_node.has(first_id):
			edges_by_node[first_id] = []
		if not edges_by_node.has(second_id):
			edges_by_node[second_id] = []
		edges_by_node[first_id].append({"edge": edge, "neighbor": second_id})
		edges_by_node[second_id].append({"edge": edge, "neighbor": first_id})

	for junction_data in active_junctions:
		var junction: Dictionary = junction_data["junction"]
		var junction_position := Vector2(float(junction["x"]), float(junction["y"]))
		var node_id := str(junction.get("nodeId", ""))
		var visible_roads: Dictionary = {}
		for road in junction_data["roads"]:
			visible_roads[str(road["id"])] = road

		var sidewalk_arms: Array = []
		var road_arms: Array = []
		for edge_arm in edges_by_node.get(node_id, []):
			var edge: Dictionary = edge_arm["edge"]
			var road_id := str(edge.get("roadId", ""))
			if not visible_roads.has(road_id):
				continue

			var neighbor_position: Vector2 = node_lookup.get(
				str(edge_arm["neighbor"]),
				junction_position
			)
			var direction := (neighbor_position - junction_position).normalized()
			if direction.length_squared() <= 0.000001:
				continue

			var road: Dictionary = visible_roads[road_id]
			var road_class := str(road.get("class", "local"))
			sidewalk_arms.append({
				"direction": direction,
				"width": float(SIDEWALK_WIDTH.get(road_class, 23.0)),
			})
			road_arms.append({
				"direction": direction,
				"width": float(ROAD_WIDTH.get(road_class, 15.0)),
			})

		if road_arms.size() < 2:
			continue

		_add_junction_patch(
			junction_position,
			sidewalk_arms,
			Color("#777a74"),
			SIDEWALK_SURFACE_HEIGHT
		)
		_add_junction_patch(
			junction_position,
			road_arms,
			Color("#3b3d3b"),
			ROAD_SURFACE_HEIGHT
		)

func _add_junction_patch(
	center: Vector2,
	arms: Array,
	color: Color,
	height_offset: float
) -> void:
	var mesh = RoadGeometry.create_junction_patch_mesh(
		GameStore.city_seed,
		center,
		arms,
		color,
		height_offset
	)
	if mesh == null:
		return

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_junction_root.add_child(mesh_instance)

func _sync_buildings() -> void:
	var live: Dictionary = {}
	var parcel_lookup: Dictionary = {}
	for parcel in GameStore.city["parcels"]:
		parcel_lookup[str(parcel["id"])] = parcel

	for building in GameStore.city["buildings"]:
		var building_id := str(building["id"])
		live[building_id] = true
		var parcel: Dictionary = parcel_lookup.get(str(building["parcelId"]), {})
		if parcel.is_empty():
			continue

		var entry: Dictionary = _building_cache.get(building_id, {})
		if entry.is_empty():
			entry = _create_building(building, parcel)
			_building_cache[building_id] = entry

		_update_building(entry, building)

	for building_id in _building_cache.keys():
		if not live.has(building_id):
			var entry: Dictionary = _building_cache[building_id]
			var node: Node = entry.get("root")
			if node:
				node.queue_free()
			_building_cache.erase(building_id)

	_sync_foundations()

func _setup_foundations() -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#77766c")
	material.roughness = 1.0
	mesh.material = material

	_foundation_multimesh = MultiMesh.new()
	_foundation_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_foundation_multimesh.mesh = mesh
	_foundation_instance = MultiMeshInstance3D.new()
	_foundation_instance.name = "BuildingFoundations"
	_foundation_instance.multimesh = _foundation_multimesh
	_foundation_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_foundation_instance)

func _sync_foundations() -> void:
	var building_ids: Array = _building_cache.keys()
	building_ids.sort()
	var signature_parts: PackedStringArray = []
	var instances: Array[Transform3D] = []

	for building_id_value in building_ids:
		var entry: Dictionary = _building_cache[building_id_value]
		var center: Vector2 = entry["foundation_center"]
		var width := float(entry["foundation_width"])
		var depth := float(entry["foundation_depth"])
		var top := float(entry["foundation_top"])
		var bottom := float(entry["foundation_bottom"])
		var rotation := float(entry["foundation_rotation"])
		var transform := BuildingFoundation.box_transform(
			center,
			width,
			depth,
			rotation,
			bottom,
			top - FOUNDATION_TOP_CLEARANCE,
			FOUNDATION_TOP_CLEARANCE
		)
		instances.append(transform)
		signature_parts.append("%s:%.3f:%.3f:%.3f:%.3f:%.3f:%.3f:%.3f" % [
			str(building_id_value), center.x, center.y, width, depth, top, bottom, rotation
		])

	var signature := ";".join(signature_parts)
	if signature == _foundation_signature:
		return
	_foundation_signature = signature
	_foundation_multimesh.instance_count = instances.size()
	for index in range(instances.size()):
		_foundation_multimesh.set_instance_transform(index, instances[index])

func _create_building(building: Dictionary, parcel: Dictionary) -> Dictionary:
	var root := Node3D.new()
	root.name = str(building["id"])
	_buildings_root.add_child(root)

	var inset: float = maxf(4.0, float(parcel.get("setback", 6.0)))
	var width: float = maxf(14.0, float(parcel.get("w", 38.0)) - inset * 1.4)
	var depth: float = maxf(12.0, float(parcel.get("h", 34.0)) - inset * 1.4)
	var height := float(building.get("profile", {}).get("heightMeters", 8.0))
	var x := float(building["x"])
	var z := float(building["y"])
	var rotation := float(building.get("rotationRadians", 0.0))
	var center_ground := Terrain.height(GameStore.city_seed, x, z)
	root.position = Vector3(x, 0.0, z)
	root.rotation.y = -rotation

	var asset := BuildingAssets.create_visual(building, width, height, depth, center_ground)
	var foundation_width := width
	var foundation_depth := depth
	if not asset.is_empty():
		foundation_width = float(asset.get("footprint_width", width * 0.78)) + FOUNDATION_FOOTPRINT_MARGIN
		foundation_depth = float(asset.get("footprint_depth", depth * 0.78)) + FOUNDATION_FOOTPRINT_MARGIN

	var ground_range := BuildingFoundation.height_range(
		GameStore.city_seed,
		Vector2(x, z),
		rotation,
		foundation_width,
		foundation_depth
	)
	var ground := ground_range.y
	var foundation_top := ground + FOUNDATION_TOP_CLEARANCE
	var foundation_bottom := ground_range.x

	if not asset.is_empty():
		var visual: Node3D = asset["visual"]
		visual.position.y += ground - center_ground
		visual.rotation.y = BuildingOrientation.frontage_yaw_adjustment(
			rotation,
			Vector2(x, z),
			_frontage_road_points(parcel),
			float(asset.get("front_side", 1.0))
		)
		root.add_child(visual)
		return {
			"root": root,
			"mesh": visual,
			"material": null,
			"height": height,
			"width": width,
			"depth": depth,
			"ground": ground,
			"foundation_center": Vector2(x, z),
			"foundation_width": foundation_width,
			"foundation_depth": foundation_depth,
			"foundation_top": foundation_top,
			"foundation_bottom": foundation_bottom,
			"foundation_rotation": rotation,
			"roof": null,
			"asset_scale": float(asset["scale"]),
			"asset_bottom": float(asset["bottom"]),
		}

	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, height, depth)
	var material := StandardMaterial3D.new()
	material.albedo_color = BUILDING_COLORS.get(str(building.get("zone", "")), Color("#a09b88"))
	material.roughness = 0.92
	box.material = material
	mesh_instance.mesh = box
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(mesh_instance)

	return {
		"root": root,
		"mesh": mesh_instance,
		"material": material,
		"height": height,
		"width": width,
		"depth": depth,
		"ground": ground,
		"foundation_center": Vector2(x, z),
		"foundation_width": foundation_width,
		"foundation_depth": foundation_depth,
		"foundation_top": foundation_top,
		"foundation_bottom": foundation_bottom,
		"foundation_rotation": rotation,
		"roof": null,
	}

func _frontage_road_points(parcel: Dictionary) -> Array[Vector2]:
	var frontage_id := str(parcel.get("frontageRoadId", ""))
	for road in GameStore.city.get("roads", []):
		if str(road.get("id", "")) == frontage_id:
			return _road_points(road)
	return []

func _update_building(entry: Dictionary, building: Dictionary) -> void:
	var progress: float = 1.0 if str(building.get("status", "")) == "built" else clampf(float(building.get("constructionProgress", 0.0)), 0.04, 1.0)
	if entry.has("asset_scale"):
		var asset_scale := float(entry["asset_scale"])
		var asset_bottom := float(entry["asset_bottom"])
		var asset_visual: Node3D = entry["mesh"]
		asset_visual.scale = Vector3(asset_scale, asset_scale * progress, asset_scale)
		asset_visual.position.y = float(entry["ground"]) + 0.7 - asset_bottom * asset_scale * progress
		var desired_transparency := 0.22 if str(building.get("status", "")) != "built" else 0.0
		if not entry.has("asset_transparency") or not is_equal_approx(float(entry["asset_transparency"]), desired_transparency):
			_set_geometry_transparency(asset_visual, desired_transparency)
			entry["asset_transparency"] = desired_transparency
		return

	var mesh_instance: MeshInstance3D = entry["mesh"]
	var height := float(entry["height"])
	mesh_instance.scale.y = progress
	mesh_instance.position.y = float(entry["ground"]) + height * progress * 0.5 + 0.7

	if str(building.get("status", "")) != "built":
		var material: StandardMaterial3D = entry["material"]
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color.a = 0.78
		return

	var built_material: StandardMaterial3D = entry["material"]
	built_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	built_material.albedo_color.a = 1.0

	if entry["roof"] != null:
		return

	var kind := str(building.get("profile", {}).get("kind", ""))
	if kind not in ["house", "townhouse"]:
		return

	var roof := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(
		float(entry["width"]) * 1.05,
		5.5,
		float(entry["depth"]) * 1.05
	)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#654a3b")
	material.roughness = 1.0
	prism.material = material
	roof.mesh = prism
	roof.position.y = float(entry["ground"]) + height + 3.0
	entry["root"].add_child(roof)
	entry["roof"] = roof

func _set_geometry_transparency(node: Node, transparency: float) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).transparency = transparency
	for child in node.get_children():
		_set_geometry_transparency(child, transparency)
