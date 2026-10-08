extends Node3D

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
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

const ROAD_COLOR := {
	"arterial": Color("#343735"),
	"collector": Color("#3a3d3a"),
	"local": Color("#40433f"),
	"service": Color("#464944"),
}

const SIDEWALK_COLOR := {
	"arterial": Color("#666b66"),
	"collector": Color("#6a6f69"),
	"local": Color("#6e736c"),
	"service": Color("#72766f"),
}

const CURB_COLOR := {
	"arterial": Color("#878c85"),
	"collector": Color("#858a83"),
	"local": Color("#838880"),
	"service": Color("#81857e"),
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
var _service_buildings_root: Node3D
var _foundation_instance: MultiMeshInstance3D
var _foundation_multimesh: MultiMesh
var _foundation_signature := ""
var _foundations_dirty := true

var _road_cache: Dictionary = {}
var _road_marking_batches: Dictionary = {}
var _road_marking_inputs: Dictionary = {}
var _crosswalks_root: Node3D
var _crosswalk_signature := ""
var _building_cache: Dictionary = {}
var _service_building_cache: Dictionary = {}
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
	_crosswalks_root = Node3D.new()
	_crosswalks_root.name = "Crosswalks"
	_road_markings_root.add_child(_crosswalks_root)

	_junction_root = Node3D.new()
	_junction_root.name = "Junctions"
	add_child(_junction_root)

	_buildings_root = Node3D.new()
	_buildings_root.name = "Buildings"
	add_child(_buildings_root)
	_service_buildings_root = Node3D.new()
	_service_buildings_root.name = "PlayerServiceBuildings"
	add_child(_service_buildings_root)
	_setup_foundations()

	GameStore.city_changed.connect(sync_city)
	GameStore.state_changed.connect(_on_state_changed)
	GameStore.terrain_changed.connect(_on_terrain_changed)
	sync_city()

func _on_state_changed() -> void:
	sync_city()

func _on_terrain_changed() -> void:
	for entry_value in _road_cache.values():
		var road_node: Node = entry_value.get("node")
		if road_node:
			road_node.queue_free()
	_road_cache.clear()
	for entry_value in _building_cache.values():
		var building_node: Node = entry_value.get("root")
		if building_node:
			building_node.queue_free()
	_building_cache.clear()
	for entry_value in _service_building_cache.values():
		var service_node: Node = entry_value.get("root")
		if service_node:
			service_node.queue_free()
	_service_building_cache.clear()
	_road_marking_inputs.clear()
	_junction_signature = "terrain-edited"
	_active_junctions_source_signature = ""
	_active_junctions_cache.clear()
	_crosswalk_signature = "terrain-edited"
	_foundation_signature = ""
	_foundations_dirty = true
	sync_city()

func sync_city() -> void:
	if GameStore.city.is_empty():
		return
	_sync_roads()
	_sync_junctions()
	_sync_buildings()
	_sync_player_service_buildings()

func _road_signature(road: Dictionary) -> String:
	var status := str(road.get("status", "planned"))
	if status == "constructing":
		var bucket := clampi(floori(float(road.get("constructionProgress", 0.0)) * 20.0), 1, 20)
		return "constructing:%d" % bucket
	if status == "planned":
		return "planned:%s" % _road_planned_visible(road)
	return status

func _road_planned_visible(road: Dictionary) -> bool:
	if GameStore.is_sandbox() and str(road.get("regionalRole", "")) != "":
		if str(road.get("status", "")) == "planned":
			var regional_status := GameStore.regional_road_build_status(str(road.get("id", "")))
			if bool(regional_status.get("available", false)) or str(regional_status.get("reason", "")) == "insufficient_funds":
				return true
			for project_value in GameStore.city.get("projects", []):
				if (
					str(project_value.get("type", "")) == "road"
					and str(project_value.get("targetId", "")) == str(road.get("id", ""))
					and str(project_value.get("status", "")) in ["queued", "active"]
				):
					return true
			return false
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
		var regional_status := GameStore.regional_road_build_status(str(road.get("id", "")))
		var is_regional_frontier := bool(regional_status.get("available", false))
		var can_select_regional_frontier := (
			is_regional_frontier or str(regional_status.get("reason", "")) == "insufficient_funds"
		)
		var road_class := str(road.get("class", "collector"))
		var width := maxf(5.0, float(ROAD_WIDTH.get(road_class, 15.0)) * 0.55)
		var color := Color("#e6c16d", 0.66) if is_regional_frontier else Color(0.55, 0.57, 0.54, 0.30)
		_add_ribbon(root, points, width, color, MARKING_SURFACE_HEIGHT)
		if can_select_regional_frontier:
			_add_regional_road_pick_area(root, points, str(road.get("id", "")), width)
		return root

	var road_class := str(road.get("class", "local"))
	var profile_widths := _road_profile_widths(road, road_class)
	_add_ribbon(
		root,
		points,
		maxf(float(SIDEWALK_WIDTH.get(road_class, 23.0)), float(profile_widths.y)),
		SIDEWALK_COLOR.get(road_class, Color("#6e736c")),
		SIDEWALK_SURFACE_HEIGHT
	)
	_add_ribbon(
		root,
		points,
		maxf(float(ROAD_WIDTH.get(road_class, 15.0)), float(profile_widths.x)),
		ROAD_COLOR.get(road_class, Color("#40433f")),
		ROAD_SURFACE_HEIGHT
	)
	_add_bridge_decks(root, road, maxf(float(ROAD_WIDTH.get(road_class, 15.0)), float(profile_widths.x)))
	return root


func _add_regional_road_pick_area(parent: Node3D, points: Array[Vector2], road_id: String, road_width: float) -> void:
	var area := Area3D.new()
	area.name = "BuildRegionalRoad_%s" % road_id
	area.input_ray_pickable = true
	area.set_meta("selection", "regional_road:%s" % road_id)
	area.collision_layer = 1
	area.collision_mask = 0
	for index in range(points.size() - 1):
		var start := points[index]
		var finish := points[index + 1]
		var delta := finish - start
		var length := delta.length()
		if length <= 1.0:
			continue
		var center := (start + finish) * 0.5
		var shape := BoxShape3D.new()
		shape.size = Vector3(length + 10.0, 14.0, maxf(42.0, road_width * 4.0))
		var collision := CollisionShape3D.new()
		collision.shape = shape
		collision.position = Vector3(
			center.x,
			TerrainSurface.height(GameStore.city_seed, center.x, center.y) + 7.0,
			center.y
		)
		collision.rotation.y = -atan2(delta.y, delta.x)
		area.add_child(collision)
	area.input_event.connect(_on_regional_road_pick.bind(road_id))
	parent.add_child(area)


func _on_regional_road_pick(
	_camera: Node,
	event: InputEvent,
	_event_position: Vector3,
	_normal: Vector3,
	_shape_idx: int,
	road_id: String
) -> void:
	if GameStore.route_editor_active() or GameStore.road_builder_active() or GameStore.depot_placement_active():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		GameStore.set_selection("regional_road:%s" % road_id)
		get_viewport().set_input_as_handled()

func _road_profile_widths(road: Dictionary, road_class: String) -> Vector2:
	var profile: Dictionary = road.get("profile", {})
	var lane_width := 0.0
	for lane in profile.get("lanes", []):
		if lane is Dictionary:
			lane_width += maxf(0.0, float(lane.get("width_m", 0.0)))
	if lane_width <= 0.0:
		var legacy_width := float(ROAD_WIDTH.get(road_class, 15.0))
		return Vector2(legacy_width, float(SIDEWALK_WIDTH.get(road_class, 23.0)))
	var extras := 0.0
	var parking: Dictionary = profile.get("parking", {})
	var sidewalk: Dictionary = profile.get("sidewalk", {})
	var bike_lane: Dictionary = profile.get("bike_lane", {})
	for side in ["left", "right"]:
		if bool(parking.get(side, false)):
			extras += 2.2
		if bool(sidewalk.get(side, false)):
			extras += 2.0
	var bike_width := 0.0
	for lane in profile.get("lanes", []):
		if lane is Dictionary and str(lane.get("type", "")) == "bike":
			bike_width += maxf(0.0, float(lane.get("width_m", 0.0)))
	if bike_width <= 0.0:
		for side in ["left", "right"]:
			if bool(bike_lane.get(side, false)):
				bike_width += 1.8
	return Vector2(lane_width + bike_width, lane_width + bike_width + extras)

func _add_bridge_decks(parent: Node3D, road: Dictionary, road_width: float) -> void:
	for crossing in road.get("bridgeCrossings", []):
		if not crossing is Dictionary:
			continue
		var deck_points: Array[Vector2] = []
		var crossing_start := _bridge_point(crossing.get("start", Vector2.ZERO))
		var crossing_end := _bridge_point(crossing.get("end", Vector2.ZERO))
		deck_points.append(crossing_start)
		for raw_water_point in crossing.get("water_points", []):
			var water_point := _bridge_point(raw_water_point)
			if deck_points.back().distance_to(water_point) > 0.5:
				deck_points.append(water_point)
		if deck_points.back().distance_to(crossing_end) > 0.5:
			deck_points.append(crossing_end)
		if deck_points.size() < 2:
			continue
		var deck_offset := ROAD_SURFACE_HEIGHT + 2.8
		_add_ribbon(parent, deck_points, road_width * 0.92, Color("#303633"), deck_offset)
		for side in [-1.0, 1.0]:
			var rail_points := _offset_polyline(deck_points, side * road_width * 0.46)
			_add_ribbon(parent, rail_points, 0.72, Color("#969d97"), deck_offset + 1.15)

func _bridge_point(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if typeof(value) == TYPE_DICTIONARY:
		return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
	return Vector2.ZERO

func _offset_polyline(points: Array[Vector2], offset: float) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for index in range(points.size()):
		var before := points[maxi(0, index - 1)]
		var after := points[mini(points.size() - 1, index + 1)]
		var tangent := after - before
		if tangent.length_squared() <= 0.000001:
			result.append(points[index])
			continue
		var direction := tangent.normalized()
		var normal := Vector2(-direction.y, direction.x)
		result.append(points[index] + normal * offset)
	return result

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
	# Curbs and lane markings are grouped into class batches. A change to
	# one road only regenerates the batches containing that road (and any roads
	# whose junction trim changed), rather than resampling every road in the city.
	var junction_positions_by_road: Dictionary = {}
	for junction_data in _active_junctions():
		var junction: Dictionary = junction_data["junction"]
		var position := Vector2(float(junction["x"]), float(junction["y"]))
		for road in junction_data["roads"]:
			var road_id := str(road["id"])
			if not junction_positions_by_road.has(road_id):
				junction_positions_by_road[road_id] = []
			junction_positions_by_road[road_id].append(position)

	var current_inputs: Dictionary = {}
	var roads_by_batch: Dictionary = {}
	for road in GameStore.city.get("roads", []):
		var status := str(road.get("status", ""))
		if status not in ["built", "constructing"]:
			continue
		var road_id := str(road["id"])
		var road_class := str(road.get("class", "local"))
		var points := _road_points(road)
		if status == "constructing":
			var road_signature := _road_signature(road)
			var bucket := int(road_signature.get_slice(":", 1))
			points = _polyline_prefix(points, float(bucket) / 20.0)
		points = RoadGeometry.resample_polyline(points)
		if points.size() < 2:
			continue
		var batch_key := _road_marking_batch_key(road_class)
		var junctions: Array = junction_positions_by_road.get(road_id, [])
		var input_signature := _road_marking_input_signature(road, status, points, junctions)
		current_inputs[road_id] = {
			"signature": input_signature,
			"batch_key": batch_key,
			"road": road,
			"status": status,
			"points": points,
			"junctions": junctions,
		}
		if not roads_by_batch.has(batch_key):
			roads_by_batch[batch_key] = []
		roads_by_batch[batch_key].append(current_inputs[road_id])

	var dirty_batches: Dictionary = {}
	for road_id_value in _road_marking_inputs:
		var road_id := str(road_id_value)
		if not current_inputs.has(road_id):
			var old_input: Dictionary = _road_marking_inputs[road_id]
			dirty_batches[str(old_input["batch_key"])] = true
	for road_id_value in current_inputs:
		var road_id := str(road_id_value)
		var current: Dictionary = current_inputs[road_id]
		var previous: Dictionary = _road_marking_inputs.get(road_id, {})
		if previous.is_empty() or str(previous["signature"]) != str(current["signature"]):
			if not previous.is_empty():
				dirty_batches[str(previous["batch_key"])] = true
			dirty_batches[str(current["batch_key"])] = true

	for batch_key_value in dirty_batches:
		var batch_key := str(batch_key_value)
		var previous_node: Node = _road_marking_batches.get(batch_key)
		if previous_node:
			previous_node.queue_free()
			_road_marking_batches.erase(batch_key)
		if not roads_by_batch.has(batch_key):
			continue
		var markings := _build_road_marking_batch(batch_key, roads_by_batch[batch_key])
		if markings != null:
			_road_markings_root.add_child(markings)
			_road_marking_batches[batch_key] = markings

	_road_marking_inputs = current_inputs
	_rebuild_crosswalks_if_changed()

func _road_marking_batch_key(road_class: String) -> String:
	# Keep one draw batch per road class, as before. Caching at this level still
	# avoids rebuilding unrelated classes when a road advances a construction bucket.
	return road_class

func _road_marking_input_signature(
	road: Dictionary,
	status: String,
	points: Array[Vector2],
	junctions: Array
) -> String:
	var parts: Array[String] = [str(GameStore.city_seed), str(road.get("class", "local")), status]
	if status == "constructing":
		parts.append(_road_signature(road))
	for point in points:
		parts.append("%s,%s" % [str(point.x), str(point.y)])
	var sorted_junctions: Array[Vector2] = []
	for junction_value in junctions:
		sorted_junctions.append(junction_value)
	sorted_junctions.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		if not is_equal_approx(a.x, b.x):
			return a.x < b.x
		return a.y < b.y
	)
	for junction in sorted_junctions:
		parts.append("j%s,%s" % [str(junction.x), str(junction.y)])
	return "|".join(parts)

func _build_road_marking_batch(batch_key: String, road_details: Array) -> MeshInstance3D:
	if road_details.is_empty():
		return null
	var road_class := batch_key.get_slice(":", 0)
	var mesh := ImmediateMesh.new()
	var marking_roads: Array[Dictionary] = []
	for detail in road_details:
		if str(detail["status"]) != "built":
			continue
		var detail_points: Array[Vector2] = detail["points"]
		if _polyline_length(detail_points) > 30.0:
			marking_roads.append({"points": detail_points})
	var curb_material := StandardMaterial3D.new()
	curb_material.albedo_color = CURB_COLOR.get(road_class, Color("#838880"))
	curb_material.roughness = 1.0
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, curb_material)
	for detail in road_details:
		var points: Array[Vector2] = detail["points"]
		var curb_paths := _curb_paths(
			points,
			float(ROAD_WIDTH.get(road_class, 15.0)) * 0.5,
			detail["junctions"]
		)
		for curb_path_value in curb_paths:
			var curb_path: Array[Vector2] = curb_path_value
			_append_curb_strips(mesh, curb_path, float(ROAD_WIDTH.get(road_class, 15.0)), 1.4)
	mesh.surface_end()

	if road_class == "arterial" and not marking_roads.is_empty():
		var center_material := StandardMaterial3D.new()
		center_material.albedo_color = Color("#d2c57c")
		center_material.roughness = 1.0
		mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, center_material)
		for marking_road in marking_roads:
			var points: Array[Vector2] = marking_road["points"]
			_append_dashed_line(mesh, points, 0.0, 9.0, 6.0, 0.72)
		mesh.surface_end()

		var lane_material := StandardMaterial3D.new()
		lane_material.albedo_color = Color("#d9d9cd")
		lane_material.roughness = 1.0
		mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, lane_material)
		var lane_offset := float(ROAD_WIDTH["arterial"]) * 0.25
		for marking_road in marking_roads:
			var points: Array[Vector2] = marking_road["points"]
			_append_dashed_line(mesh, points, -lane_offset, 6.0, 7.0, 0.42)
			_append_dashed_line(mesh, points, lane_offset, 6.0, 7.0, 0.42)
		mesh.surface_end()
	elif road_class == "collector" and not marking_roads.is_empty():
		var collector_material := StandardMaterial3D.new()
		collector_material.albedo_color = Color("#d0d0c4")
		collector_material.roughness = 1.0
		mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, collector_material)
		for marking_road in marking_roads:
			var points: Array[Vector2] = marking_road["points"]
			_append_dashed_line(mesh, points, 0.0, 5.5, 7.0, 0.48)
		mesh.surface_end()

	var markings := MeshInstance3D.new()
	markings.name = "%sRoadDetails_%s" % [road_class.capitalize(), batch_key.replace(":", "_")]
	markings.mesh = mesh
	markings.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return markings

func _rebuild_crosswalks_if_changed() -> void:
	var signature_parts: Array[String] = []
	for junction_data in _active_junctions():
		var junction: Dictionary = junction_data["junction"]
		var road_ids: Array[String] = []
		for road in junction_data["roads"]:
			road_ids.append(str(road["id"]))
		road_ids.sort()
		signature_parts.append("%s:%s" % [str(junction["id"]), "|".join(road_ids)])
	for road in GameStore.city.get("roads", []):
		if str(road.get("status", "")) == "built":
			signature_parts.append("built:%s:%s" % [
				str(road.get("id", "")), str(road.get("class", "local"))
			])
	signature_parts.sort()
	var signature := "%d::%s" % [GameStore.city_seed, "|".join(signature_parts)]
	if signature == _crosswalk_signature:
		return
	_crosswalk_signature = signature
	_rebuild_crosswalks()

func _rebuild_crosswalks() -> void:
	for child in _crosswalks_root.get_children():
		child.queue_free()
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
	var has_crosswalks := false
	var surface_started := false
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
			if not surface_started:
				mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
				surface_started = true
			_append_crosswalk(mesh, junction_position, direction, float(ROAD_WIDTH[road_class]))
			has_crosswalks = true
	if not has_crosswalks:
		return
	mesh.surface_end()

	var instance := MeshInstance3D.new()
	instance.name = "PedestrianCrosswalks"
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_crosswalks_root.add_child(instance)

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

func _append_dashed_line(
	mesh: ImmediateMesh,
	points: Array[Vector2],
	lateral_offset: float,
	dash_length: float,
	gap_length: float,
	marking_width: float
) -> void:
	var total_length := _polyline_length(points)
	var end_distance := total_length - 12.0
	var distance := 12.0
	while distance < end_distance:
		var dash_end := minf(distance + dash_length, end_distance)
		var start := _point_on_polyline(points, distance)
		var finish := _point_on_polyline(points, dash_end)
		var direction := (finish - start).normalized()
		if direction.length_squared() > 0.0:
			var across := Vector2(-direction.y, direction.x)
			start += across * lateral_offset
			finish += across * lateral_offset
			var half_width := across * marking_width * 0.5
			var left_start := start + half_width
			var right_start := start - half_width
			var left_end := finish + half_width
			var right_end := finish - half_width
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
			_junction_style_color(visible_roads, SIDEWALK_COLOR, Color("#6e736c")),
			SIDEWALK_SURFACE_HEIGHT
		)
		_add_junction_patch(
			junction_position,
			road_arms,
			_junction_style_color(visible_roads, ROAD_COLOR, Color("#40433f")),
			ROAD_SURFACE_HEIGHT
		)

func _junction_style_color(
	roads: Dictionary,
	palette: Dictionary,
	fallback: Color
) -> Color:
	var priority := ["arterial", "collector", "local", "service"]
	for road_class in priority:
		for road in roads.values():
			if str(road.get("class", "local")) == road_class:
				return palette.get(road_class, fallback)
	return fallback

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
			_foundations_dirty = true

		_update_building(entry, building)

	for building_id in _building_cache.keys():
		if not live.has(building_id):
			var entry: Dictionary = _building_cache[building_id]
			var node: Node = entry.get("root")
			if node:
				node.queue_free()
			_building_cache.erase(building_id)
			_foundations_dirty = true

	_sync_foundations()


func _sync_player_service_buildings() -> void:
	var live: Dictionary = {}
	for facility_value in GameStore.city.get("service_buildings", []):
		if typeof(facility_value) != TYPE_DICTIONARY:
			continue
		var facility: Dictionary = facility_value
		if str(facility.get("source", "")) != "player":
			continue
		var facility_id := str(facility.get("id", ""))
		if facility_id.is_empty():
			continue
		live[facility_id] = true
		var signature := _player_service_building_signature(facility)
		var previous: Dictionary = _service_building_cache.get(facility_id, {})
		if not previous.is_empty() and str(previous.get("signature", "")) == signature:
			continue
		if not previous.is_empty():
			var old_node: Node = previous.get("root")
			if old_node:
				old_node.queue_free()
			_service_building_cache.erase(facility_id)
		var root := _create_player_service_building(facility)
		_service_buildings_root.add_child(root)
		_service_building_cache[facility_id] = {"signature": signature, "root": root}

	for facility_id in _service_building_cache.keys():
		if live.has(facility_id):
			continue
		var entry: Dictionary = _service_building_cache[facility_id]
		var node: Node = entry.get("root")
		if node:
			node.queue_free()
		_service_building_cache.erase(facility_id)


func _player_service_building_signature(facility: Dictionary) -> String:
	return "%s|%s|%.3f|%.3f|%s|%.2f|%.2f" % [
		str(facility.get("service", "")),
		str(facility.get("settlementId", facility.get("districtId", ""))),
		float(facility.get("x", 0.0)),
		float(facility.get("y", 0.0)),
		str(facility.get("status", "operational")),
		float(facility.get("condition", 1.0)),
		float(facility.get("capacity", 0.0)),
	]


func _create_player_service_building(facility: Dictionary) -> Node3D:
	var facility_id := str(facility.get("id", "service-building"))
	var service_type := str(facility.get("service", "healthcare"))
	var center_x := float(facility.get("x", 0.0))
	var center_z := float(facility.get("y", 0.0))
	var settlement_id := str(facility.get("settlementId", facility.get("districtId", "")))
	var stable_hash := _service_visual_hash("%s|%s|%s" % [facility_id, service_type, settlement_id])
	var angle := float(stable_hash % 6283) / 1000.0
	var radius := 22.0 + float((stable_hash / 6283) % 19)
	center_x += cos(angle) * radius
	center_z += sin(angle) * radius

	var root := Node3D.new()
	root.name = "PlayerService_%s" % facility_id.validate_node_name()
	var ground := TerrainSurface.height(GameStore.city_seed, center_x, center_z)
	root.position = Vector3(center_x, ground, center_z)
	var colors := _service_visual_colors(service_type)
	var primary: Color = colors[0]
	var secondary: Color = colors[1]
	var roof: Color = colors[2]
	var under_construction := str(facility.get("status", "operational")) in ["planned", "queued", "under_construction", "constructing"]
	var opacity := 0.72 if under_construction else 1.0

	# A raised plinth keeps the small civic assets readable against varied terrain.
	_service_add_box(root, "Plinth", Vector3(0.0, 1.0, 0.0), Vector3(46.0, 2.0, 34.0), Color("#77796e"), opacity)
	match service_type:
		"healthcare":
			_service_add_box(root, "Clinic", Vector3(0.0, 8.0, 0.0), Vector3(38.0, 12.0, 27.0), primary, opacity)
			_service_add_box(root, "ClinicWing", Vector3(-12.0, 13.0, 1.0), Vector3(16.0, 10.0, 24.0), secondary, opacity)
			_service_add_box(root, "Roof", Vector3(1.0, 14.3, 0.0), Vector3(40.0, 1.4, 29.0), roof, opacity)
			_service_add_box(root, "MedicalCrossH", Vector3(0.0, 23.0, 14.1), Vector3(8.0, 2.2, 0.8), Color("#f5f3e8"), opacity)
			_service_add_box(root, "MedicalCrossV", Vector3(0.0, 23.0, 14.7), Vector3(2.2, 8.0, 0.8), Color("#f5f3e8"), opacity)
		"education":
			_service_add_box(root, "School", Vector3(0.0, 7.0, 0.0), Vector3(40.0, 10.0, 28.0), primary, opacity)
			_service_add_box(root, "SchoolWing", Vector3(-12.0, 12.0, 0.0), Vector3(18.0, 8.0, 24.0), secondary, opacity)
			_service_add_box(root, "SchoolRoof", Vector3(1.0, 12.6, 0.0), Vector3(42.0, 1.2, 30.0), roof, opacity)
			_service_add_box(root, "BellTower", Vector3(14.0, 19.0, -6.0), Vector3(8.0, 16.0, 8.0), secondary, opacity)
			_service_add_cone(root, "BellTowerCap", Vector3(14.0, 29.0, -6.0), 6.0, 7.0, roof, opacity)
		"fire":
			_service_add_box(root, "FireHall", Vector3(0.0, 7.0, 0.0), Vector3(42.0, 10.0, 29.0), primary, opacity)
			_service_add_box(root, "FireRoof", Vector3(0.0, 12.8, 0.0), Vector3(44.0, 1.4, 31.0), roof, opacity)
			for bay_index in range(3):
				_service_add_box(root, "BayDoor%d" % bay_index, Vector3(-12.0 + bay_index * 12.0, 5.2, 14.7), Vector3(8.5, 7.0, 0.7), Color("#3d4342"), opacity)
			_service_add_box(root, "WatchTower", Vector3(16.0, 17.0, -9.0), Vector3(8.0, 18.0, 9.0), secondary, opacity)
			_service_add_box(root, "Siren", Vector3(16.0, 27.0, -9.0), Vector3(4.0, 2.0, 4.0), Color("#f2c35e"), opacity)
		"police":
			_service_add_box(root, "Station", Vector3(0.0, 7.0, 0.0), Vector3(38.0, 10.0, 27.0), primary, opacity)
			_service_add_box(root, "StationWing", Vector3(13.0, 11.0, -2.0), Vector3(16.0, 8.0, 24.0), secondary, opacity)
			_service_add_box(root, "StationRoof", Vector3(1.0, 12.8, 0.0), Vector3(40.0, 1.4, 29.0), roof, opacity)
			_service_add_box(root, "FlagPost", Vector3(-13.0, 19.0, 14.0), Vector3(1.0, 12.0, 1.0), Color("#e5e0d1"), opacity)
			_service_add_box(root, "Flag", Vector3(-10.0, 24.0, 14.0), Vector3(5.0, 2.8, 0.6), Color("#70a6cf"), opacity)
		"waste":
			_service_add_box(root, "Works", Vector3(0.0, 6.0, 0.0), Vector3(42.0, 8.0, 29.0), primary, opacity)
			_service_add_box(root, "WorksRoof", Vector3(0.0, 10.8, 0.0), Vector3(44.0, 1.2, 31.0), roof, opacity)
			_service_add_cylinder(root, "RecyclingSiloA", Vector3(-12.0, 12.0, -8.0), 5.2, 14.0, secondary, opacity)
			_service_add_cylinder(root, "RecyclingSiloB", Vector3(0.0, 12.0, -8.0), 5.2, 14.0, secondary, opacity)
			_service_add_cylinder(root, "RecyclingSiloC", Vector3(12.0, 12.0, -8.0), 5.2, 14.0, secondary, opacity)
		"recreation":
			_service_add_box(root, "CommunityHall", Vector3(0.0, 6.0, 0.0), Vector3(30.0, 8.0, 22.0), primary, opacity)
			_service_add_prism(root, "PavilionRoof", Vector3(0.0, 12.0, 0.0), Vector3(35.0, 6.0, 27.0), roof, opacity)
			_service_add_box(root, "Court", Vector3(0.0, 1.4, 24.0), Vector3(27.0, 0.8, 15.0), Color("#7d9872"), opacity)
			_service_add_tree(root, "ParkTreeA", Vector3(-17.0, 0.0, -14.0), secondary, opacity)
			_service_add_tree(root, "ParkTreeB", Vector3(19.0, 0.0, 15.0), secondary, opacity)
		_:
			_service_add_box(root, "CivicBuilding", Vector3(0.0, 7.0, 0.0), Vector3(38.0, 10.0, 27.0), primary, opacity)
			_service_add_box(root, "CivicRoof", Vector3(0.0, 12.8, 0.0), Vector3(40.0, 1.4, 29.0), roof, opacity)
	return root


func _service_visual_colors(service_type: String) -> Array[Color]:
	match service_type:
		"healthcare":
			return [Color("#bacac7"), Color("#759ea2"), Color("#e7e7da")]
		"education":
			return [Color("#bb9b78"), Color("#d2b895"), Color("#55483d")]
		"fire":
			return [Color("#b65c4c"), Color("#d18460"), Color("#49413c")]
		"police":
			return [Color("#768ea0"), Color("#9aabb0"), Color("#424e55")]
		"waste":
			return [Color("#758b6b"), Color("#a2ad82"), Color("#555c4b")]
		"recreation":
			return [Color("#d2c39e"), Color("#879b74"), Color("#a95f42")]
	return [Color("#a4aaa9"), Color("#8f9b97"), Color("#555d59")]


func _service_visual_hash(value: String) -> int:
	var result := 17
	for character in value:
		result = posmod(result * 31 + character.unicode_at(0), 2147483647)
	return result


func _service_material(color: Color, opacity: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color.r, color.g, color.b, opacity)
	material.roughness = 0.9
	if opacity < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _service_add_box(
	parent: Node3D,
	part_name: String,
	center: Vector3,
	size: Vector3,
	color: Color,
	opacity: float
) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _service_material(color, opacity)
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.position = center
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)


func _service_add_cylinder(
	parent: Node3D,
	part_name: String,
	center: Vector3,
	radius: float,
	height: float,
	color: Color,
	opacity: float
) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 10
	mesh.material = _service_material(color, opacity)
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.position = center
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)


func _service_add_cone(
	parent: Node3D,
	part_name: String,
	center: Vector3,
	radius: float,
	height: float,
	color: Color,
	opacity: float
) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.2
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 8
	mesh.material = _service_material(color, opacity)
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.position = center
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)


func _service_add_prism(
	parent: Node3D,
	part_name: String,
	center: Vector3,
	size: Vector3,
	color: Color,
	opacity: float
) -> void:
	var mesh := PrismMesh.new()
	mesh.size = size
	mesh.material = _service_material(color, opacity)
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.position = center
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)


func _service_add_tree(parent: Node3D, tree_name: String, center: Vector3, foliage: Color, opacity: float) -> void:
	_service_add_cylinder(parent, "%sTrunk" % tree_name, center + Vector3(0.0, 3.0, 0.0), 1.4, 6.0, Color("#685644"), opacity)
	_service_add_cone(parent, "%sCrown" % tree_name, center + Vector3(0.0, 10.0, 0.0), 5.5, 12.0, foliage, opacity)

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
	if not _foundations_dirty:
		return

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
		_foundations_dirty = false
		return
	_foundation_signature = signature
	_foundation_multimesh.instance_count = instances.size()
	for index in range(instances.size()):
		_foundation_multimesh.set_instance_transform(index, instances[index])
	_foundations_dirty = false

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
	var center_ground := TerrainSurface.height(GameStore.city_seed, x, z)
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
