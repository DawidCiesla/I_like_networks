extends Node3D

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const RoadGeometry = preload("res://scripts/render/road_geometry.gd")
const TramCatenaryLayout = preload("res://scripts/render/tram_catenary_layout.gd")
const TramPantographMesh = preload("res://scripts/render/tram_pantograph_mesh.gd")
const MetroSurfaceFeatures = preload("res://scripts/render/metro_surface_features.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")
const TransitModes = preload("res://scripts/transport/transit_modes.gd")

const METRO_CUTAWAY_HALF_WIDTH := 8.4
const METRO_CUTAWAY_MAX_TEXTURE_EDGE := 2048

var _static_root: Node3D
var _selection_root: Node3D
var _bus_root: Node3D
var _bus_meshes: Dictionary = {}
var _bus_model_mesh: ArrayMesh
var _mode_vehicle_meshes: Dictionary = {}
var _bus_details_material: StandardMaterial3D
var _tram_contact_material: StandardMaterial3D
var _tram_catenary_support_material: StandardMaterial3D
var _tram_catenary_wire_material: StandardMaterial3D
var _station_mesh_cache: Dictionary = {}
var _metro_station_mesh_cache: Dictionary = {}
var _tram_shelter_mesh_cache: Dictionary = {}
var _metro_vent_mesh_cache: Dictionary = {}
var _metro_cutaway_material: ShaderMaterial
var _metro_cutaway_terrain: MeshInstance3D
var _metro_cutaway_original_override: Material
var _metro_cutaway_original_override_captured := false
var _station_body_material_cache: Dictionary = {}
var _station_details_material_cache: Dictionary = {}
var _signature := ""

func _ready() -> void:
	_static_root = Node3D.new()
	_static_root.name = "StaticNetwork"
	add_child(_static_root)

	_selection_root = Node3D.new()
	_selection_root.name = "NetworkSelection"
	add_child(_selection_root)

	_bus_root = Node3D.new()
	_bus_root.name = "Buses"
	add_child(_bus_root)

	GameStore.state_changed.connect(_on_state_changed)
	GameStore.terrain_changed.connect(_on_terrain_changed)
	GameStore.selection_changed.connect(_on_selection_changed)
	rebuild()
	_rebuild_selection_overlay()

func _process(_delta: float) -> void:
	_update_buses()

func _on_state_changed() -> void:
	var next_signature := _visual_signature()
	if next_signature == _signature:
		return
	rebuild()

func _on_terrain_changed() -> void:
	_signature = ""
	rebuild()

func _on_selection_changed(_selection: String) -> void:
	_rebuild_selection_overlay()

func _rebuild_selection_overlay() -> void:
	if _selection_root == null:
		return
	for child in _selection_root.get_children():
		child.queue_free()

	var selection := GameStore.selected
	if not selection.begins_with("free_stop:"):
		return
	var stop_id := selection.trim_prefix("free_stop:")
	var stop := GameStore.transit_stop(stop_id)
	if stop.is_empty():
		return
	var point := Vector2(
		float(stop.get("x", 0.0)),
		float(stop.get("y", 0.0))
	)
	var stats := GameStore.custom_stop_catchment(stop_id)
	var radius := float(
		stats.get("radius", TransitNetwork.DEFAULT_CATCHMENT_RADIUS)
	)

	var disk_instance := MeshInstance3D.new()
	var disk := CylinderMesh.new()
	disk.top_radius = radius
	disk.bottom_radius = radius
	disk.height = 0.20
	disk.radial_segments = 56
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.20, 0.62, 0.96, 0.10)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disk.material = material
	disk_instance.mesh = disk
	disk_instance.position = Vector3(
		point.x,
		TerrainSurface.height(GameStore.city_seed, point.x, point.y) + 0.12,
		point.y
	)
	disk_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_selection_root.add_child(disk_instance)

	var label := Label3D.new()
	label.text = "%d BUILDINGS · %.1f PAX/MIN" % [
		int(stats.get("building_count", 0)),
		float(stats.get("demand_ppm", 0.0)),
	]
	label.position = Vector3(
		point.x,
		TerrainSurface.height(GameStore.city_seed, point.x, point.y) + 24.0,
		point.y
	)
	label.font_size = 24
	label.outline_size = 7
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_selection_root.add_child(label)

func _visual_signature() -> String:
	var parts: Array[String] = []
	for line_key in Data.LINE_KEYS:
		var line: Dictionary = GameStore.lines[line_key]
		parts.append("%s:%s:%s" % [line_key, line.built, line.stop_count])
	for station_id in Data.all_station_ids():
		parts.append("%s:%d" % [station_id, GameStore.station_level(station_id)])

	var network_lines: Dictionary = GameStore.transit_network.get("lines", {})
	for line_id in TransitNetwork.custom_line_ids(GameStore.transit_network):
		var custom_line: Dictionary = network_lines.get(line_id, {})
		parts.append("%s:%s:%s:%s:%s:%d" % [
			line_id,
			custom_line.get("status", ""),
			custom_line.get("stop_ids", []),
			custom_line.get("route_length_world", 0.0),
			custom_line.get("mode", "bus"),
			hash(custom_line.get("route_points", [])),
		])
	var network_stops: Dictionary = GameStore.transit_network.get("stops", {})
	for stop_id_value in network_stops.keys():
		var stop_id := str(stop_id_value)
		var stop: Dictionary = network_stops[stop_id]
		if str(stop.get("source", "")) != "custom":
			continue
		parts.append("%s:%.2f:%.2f:%d" % [
			stop_id,
			float(stop.get("x", 0.0)),
			float(stop.get("y", 0.0)),
			int(stop.get("level", 0)),
		])
	for settlement_value in GameStore.city.get("regional_settlements", []):
		if not (settlement_value is Dictionary):
			continue
		var settlement: Dictionary = settlement_value
		var position := _settlement_position(settlement)
		parts.append("settlement:%s:%.2f:%.2f:%d" % [
			str(settlement.get("id", "")),
			position.x,
			position.y,
			int(settlement.get("population", 0)),
		])

	var depot_position: Variant = GameStore.depot.get("position", null)
	parts.append("depot:%s:%s" % [GameStore.depot.built, str(depot_position)])
	return "|".join(parts)

func rebuild() -> void:
	_signature = _visual_signature()
	for child in _static_root.get_children():
		child.queue_free()

	var rendered_stations: Dictionary = {}

	for line_key in Data.LINE_KEYS:
		var line: Dictionary = GameStore.lines[line_key]
		if bool(line.built):
			var route := Layout.built_route(line_key, int(line.stop_count))
			_add_ribbon(route, 3.8, Data.LINE_COLORS[line_key], 0.13, true)

		for stop_index in range(int(line.stop_count)):
			var station_id: String = Data.STATION_IDS[line_key][stop_index]
			if rendered_stations.has(station_id):
				continue
			_add_station(station_id, line_key, stop_index, false, "")
			rendered_stations[station_id] = true

		if int(line.stop_count) > 0 and int(line.stop_count) < int(Data.LINE_CONFIG[line_key].max_stops):
			var future := Layout.future_segment(line_key, int(line.stop_count))
			_add_ribbon(future, 14.0, Color(0.35, 0.37, 0.35, 0.38), 0.09, false)
			_add_ribbon(future, 3.2, Color(Data.LINE_COLORS[line_key], 0.48), 0.13, true)
			var station_id: String = Data.STATION_IDS[line_key][int(line.stop_count)]
			_add_station(
				station_id,
				line_key,
				int(line.stop_count),
				true,
				"future_stop:%s" % line_key
			)

	for line_key in ["line2", "line3", "line4"]:
		if bool(GameStore.lines[line_key].built) or not GameStore.can_unlock_line(line_key):
			continue
		var future := Layout.segment_points(line_key, 0)
		_add_ribbon(future, 3.2, Color(Data.LINE_COLORS[line_key], 0.42), 0.13, true)
		var station_id: String = Data.STATION_IDS[line_key][1]
		_add_station(station_id, line_key, 1, true, "future_line:%s" % line_key)

	var network_lines: Dictionary = GameStore.transit_network.get("lines", {})
	var metro_routes: Array[Dictionary] = []
	for line_id in TransitNetwork.custom_line_ids(GameStore.transit_network):
		var custom_line: Dictionary = network_lines.get(line_id, {})
		if str(custom_line.get("status", "")) != "active":
			continue
		var transit_mode := str(custom_line.get("mode", "bus"))
		var route := TransitNetwork.line_route_points(GameStore.transit_network, line_id)
		if route.size() >= 2:
			if transit_mode == "tram":
				_add_tram_track_corridor(route)
				_add_tram_crossings(route)
				_add_tram_overhead(line_id, route)
			elif transit_mode == "metro":
				_add_metro_tunnel(route)
				_add_metro_surface_trace(line_id, route)
				_add_metro_ventilation(line_id, route)
				metro_routes.append({"line_id": line_id, "route": route.duplicate()})
			else:
				_add_ribbon(route, 4.2, _line_color(line_id), 0.145, true)
		for stop_id in TransitNetwork.line_stop_ids(GameStore.transit_network, line_id):
			if rendered_stations.has(stop_id):
				continue
			_add_free_station(stop_id, line_id, route)
			rendered_stations[stop_id] = true
	_update_metro_cutaway(metro_routes)

	if GameStore.is_sandbox():
		for settlement_value in GameStore.city.get("regional_settlements", []):
			if settlement_value is Dictionary:
				_add_settlement_marker(settlement_value)
		if bool(GameStore.depot.get("built", false)):
			_add_depot(false)
	elif bool(GameStore.depot.built) or GameStore.can_build_depot():
		_add_depot(not bool(GameStore.depot.built))
	_rebuild_selection_overlay()


func _settlement_position(settlement: Dictionary) -> Vector2:
	var position_value: Variant = settlement.get("position", Vector2.ZERO)
	if position_value is Vector2:
		return position_value
	if typeof(position_value) == TYPE_DICTIONARY:
		var raw: Dictionary = position_value
		return Vector2(float(raw.get("x", 0.0)), float(raw.get("y", 0.0)))
	return Vector2.ZERO


func _add_settlement_marker(settlement: Dictionary) -> void:
	var settlement_id := str(settlement.get("id", ""))
	if settlement_id.is_empty():
		return
	var point := _settlement_position(settlement)
	var y := TerrainSurface.height(GameStore.city_seed, point.x, point.y)
	var color := Color("#78cbd5")
	match str(settlement.get("tier", "village")):
		"capital":
			color = Color("#91dfeb")
		"market":
			color = Color("#e5bd73")

	var area := Area3D.new()
	area.name = "Settlement_%s" % settlement_id
	area.position = Vector3(point.x, y + 1.6, point.y)
	area.input_ray_pickable = true
	area.set_meta("selection", "settlement:%s" % settlement_id)
	var collision := CollisionShape3D.new()
	var collision_shape := CylinderShape3D.new()
	collision_shape.radius = 36.0
	collision_shape.height = 13.0
	collision.shape = collision_shape
	area.add_child(collision)

	var marker := MeshInstance3D.new()
	var marker_mesh := CylinderMesh.new()
	marker_mesh.top_radius = 12.0
	marker_mesh.bottom_radius = 27.0
	marker_mesh.height = 1.5
	marker_mesh.radial_segments = 18
	var marker_material := StandardMaterial3D.new()
	marker_material.albedo_color = color
	marker_material.roughness = 0.58
	marker_material.emission_enabled = true
	marker_material.emission = color.darkened(0.44)
	marker_material.emission_energy_multiplier = 0.16
	marker_mesh.material = marker_material
	marker.mesh = marker_mesh
	marker.position.y = 0.8
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	area.add_child(marker)

	var label := Label3D.new()
	label.text = "%s\n%d RESIDENTS" % [
		str(settlement.get("name", settlement_id)).to_upper(),
		maxi(0, int(settlement.get("population", 0))),
	]
	label.position.y = 13.0
	label.font_size = 22
	label.outline_size = 6
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	area.add_child(label)
	area.input_event.connect(_on_pick.bind(area))
	_static_root.add_child(area)

func _add_ribbon(
	points: Array[Vector2],
	width: float,
	color: Color,
	height_offset: float,
	emissive: bool
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
		true,
		emissive,
		0.32
	)
	if mesh == null:
		return

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_static_root.add_child(instance)


func _offset_polyline(points: Array[Vector2], offset: float) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for index in range(points.size()):
		var before := points[maxi(0, index - 1)]
		var after := points[mini(points.size() - 1, index + 1)]
		var tangent := (after - before).normalized()
		var normal := Vector2(-tangent.y, tangent.x)
		result.append(points[index] + normal * offset)
	return result


func _add_tram_track_corridor(route: Array[Vector2]) -> void:
	# Keep the tram in the road corridor: the broad, quiet base sits just above
	# the street while the finer rails and sleepers carry the track detail.
	_add_ribbon(route, 5.8, Color("#454a46"), 0.10, false)
	_add_ribbon(route, 3.8, Color("#79796d"), 0.17, false)
	_add_tram_sleepers(route)
	for side in [-1.0, 1.0]:
		var rail_path := _offset_polyline(route, side * 1.35)
		_add_ribbon(rail_path, 0.48, Color("#737c79"), 0.25, false)
		_add_ribbon(rail_path, 0.17, Color("#c2c9c1"), 0.34, true)


func _add_tram_overhead(line_id: String, route: Array[Vector2]) -> void:
	var layout := TramCatenaryLayout.build_layout(route)
	var poles: Array = layout.get("pole_frames", [])
	var spans: Array = layout.get("spans", [])
	if poles.size() < 2 or spans.is_empty():
		return

	var mesh := ArrayMesh.new()
	var support_tool := SurfaceTool.new()
	support_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var unit_box := BoxMesh.new()
	unit_box.size = Vector3.ONE
	for frame_value in poles:
		var frame: Dictionary = frame_value
		var point: Vector2 = frame.get("point", Vector2.ZERO)
		var normal: Vector2 = frame.get("normal", Vector2.UP)
		var side := float(frame.get("side", 1.0))
		var support_point := point + normal * side * 7.2
		var support_ground := TerrainSurface.height(
			GameStore.city_seed, support_point.x, support_point.y
		)
		var contact_y := TerrainSurface.height(
			GameStore.city_seed, point.x, point.y
		) + 6.55
		var pole_height := maxf(7.15, contact_y - support_ground + 0.7)
		var pole_top_y := support_ground + pole_height
		_append_tram_overhead_box(
			support_tool,
			unit_box,
			Vector3(0.42, pole_height, 0.42),
			Transform3D(
				Basis.IDENTITY,
				Vector3(support_point.x, support_ground + pole_height * 0.5, support_point.y)
			)
		)

		var toward_track := Vector3(-normal.x * side, 0.0, -normal.y * side).normalized()
		var axis_z := toward_track.cross(Vector3.UP).normalized()
		if axis_z.length_squared() <= 0.000001:
			axis_z = Vector3.FORWARD
		var horizontal_basis := Basis(toward_track, Vector3.UP, axis_z)
		var crossarm_length := support_point.distance_to(point) + 1.0
		var crossarm_center := Vector3(
			lerpf(support_point.x, point.x, 0.5),
			lerpf(pole_top_y, contact_y + 0.35, 0.5),
			lerpf(support_point.y, point.y, 0.5)
		)
		_append_tram_overhead_box(
			support_tool,
			unit_box,
			Vector3(crossarm_length, 0.24, 0.28),
			Transform3D(horizontal_basis, crossarm_center)
		)
		_append_tram_overhead_box(
			support_tool,
			unit_box,
			Vector3(0.48, 0.40, 0.42),
			Transform3D(Basis.IDENTITY, Vector3(point.x, contact_y + 0.15, point.y))
		)
	support_tool.commit(mesh)

	var wire_tool := SurfaceTool.new()
	wire_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cable_box := BoxMesh.new()
	cable_box.size = Vector3.ONE
	for span_value in spans:
		var samples: Array = span_value
		var previous_contact := Vector3.ZERO
		var previous_messenger := Vector3.ZERO
		for sample_index in range(samples.size()):
			var sample: Dictionary = samples[sample_index]
			var point: Vector2 = sample.get("point", Vector2.ZERO)
			var t := float(sample.get("span_t", 0.0))
			var ground := TerrainSurface.height(GameStore.city_seed, point.x, point.y)
			var sag := 0.22 * 4.0 * t * (1.0 - t)
			var contact := Vector3(point.x, ground + 6.55 - sag, point.y)
			var messenger := Vector3(point.x, ground + 7.30 - sag * 0.72, point.y)
			if sample_index > 0:
				_append_tram_cable_segment(wire_tool, cable_box, previous_contact, contact, 0.105)
				_append_tram_cable_segment(wire_tool, cable_box, previous_messenger, messenger, 0.075)
				if sample_index % 2 == 0:
					_append_tram_cable_segment(wire_tool, cable_box, contact, messenger, 0.055)
			previous_contact = contact
			previous_messenger = messenger
	wire_tool.commit(mesh)

	if mesh.get_surface_count() < 2:
		return
	if _tram_catenary_support_material == null:
		_tram_catenary_support_material = StandardMaterial3D.new()
		_tram_catenary_support_material.albedo_color = Color("#56605e")
		_tram_catenary_support_material.roughness = 0.8
	if _tram_catenary_wire_material == null:
		_tram_catenary_wire_material = StandardMaterial3D.new()
		_tram_catenary_wire_material.albedo_color = Color("#b8ad86")
		_tram_catenary_wire_material.roughness = 0.42
		_tram_catenary_wire_material.metallic = 0.38
	mesh.surface_set_material(0, _tram_catenary_support_material)
	mesh.surface_set_material(1, _tram_catenary_wire_material)
	var instance := MeshInstance3D.new()
	instance.name = "TramCatenary_%s" % line_id
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_static_root.add_child(instance)


func _append_tram_overhead_box(
	surface: SurfaceTool,
	unit_box: BoxMesh,
	size: Vector3,
	transform: Transform3D
) -> void:
	var scaled_basis := Basis(
		transform.basis.x * size.x,
		transform.basis.y * size.y,
		transform.basis.z * size.z
	)
	surface.append_from(
		unit_box,
		0,
		Transform3D(scaled_basis, transform.origin)
	)


func _append_tram_cable_segment(
	surface: SurfaceTool,
	unit_box: BoxMesh,
	start: Vector3,
	finish: Vector3,
	thickness: float
) -> void:
	var direction := finish - start
	var length := direction.length()
	if length <= 0.000001:
		return
	var axis_z := direction / length
	var axis_x := Vector3.UP.cross(axis_z).normalized()
	if axis_x.length_squared() <= 0.000001:
		axis_x = Vector3.RIGHT
	var axis_y := axis_z.cross(axis_x).normalized()
	var basis := Basis(
		axis_x * thickness,
		axis_y * thickness,
		axis_z * length
	)
	surface.append_from(unit_box, 0, Transform3D(basis, (start + finish) * 0.5))


func _add_tram_sleepers(route: Array[Vector2]) -> void:
	var samples := RoadGeometry.resample_polyline(route, 13.0)
	if samples.size() < 2:
		return
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#5e625b")
	material.roughness = 0.95
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
	for index in range(0, samples.size(), 2):
		var before: Vector2 = samples[maxi(0, index - 1)]
		var after: Vector2 = samples[mini(samples.size() - 1, index + 1)]
		var tangent := (after - before).normalized()
		if tangent.length_squared() <= 0.000001:
			continue
		var normal := Vector2(-tangent.y, tangent.x)
		var center: Vector2 = samples[index]
		var along := tangent * 0.38
		var across := normal * 2.05
		var a := center - along - across
		var b := center + along - across
		var c := center - along + across
		var d := center + along + across
		RoadGeometry.append_triangle_above_terrain(mesh, GameStore.city_seed, a, b, c, 0.22)
		RoadGeometry.append_triangle_above_terrain(mesh, GameStore.city_seed, c, b, d, 0.22)
	mesh.surface_end()
	var sleepers := MeshInstance3D.new()
	sleepers.name = "TramSleepers"
	sleepers.mesh = mesh
	sleepers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_static_root.add_child(sleepers)


func _add_tram_crossings(route: Array[Vector2]) -> void:
	var built_roads: Dictionary = {}
	for road_value in GameStore.city.get("roads", []):
		if not (road_value is Dictionary):
			continue
		var road: Dictionary = road_value
		if str(road.get("status", "")) == "built":
			built_roads[str(road.get("id", ""))] = true

	var crossing_frames: Array[Dictionary] = []
	for junction_value in GameStore.city.get("junctions", []):
		if not (junction_value is Dictionary):
			continue
		var junction: Dictionary = junction_value
		var road_ids: Array = junction.get("roadIds", [])
		var built_road_count := 0
		for road_id in road_ids:
			if built_roads.has(str(road_id)):
				built_road_count += 1
		if built_road_count < 2:
			continue
		var junction_point := Vector2(
			float(junction.get("x", 0.0)),
			float(junction.get("y", 0.0))
		)
		var frame := _closest_route_frame(junction_point, route)
		if frame.is_empty() or float(frame.get("distance", INF)) > 7.0:
			continue
		crossing_frames.append(frame)
	if crossing_frames.is_empty():
		return

	# Batch all crossing bars for this line into one terrain-conformed surface.
	# Junction count therefore adds vertices, not scene nodes or draw calls.
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#d2c9b4")
	material.roughness = 0.96
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
	for frame in crossing_frames:
		var tangent: Vector2 = frame["tangent"]
		var across := Vector2(-tangent.y, tangent.x)
		var center: Vector2 = frame["point"]
		for along_offset in [-1.45, 1.45]:
			var bar_center: Vector2 = center + tangent * float(along_offset)
			var half_bar_width := tangent * 0.36
			var half_bar_length := across * 3.1
			var a := bar_center - half_bar_width - half_bar_length
			var b := bar_center + half_bar_width - half_bar_length
			var c := bar_center - half_bar_width + half_bar_length
			var d := bar_center + half_bar_width + half_bar_length
			RoadGeometry.append_triangle_above_terrain(
				mesh, GameStore.city_seed, a, b, c, 0.43
			)
			RoadGeometry.append_triangle_above_terrain(
				mesh, GameStore.city_seed, c, b, d, 0.43
			)
	mesh.surface_end()
	var instance := MeshInstance3D.new()
	instance.name = "TramCrossings"
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_static_root.add_child(instance)


func _closest_route_frame(point: Vector2, route: Array[Vector2]) -> Dictionary:
	var best_distance := INF
	var best_point := Vector2.ZERO
	var best_tangent := Vector2.ZERO
	for index in range(route.size() - 1):
		var start: Vector2 = route[index]
		var finish: Vector2 = route[index + 1]
		var segment := finish - start
		if segment.length_squared() <= 0.000001:
			continue
		var t := clampf((point - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
		var projection := start + segment * t
		var distance := point.distance_to(projection)
		if distance >= best_distance:
			continue
		best_distance = distance
		best_point = projection
		best_tangent = segment.normalized()
	if best_tangent.length_squared() <= 0.000001:
		return {}
	return {
		"distance": best_distance,
		"point": best_point,
		"tangent": best_tangent,
	}


func _update_metro_cutaway(metro_routes: Array[Dictionary]) -> void:
	var terrain := get_parent().get_node_or_null("Terrain") as MeshInstance3D
	if terrain == null:
		return
	if not _metro_cutaway_original_override_captured or _metro_cutaway_terrain != terrain:
		_metro_cutaway_terrain = terrain
		_metro_cutaway_original_override = terrain.material_override
		_metro_cutaway_original_override_captured = true
	if metro_routes.is_empty():
		terrain.material_override = _metro_cutaway_original_override
		return

	var bounds := TerrainSurface.world_bounds()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	var texture_size := Vector2i(
		clampi(ceili(bounds.size.x / 4.0), 64, METRO_CUTAWAY_MAX_TEXTURE_EDGE),
		clampi(ceili(bounds.size.y / 4.0), 64, METRO_CUTAWAY_MAX_TEXTURE_EDGE)
	)
	var mask := Image.create(texture_size.x, texture_size.y, false, Image.FORMAT_R8)
	mask.fill(Color.BLACK)
	var scale_x := float(texture_size.x - 1) / bounds.size.x
	var scale_y := float(texture_size.y - 1) / bounds.size.y
	for route_data in metro_routes:
		var route: Array[Vector2] = route_data.get("route", [])
		_stamp_metro_cutaway_route(mask, bounds, scale_x, scale_y, route)

	var texture := ImageTexture.create_from_image(mask)
	if _metro_cutaway_material == null:
		_metro_cutaway_material = _create_metro_cutaway_material()
	_metro_cutaway_material.set_shader_parameter("metro_cutaway_mask", texture)
	_metro_cutaway_material.set_shader_parameter(
		"world_origin",
		Vector2(bounds.position.x, bounds.position.y)
	)
	_metro_cutaway_material.set_shader_parameter(
		"world_size",
		Vector2(bounds.size.x, bounds.size.y)
	)
	terrain.material_override = _metro_cutaway_material


func _create_metro_cutaway_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
uniform sampler2D metro_cutaway_mask : filter_linear, repeat_disable;
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
varying vec2 terrain_world_xz;

void vertex() {
	terrain_world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 mask_uv = (terrain_world_xz - world_origin) / world_size;
	if (mask_uv.x >= 0.0 && mask_uv.x <= 1.0 && mask_uv.y >= 0.0 && mask_uv.y <= 1.0) {
		if (texture(metro_cutaway_mask, mask_uv).r > 0.48) {
			discard;
		}
	}
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


func _stamp_metro_cutaway_route(
	image: Image,
	bounds: Rect2,
	scale_x: float,
	scale_y: float,
	route: Array[Vector2]
) -> void:
	if route.size() < 2:
		return
	var radius_x := maxi(1, ceili(METRO_CUTAWAY_HALF_WIDTH * scale_x))
	var radius_y := maxi(1, ceili(METRO_CUTAWAY_HALF_WIDTH * scale_y))
	for index in range(route.size() - 1):
		var start := Vector2(
			(route[index].x - bounds.position.x) * scale_x,
			(route[index].y - bounds.position.y) * scale_y
		)
		var finish := Vector2(
			(route[index + 1].x - bounds.position.x) * scale_x,
			(route[index + 1].y - bounds.position.y) * scale_y
		)
		var pixel_distance := start.distance_to(finish)
		var sample_count := maxi(1, ceili(pixel_distance * 2.0))
		for sample_index in range(sample_count + 1):
			var center := start.lerp(finish, float(sample_index) / float(sample_count))
			var min_y := maxi(0, floori(center.y) - radius_y)
			var max_y := mini(image.get_height() - 1, ceili(center.y) + radius_y)
			var min_x := maxi(0, floori(center.x) - radius_x)
			var max_x := mini(image.get_width() - 1, ceili(center.x) + radius_x)
			for y in range(min_y, max_y + 1):
				var dy := (float(y) - center.y) / float(radius_y)
				for x in range(min_x, max_x + 1):
					var dx := (float(x) - center.x) / float(radius_x)
					if dx * dx + dy * dy <= 1.0:
						image.set_pixel(x, y, Color.WHITE)


func _add_metro_tunnel(route: Array[Vector2]) -> void:
	var samples := RoadGeometry.resample_polyline(route, 12.0)
	if samples.size() < 2:
		return
	var walls := ImmediateMesh.new()
	var wall_material := StandardMaterial3D.new()
	wall_material.albedo_color = Color("#343d40")
	wall_material.roughness = 0.98
	wall_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	walls.surface_begin(Mesh.PRIMITIVE_TRIANGLES, wall_material)
	for index in range(samples.size() - 1):
		var start: Vector2 = samples[index]
		var finish: Vector2 = samples[index + 1]
		var start_tangent := (samples[mini(index + 1, samples.size() - 1)] - samples[maxi(0, index - 1)]).normalized()
		var finish_tangent := (samples[mini(index + 2, samples.size() - 1)] - samples[index]).normalized()
		if start_tangent.length_squared() <= 0.000001 or finish_tangent.length_squared() <= 0.000001:
			continue
		var start_normal := Vector2(-start_tangent.y, start_tangent.x)
		var finish_normal := Vector2(-finish_tangent.y, finish_tangent.x)
		var start_left_top := start + start_normal * 8.0
		var finish_left_top := finish + finish_normal * 8.0
		var start_left_bottom := start + start_normal * 6.0
		var finish_left_bottom := finish + finish_normal * 6.0
		var start_right_top := start - start_normal * 8.0
		var finish_right_top := finish - finish_normal * 8.0
		var start_right_bottom := start - start_normal * 6.0
		var finish_right_bottom := finish - finish_normal * 6.0
		_append_metro_wall_quad(
			walls, start_left_top, finish_left_top, start_left_bottom, finish_left_bottom,
			Vector3(-start_normal.x, 0.0, -start_normal.y)
		)
		_append_metro_wall_quad(
			walls, start_right_top, finish_right_top, start_right_bottom, finish_right_bottom,
			Vector3(start_normal.x, 0.0, start_normal.y)
		)
	walls.surface_end()
	var wall_instance := MeshInstance3D.new()
	wall_instance.name = "MetroTunnelCutaway"
	wall_instance.mesh = walls
	wall_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_static_root.add_child(wall_instance)

	_add_ribbon(route, 11.8, Color("#20282b"), -9.65, false)
	_add_ribbon(route, 7.2, Color("#333d40"), -9.42, false)
	for side in [-1.0, 1.0]:
		var rail_path := _offset_polyline(route, side * 1.35)
		_add_ribbon(rail_path, 0.44, Color("#727c7d"), -8.95, false)
		_add_ribbon(rail_path, 0.14, Color("#b4c3c0"), -8.72, true)


func _add_metro_surface_trace(line_id: String, route: Array[Vector2]) -> void:
	var station_points: Array[Vector2] = []
	var stops: Dictionary = GameStore.transit_network.get("stops", {})
	for stop_id in TransitNetwork.line_stop_ids(GameStore.transit_network, line_id):
		var stop: Dictionary = stops.get(stop_id, {})
		if stop.is_empty():
			continue
		station_points.append(Vector2(
			float(stop.get("x", 0.0)),
			float(stop.get("y", 0.0))
		))
	var dashes := MetroSurfaceFeatures.route_trace_dashes(route, MetroSurfaceFeatures.DEFAULT_TRACE_OFFSET,
		MetroSurfaceFeatures.DEFAULT_DASH_LENGTH, MetroSurfaceFeatures.DEFAULT_DASH_GAP,
		MetroSurfaceFeatures.DEFAULT_STATION_CLEARANCE,
		MetroSurfaceFeatures.DEFAULT_ROUTE_SAMPLE_SPACING, station_points)
	if dashes.is_empty():
		return

	var bounds := TerrainSurface.world_bounds()
	var color := _line_color(line_id).lerp(Color("#c2c0ad"), 0.64)
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.96
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
	var half_width := MetroSurfaceFeatures.DEFAULT_TRACE_WIDTH * 0.5
	for dash_value in dashes:
		var dash: Dictionary = dash_value
		var points: Array[Vector2] = dash.get("points", [])
		for index in range(points.size() - 1):
			var start: Vector2 = points[index]
			var finish: Vector2 = points[index + 1]
			if not bounds.has_point(start) or not bounds.has_point(finish):
				continue
			var tangent := (finish - start).normalized()
			if tangent.length_squared() <= 0.000001:
				continue
			var side := Vector2(-tangent.y, tangent.x) * half_width
			var a := start - side
			var b := finish - side
			var c := start + side
			var d := finish + side
			RoadGeometry.append_triangle_above_terrain(
				mesh, GameStore.city_seed, a, b, c, 0.075
			)
			RoadGeometry.append_triangle_above_terrain(
				mesh, GameStore.city_seed, c, b, d, 0.075
			)
	mesh.surface_end()
	if mesh.get_surface_count() == 0:
		return
	var instance := MeshInstance3D.new()
	instance.name = "MetroSurfaceTrace_%s" % line_id
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_static_root.add_child(instance)


func _append_metro_wall_quad(
	mesh: ImmediateMesh,
	top_start: Vector2,
	top_end: Vector2,
	bottom_start: Vector2,
	bottom_end: Vector2,
	normal: Vector3
) -> void:
	var seed := GameStore.city_seed
	mesh.surface_set_normal(normal)
	mesh.surface_add_vertex(Vector3(
		top_start.x,
		TerrainSurface.height(seed, top_start.x, top_start.y) - 0.25,
		top_start.y
	))
	mesh.surface_set_normal(normal)
	mesh.surface_add_vertex(Vector3(
		top_end.x,
		TerrainSurface.height(seed, top_end.x, top_end.y) - 0.25,
		top_end.y
	))
	mesh.surface_set_normal(normal)
	mesh.surface_add_vertex(Vector3(
		bottom_start.x,
		TerrainSurface.height(seed, bottom_start.x, bottom_start.y) - 9.5,
		bottom_start.y
	))
	mesh.surface_set_normal(normal)
	mesh.surface_add_vertex(Vector3(
		top_end.x,
		TerrainSurface.height(seed, top_end.x, top_end.y) - 0.25,
		top_end.y
	))
	mesh.surface_set_normal(normal)
	mesh.surface_add_vertex(Vector3(
		bottom_end.x,
		TerrainSurface.height(seed, bottom_end.x, bottom_end.y) - 9.5,
		bottom_end.y
	))
	mesh.surface_set_normal(normal)
	mesh.surface_add_vertex(Vector3(
		bottom_start.x,
		TerrainSurface.height(seed, bottom_start.x, bottom_start.y) - 9.5,
		bottom_start.y
	))


func _add_metro_ventilation(line_id: String, route: Array[Vector2]) -> void:
	var samples := RoadGeometry.resample_polyline(route, 185.0)
	if samples.size() < 3:
		return
	var stop_points: Array[Vector2] = []
	for stop_id in TransitNetwork.line_stop_ids(GameStore.transit_network, line_id):
		var stop := GameStore.transit_stop(stop_id)
		if stop.is_empty():
			continue
		stop_points.append(Vector2(float(stop.get("x", 0.0)), float(stop.get("y", 0.0))))

	var transforms: Array[Transform3D] = []
	var distance_since_vent := 0.0
	var next_vent_distance := 190.0
	for index in range(1, samples.size() - 1):
		distance_since_vent += samples[index - 1].distance_to(samples[index])
		if distance_since_vent < next_vent_distance:
			continue
		next_vent_distance += 190.0
		var point: Vector2 = samples[index]
		var near_station := false
		for stop_point in stop_points:
			if point.distance_to(stop_point) < 48.0:
				near_station = true
				break
		if near_station:
			continue
		var tangent := (samples[index + 1] - samples[index - 1]).normalized()
		if tangent.length_squared() <= 0.000001:
			continue
		var normal := Vector2(-tangent.y, tangent.x)
		var side := 1.0 if transforms.size() % 2 == 0 else -1.0
		var vent_point := point + normal * side * 13.0
		var y := TerrainSurface.height(GameStore.city_seed, vent_point.x, vent_point.y)
		transforms.append(Transform3D(
			Basis.IDENTITY,
			Vector3(vent_point.x, y, vent_point.y)
		))
	if transforms.is_empty():
		return

	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_3D
	instances.mesh = _metro_vent_mesh_for_line(line_id)
	instances.instance_count = transforms.size()
	var instance_bounds := AABB()
	for index in range(transforms.size()):
		instances.set_instance_transform(index, transforms[index])
		var center := transforms[index].origin
		var vent_bounds := AABB(center + Vector3(-2.5, 0.0, -2.5), Vector3(5.0, 3.8, 5.0))
		instance_bounds = vent_bounds if index == 0 else instance_bounds.merge(vent_bounds)
	instances.custom_aabb = instance_bounds
	var vent_cluster := MultiMeshInstance3D.new()
	vent_cluster.name = "MetroVentilation_%s" % line_id
	vent_cluster.multimesh = instances
	vent_cluster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_static_root.add_child(vent_cluster)


func _metro_vent_mesh_for_line(line_id: String) -> ArrayMesh:
	var cache_key := _line_color(line_id).to_html()
	if _metro_vent_mesh_cache.has(cache_key):
		return _metro_vent_mesh_cache[cache_key]
	var mesh := ArrayMesh.new()
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	var foot := CylinderMesh.new()
	foot.top_radius = 2.0
	foot.bottom_radius = 2.25
	foot.height = 0.52
	foot.radial_segments = 8
	body.append_from(foot, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.28, 0.0)))
	var shaft := CylinderMesh.new()
	shaft.top_radius = 1.12
	shaft.bottom_radius = 1.48
	shaft.height = 2.25
	shaft.radial_segments = 8
	body.append_from(shaft, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, 1.65, 0.0)))
	body.generate_normals()
	body.commit(mesh)
	var body_material := StandardMaterial3D.new()
	body_material.albedo_color = Color("#667276")
	body_material.roughness = 0.88
	mesh.surface_set_material(0, body_material)

	var details := SurfaceTool.new()
	details.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cap := CylinderMesh.new()
	cap.top_radius = 1.55
	cap.bottom_radius = 1.08
	cap.height = 0.34
	cap.radial_segments = 8
	details.append_from(cap, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, 2.92, 0.0)))
	for index in range(4):
		_append_station_box(
			details,
			Vector3(1.65, 0.11, 0.16),
			Vector3(0.0, 0.85 + float(index) * 0.34, 1.18)
		)
	details.generate_normals()
	details.commit(mesh)
	var accent_material := StandardMaterial3D.new()
	accent_material.albedo_color = _line_color(line_id).lightened(0.12)
	accent_material.roughness = 0.62
	accent_material.emission_enabled = true
	accent_material.emission = _line_color(line_id)
	accent_material.emission_energy_multiplier = 0.12
	mesh.surface_set_material(1, accent_material)
	_metro_vent_mesh_cache[cache_key] = mesh
	return mesh

func _add_station(
	station_id: String,
	line_key: String,
	stop_index: int,
	ghost: bool,
	override_selection: String
) -> void:
	var point := Layout.stop_position(line_key, stop_index)
	var y := TerrainSurface.height(GameStore.city_seed, point.x, point.y)
	var level := 0 if ghost else GameStore.station_level(station_id)
	var served := GameStore.station_served_lines(station_id)
	var color: Color = Data.LINE_COLORS[line_key]
	if served.size() > 1 and not ghost:
		color = Color("#e6e5dd")

	var area := Area3D.new()
	area.name = "Station_%s" % station_id
	area.position = Vector3(point.x, y + 2.0, point.y)
	area.input_ray_pickable = true
	area.set_meta("selection", override_selection if not override_selection.is_empty() else "station:%s" % station_id)

	var shape := CollisionShape3D.new()
	var cylinder_shape := CylinderShape3D.new()
	cylinder_shape.radius = 20.0 + float(level) * 7.0
	cylinder_shape.height = 16.0 + float(level) * 4.0
	shape.shape = cylinder_shape
	area.add_child(shape)

	var station_model := MeshInstance3D.new()
	station_model.name = "StationModel"
	station_model.mesh = _station_mesh_for_level(level)
	station_model.set_surface_override_material(0, _station_body_material(color, ghost))
	station_model.set_surface_override_material(1, _station_details_material(ghost))
	station_model.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	area.add_child(station_model)

	var label := Label3D.new()
	label.text = Data.station_name(station_id)
	if ghost:
		label.text += "\n$%d" % (
			GameStore.line_build_cost(line_key)
			if override_selection.begins_with("future_line:")
			else GameStore.next_stop_cost(line_key)
		)
	elif level > 0:
		label.text += "\n%s" % GameStore.station_tier(station_id)
	label.position.y = 11.0 + float(level) * 0.8
	label.font_size = 24
	label.outline_size = 6
	label.modulate = Color.WHITE
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	area.add_child(label)

	area.input_event.connect(_on_pick.bind(area))
	_static_root.add_child(area)

func _add_free_station(
	stop_id: String,
	line_id: String,
	route_points: Array[Vector2] = []
) -> void:
	var stop := GameStore.transit_stop(stop_id)
	if stop.is_empty():
		return
	var point := Vector2(
		float(stop.get("x", 0.0)),
		float(stop.get("y", 0.0))
	)
	var y := TerrainSurface.height(GameStore.city_seed, point.x, point.y)
	var level := clampi(int(stop.get("level", 0)), 0, 3)
	var served: Array = stop.get("served_line_ids", [])
	var color := _line_color(line_id)
	var mode := str(GameStore.transit_line(line_id).get("mode", "bus"))
	var route := route_points
	if route.is_empty():
		route = TransitNetwork.line_route_points(GameStore.transit_network, line_id)
	var route_frame := _closest_route_frame(point, route)
	var tangent: Vector2 = route_frame.get("tangent", Vector2.RIGHT)
	if served.size() > 1:
		color = Color("#e6e5dd")

	var area := Area3D.new()
	area.name = "FreeStation_%s" % stop_id
	var station_lift := 0.08 if mode in ["tram", "metro"] else 2.0
	area.position = Vector3(point.x, y + station_lift, point.y)
	if tangent.length_squared() > 0.000001:
		area.rotation.y = -atan2(tangent.y, tangent.x)
	area.input_ray_pickable = true
	area.set_meta("selection", "free_stop:%s" % stop_id)

	var shape := CollisionShape3D.new()
	var cylinder_shape := CylinderShape3D.new()
	cylinder_shape.radius = 20.0 + float(level) * 7.0
	cylinder_shape.height = 16.0 + float(level) * 4.0
	shape.shape = cylinder_shape
	area.add_child(shape)

	var station_model := MeshInstance3D.new()
	station_model.name = "StationModel"
	if mode == "metro":
		station_model.mesh = _metro_station_mesh_for_level(level)
	elif mode == "tram":
		station_model.mesh = _tram_shelter_mesh_for_level(level)
		station_model.position.z = 5.0
	else:
		station_model.mesh = _station_mesh_for_level(level)
	station_model.set_surface_override_material(0, _station_body_material(color, false))
	station_model.set_surface_override_material(1, _station_details_material(false))
	station_model.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	area.add_child(station_model)
	if mode == "tram":
		_add_tram_stop_platforms(point, tangent, level)
	elif mode == "metro":
		var metro_sign := Label3D.new()
		metro_sign.text = "M"
		metro_sign.position = MetroSurfaceFeatures.entrance_sign_layout()["label_position"]
		metro_sign.font_size = 34
		metro_sign.outline_size = 5
		metro_sign.modulate = Color.WHITE
		metro_sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		area.add_child(metro_sign)

	var label := Label3D.new()
	var mode_label := "METRO STATION" if mode == "metro" else ("TRAM STOP" if mode == "tram" else "")
	label.text = (mode_label + "\n" if not mode_label.is_empty() else "") + str(stop.get("name", stop_id))
	if served.size() > 1:
		label.text += "\nINTERCHANGE"
	label.position.y = 11.0 + float(level) * 0.8
	label.font_size = 24
	label.outline_size = 6
	label.modulate = Color.WHITE
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	area.add_child(label)

	area.input_event.connect(_on_pick.bind(area))
	_static_root.add_child(area)


func _add_tram_stop_platforms(point: Vector2, tangent: Vector2, level: int) -> void:
	var safe_tangent := tangent.normalized()
	if safe_tangent.length_squared() <= 0.000001:
		safe_tangent = Vector2.RIGHT
	var normal := Vector2(-safe_tangent.y, safe_tangent.x)
	var platform_length := 27.0 + float(level) * 4.0
	for side in [-1.0, 1.0]:
		var platform_center: Vector2 = point + normal * float(side) * 5.0
		var platform_points: Array[Vector2] = [
			platform_center - safe_tangent * platform_length * 0.5,
			platform_center + safe_tangent * platform_length * 0.5,
		]
		_add_ribbon(platform_points, 3.5, Color("#aaa99f"), 0.15, false)
		var tactile_center: Vector2 = point + normal * float(side) * 3.55
		var tactile_points: Array[Vector2] = [
			tactile_center - safe_tangent * (platform_length - 1.4) * 0.5,
			tactile_center + safe_tangent * (platform_length - 1.4) * 0.5,
		]
		_add_ribbon(tactile_points, 0.42, Color("#d9b861"), 0.31, true)


func _metro_station_mesh_for_level(level: int) -> ArrayMesh:
	var tier := clampi(level, 0, 3)
	if _metro_station_mesh_cache.has(tier):
		return _metro_station_mesh_cache[tier]

	var mesh := ArrayMesh.new()
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	var plaza_width := 25.0 + float(tier) * 4.0
	var plaza_depth := 18.0 + float(tier) * 2.0
	var shaft_width := 5.2
	var shaft_depth := 8.3
	var shaft_center_z := 2.1
	var wing_width := (plaza_width - shaft_width) * 0.5
	_append_station_box(
		body,
		Vector3(wing_width, 0.72, plaza_depth),
		Vector3(-shaft_width * 0.5 - wing_width * 0.5, 0.37, 0.0)
	)
	_append_station_box(
		body,
		Vector3(wing_width, 0.72, plaza_depth),
		Vector3(shaft_width * 0.5 + wing_width * 0.5, 0.37, 0.0)
	)
	var shaft_back_depth := plaza_depth * 0.5 - (shaft_center_z - shaft_depth * 0.5)
	var shaft_front_depth := plaza_depth - shaft_back_depth - shaft_depth
	_append_station_box(
		body,
		Vector3(shaft_width, 0.72, shaft_back_depth),
		Vector3(0.0, 0.37, -plaza_depth * 0.5 + shaft_back_depth * 0.5)
	)
	_append_station_box(
		body,
		Vector3(shaft_width, 0.72, shaft_front_depth),
		Vector3(0.0, 0.37, shaft_center_z + shaft_depth * 0.5 + shaft_front_depth * 0.5)
	)
	# A compact canopy, four squared columns and open sides make this read as a
	# surface entrance instead of a solid block or an exposed tunnel mouth.
	for x in [-5.5, 5.5]:
		for z in [-5.0, 5.0]:
			_append_station_box(body, Vector3(0.48, 4.4, 0.48), Vector3(x, 2.93, z))
	_append_station_box(body, Vector3(14.2, 0.72, 12.2), Vector3(0.0, 5.35, 0.0))
	# A short, open stairwell descends into the locally visible tunnel cutaway.
	# It ends above the rails; the train remains visible in the route cutaway below.
	for step in range(12):
		var step_y := 0.45 - float(step) * 0.68
		var step_z := -1.72 + float(step) * 0.72
		_append_station_box(body, Vector3(4.4, 0.20, 0.76), Vector3(0.0, step_y, step_z))
	body.generate_normals()
	body.commit(mesh)

	var details := SurfaceTool.new()
	details.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		var handrail := BoxMesh.new()
		handrail.size = Vector3(0.16, 0.16, shaft_depth)
		var slope := atan2(7.5, shaft_depth)
		details.append_from(
			handrail,
			0,
			Transform3D(
				Basis(Vector3.RIGHT, slope),
				Vector3(side * 2.75, -3.15, shaft_center_z)
			)
		)
	_append_station_box(details, Vector3(4.8, 0.20, 1.0), Vector3(0.0, -7.28, 5.85))
	_append_station_box(details, Vector3(10.6, 1.0, 0.2), Vector3(0.0, 4.6, -6.0))
	var sign_layout := MetroSurfaceFeatures.entrance_sign_layout()
	var support_size: Vector3 = sign_layout["support_size"]
	for support_position in sign_layout["support_positions"]:
		_append_station_box(details, support_size, support_position)
	_append_station_box(details, sign_layout["panel_size"], sign_layout["panel_position"])
	# Wider stations add a low, simple wayfinding wing while retaining the same
	# entrance footprint and its recognizable open stair canopy.
	if tier >= 2:
		_append_station_box(
			details,
			Vector3(12.0 + float(tier) * 2.0, 0.42, 5.0),
			Vector3(0.0, 1.05, plaza_depth * 0.5 - 3.0)
		)
	details.generate_normals()
	details.commit(mesh)
	mesh.surface_set_material(1, _station_details_material())
	_metro_station_mesh_cache[tier] = mesh
	return mesh


func _tram_shelter_mesh_for_level(level: int) -> ArrayMesh:
	var tier := clampi(level, 0, 3)
	if _tram_shelter_mesh_cache.has(tier):
		return _tram_shelter_mesh_cache[tier]

	var mesh := ArrayMesh.new()
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	var roof_length := 11.5 + float(tier) * 1.5
	_append_station_box(body, Vector3(roof_length, 0.64, 4.0), Vector3(0.0, 5.0, 0.0))
	for x in [-roof_length * 0.42, roof_length * 0.42]:
		for z in [-1.55, 1.55]:
			_append_station_box(body, Vector3(0.38, 4.5, 0.38), Vector3(x, 2.58, z))
	_append_station_box(body, Vector3(5.8, 0.5, 0.92), Vector3(0.0, 1.15, 0.9))
	_append_station_box(body, Vector3(5.8, 0.28, 0.32), Vector3(0.0, 2.05, 1.15))
	body.generate_normals()
	body.commit(mesh)

	var details := SurfaceTool.new()
	details.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_station_box(details, Vector3(0.18, 2.5, 3.25), Vector3(-roof_length * 0.39, 3.25, -0.12))
	_append_station_box(details, Vector3(0.18, 2.5, 3.25), Vector3(roof_length * 0.39, 3.25, -0.12))
	_append_station_box(details, Vector3(4.0, 1.15, 0.18), Vector3(0.0, 4.45, -1.88))
	details.generate_normals()
	details.commit(mesh)
	mesh.surface_set_material(1, _station_details_material())
	_tram_shelter_mesh_cache[tier] = mesh
	return mesh

func _line_color(line_id: String) -> Color:
	if Data.LINE_COLORS.has(line_id):
		return Data.LINE_COLORS[line_id]
	var line := GameStore.transit_line(line_id)
	var raw := str(line.get("color", "#58b8ff"))
	return Color(raw)

func _station_mesh_for_level(level: int) -> ArrayMesh:
	if _station_mesh_cache.has(level):
		return _station_mesh_cache[level]

	var platform_sizes := [
		Vector3(30.0, 1.4, 12.0),
		Vector3(34.0, 1.4, 14.0),
		Vector3(40.0, 1.5, 18.0),
		Vector3(52.0, 1.7, 24.0),
	]
	var platform_size: Vector3 = platform_sizes[clampi(level, 0, 3)]
	var mesh := ArrayMesh.new()
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_station_box(body, platform_size, Vector3(0.0, -1.3, 0.0))

	var sign_x := -platform_size.x * 0.5 + 2.8
	_append_station_box(body, Vector3(0.7, 4.8, 0.7), Vector3(sign_x, 1.8, 0.0))
	_append_station_box(body, Vector3(5.0, 1.8, 0.7), Vector3(sign_x + 1.8, 4.9, 0.0))

	match level:
		1:
			_append_station_box(body, Vector3(28.0, 0.8, 13.0), Vector3(0.0, 5.6, 0.0))
			_add_station_supports(body, [-11.5, 11.5], [-5.2, 5.2], 5.8, 2.6)
		2:
			_append_station_box(body, Vector3(34.0, 1.0, 16.0), Vector3(0.0, 6.1, 0.0))
			_append_station_box(body, Vector3(19.0, 4.0, 12.0), Vector3(0.0, 1.35, 0.0))
			_add_station_supports(body, [-14.5, 14.5], [-6.7, 6.7], 6.2, 2.9)
		3:
			_append_station_box(body, Vector3(21.0, 0.9, 17.0), Vector3(0.0, 4.1, 0.0))
			_append_station_box(body, Vector3(19.0, 0.8, 20.0), Vector3(-16.0, 6.0, 0.0))
			_append_station_box(body, Vector3(19.0, 0.8, 20.0), Vector3(16.0, 6.0, 0.0))
			_append_station_box(body, Vector3(20.0, 4.4, 14.0), Vector3(0.0, 1.45, 0.0))
			_add_station_supports(body, [-23.0, -16.0, 16.0, 23.0], [-8.5, 8.5], 6.4, 3.0)

	body.generate_normals()
	body.commit(mesh)

	var details := SurfaceTool.new()
	details.begin(Mesh.PRIMITIVE_TRIANGLES)
	# A dark route board distinguishes even the basic Stop tier.
	_append_station_box(details, Vector3(3.8, 1.05, 0.12), Vector3(sign_x + 1.8, 4.9, 0.39))
	if level == 2:
		for side in [-1.0, 1.0]:
			for x in [-6.0, 0.0, 6.0]:
				_append_station_box(details, Vector3(3.8, 1.9, 0.12), Vector3(x, 1.65, side * 6.08))
			_append_station_box(details, Vector3(0.12, 2.0, 6.0), Vector3(9.58, 1.75, 0.0))
	if level == 3:
		for side in [-1.0, 1.0]:
			for x in [-6.0, 0.0, 6.0]:
				_append_station_box(details, Vector3(3.8, 2.1, 0.12), Vector3(x, 1.75, side * 7.08))
		_append_station_box(details, Vector3(0.12, 2.0, 7.0), Vector3(10.08, 1.75, 0.0))
	details.generate_normals()
	details.commit(mesh)
	mesh.surface_set_material(1, _station_details_material())
	_station_mesh_cache[level] = mesh
	return mesh

func _add_station_supports(
	surface: SurfaceTool,
	x_positions: Array,
	z_positions: Array,
	height: float,
	center_y: float
) -> void:
	for x in x_positions:
		for z in z_positions:
			_append_station_box(surface, Vector3(0.65, height, 0.65), Vector3(float(x), center_y, float(z)))

func _append_station_box(surface: SurfaceTool, size: Vector3, position: Vector3) -> void:
	var box := BoxMesh.new()
	box.size = size
	surface.append_from(box, 0, Transform3D(Basis.IDENTITY, position))

func _station_body_material(color: Color, ghost: bool) -> StandardMaterial3D:
	var cache_key := "%s:%s" % [color.to_html(), ghost]
	if _station_body_material_cache.has(cache_key):
		return _station_body_material_cache[cache_key]
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color.r, color.g, color.b, 0.48) if ghost else color
	material.roughness = 0.78
	if ghost:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_station_body_material_cache[cache_key] = material
	return material

func _station_details_material(ghost: bool = false) -> StandardMaterial3D:
	if _station_details_material_cache.has(ghost):
		return _station_details_material_cache[ghost]
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.145, 0.196, 0.22, 0.56) if ghost else Color("#253238")
	material.roughness = 0.58
	if ghost:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_station_details_material_cache[ghost] = material
	return material

func _add_depot(ghost: bool) -> void:
	var point := Layout.depot_position()
	var saved_position: Variant = GameStore.depot.get("position", null)
	if saved_position is Vector2:
		point = saved_position
	elif typeof(saved_position) == TYPE_DICTIONARY:
		var raw_position: Dictionary = saved_position
		point = Vector2(
			float(raw_position.get("x", point.x)),
			float(raw_position.get("y", point.y))
		)
	var y := TerrainSurface.height(GameStore.city_seed, point.x, point.y)

	var area := Area3D.new()
	area.position = Vector3(point.x, y + 5.0, point.y)
	area.input_ray_pickable = true
	area.set_meta("selection", "future_depot" if ghost else "depot")

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(110.0, 28.0, 80.0)
	shape.shape = box_shape
	area.add_child(shape)

	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(105.0, 20.0 if not ghost else 5.0, 74.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.25, 0.27, 0.25, 0.55) if ghost else Color("#a7aaa3")
	if ghost:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	box.material = material
	mesh_instance.mesh = box
	area.add_child(mesh_instance)

	var label := Label3D.new()
	var build_cost := (
		float(Data.ECONOMY["sandbox_depot_build_cost"])
		if GameStore.is_sandbox()
		else float(Data.ECONOMY.depot_build_cost)
	)
	label.text = "BUS DEPOT" if not ghost else "BUS DEPOT\n$%d" % roundi(build_cost)
	label.position.y = 28.0
	label.font_size = 30
	label.outline_size = 8
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	area.add_child(label)

	area.input_event.connect(_on_pick.bind(area))
	_static_root.add_child(area)

func _on_pick(
	_camera: Node,
	event: InputEvent,
	_event_position: Vector3,
	_normal: Vector3,
	_shape_idx: int,
	area: Area3D
) -> void:
	if (
		GameStore.route_editor_active()
		or GameStore.road_builder_active()
		or GameStore.depot_placement_active()
	):
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		GameStore.set_selection(str(area.get_meta("selection")))
		get_viewport().set_input_as_handled()

func _update_buses() -> void:
	var visible_keys: Dictionary = {}
	for visual in GameStore.bus_visuals():
		var transit_mode := str(visual.get("mode", "bus"))
		var key: String = visual.key
		visible_keys[key] = true
		var vehicle: MeshInstance3D = _bus_meshes.get(key)
		if vehicle == null:
			vehicle = _create_transit_vehicle(visual.line_key, transit_mode)
			_bus_meshes[key] = vehicle
			_bus_root.add_child(vehicle)

		var point: Vector2 = visual.position
		var tangent: Vector2 = visual.tangent
		var ground_height := TerrainSurface.height(GameStore.city_seed, point.x, point.y)
		vehicle.visible = true
		vehicle.position = Vector3(
			point.x,
			ground_height - 9.1 if transit_mode == "metro" else ground_height + 0.58,
			point.y
		)
		vehicle.rotation.y = -atan2(tangent.y, tangent.x)

	for key in _bus_meshes:
		if not visible_keys.has(key):
			_bus_meshes[key].visible = false

func _create_transit_vehicle(line_key: String, mode: String) -> MeshInstance3D:
	if _bus_model_mesh == null:
		_bus_model_mesh = _build_bus_mesh()
		_bus_details_material = StandardMaterial3D.new()
		_bus_details_material.albedo_color = Color("#253238")
		_bus_details_material.roughness = 0.58
		_bus_model_mesh.surface_set_material(1, _bus_details_material)

	var bus := MeshInstance3D.new()
	var material := StandardMaterial3D.new()
	var line_color := _line_color(line_key)
	material.albedo_color = line_color
	material.roughness = 0.7
	material.emission_enabled = true
	material.emission = line_color
	material.emission_energy_multiplier = 0.08
	if not _mode_vehicle_meshes.has(mode):
		_mode_vehicle_meshes[mode] = _build_mode_vehicle_mesh(mode)
	bus.mesh = _mode_vehicle_meshes[mode]
	bus.set_surface_override_material(0, material)
	if bus.mesh.get_surface_count() > 1:
		bus.set_surface_override_material(1, _bus_details_material)
	if mode == "tram" and bus.mesh.get_surface_count() > 2:
		if _tram_contact_material == null:
			_tram_contact_material = StandardMaterial3D.new()
			_tram_contact_material.albedo_color = Color("#d4d7cd")
			_tram_contact_material.roughness = 0.34
			_tram_contact_material.metallic = 0.42
		bus.set_surface_override_material(2, _tram_contact_material)
	bus.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return bus

func _build_mode_vehicle_mesh(mode: String) -> ArrayMesh:
	if mode == "bus":
		return _bus_model_mesh
	var result := ArrayMesh.new()
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	var car_count := 2 if mode == "tram" else 3
	var car_length := 13.0 if mode == "tram" else 12.0
	var spacing := car_length + 1.0
	for index in range(car_count):
		var x := (float(index) - float(car_count - 1) * 0.5) * spacing
		_append_bus_box(body, Vector3(car_length, 4.0, 5.0), Vector3(x, 2.45, 0.0))
		_append_bus_box(body, Vector3(car_length - 1.5, 1.5, 0.09), Vector3(x, 3.0, 2.55))
		_append_bus_box(body, Vector3(car_length - 1.5, 1.5, 0.09), Vector3(x, 3.0, -2.55))
		for wheel_offset in [-car_length * 0.3, car_length * 0.3]:
			_append_bus_wheel(body, Vector3(x + wheel_offset, 0.7, -2.5))
			_append_bus_wheel(body, Vector3(x + wheel_offset, 0.7, 2.5))
	body.generate_normals()
	body.commit(result)
	if mode == "tram":
		TramPantographMesh.append_surfaces(result)
	return result

func _build_bus_mesh() -> ArrayMesh:
	var result := ArrayMesh.new()
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_bus_box(body, Vector3(15.0, 2.1, 5.8), Vector3(0.0, 1.86, 0.0))
	_append_bus_box(body, Vector3(13.8, 2.8, 5.65), Vector3(-0.1, 4.05, 0.0))
	_append_bus_box(body, Vector3(11.5, 0.38, 5.35), Vector3(-0.15, 5.64, 0.0))
	body.generate_normals()
	body.commit(result)

	var details := SurfaceTool.new()
	details.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		for x in [-4.4, -1.6, 1.2, 3.8]:
			_append_bus_box(details, Vector3(2.25, 1.45, 0.08), Vector3(x, 4.15, side * 2.88))
	_append_bus_box(details, Vector3(0.1, 1.65, 5.0), Vector3(6.98, 4.05, 0.0))
	_append_bus_box(details, Vector3(0.1, 1.35, 4.6), Vector3(-7.0, 4.0, 0.0))
	_append_bus_wheel(details, Vector3(-4.6, 1.0, -2.82))
	_append_bus_wheel(details, Vector3(-4.6, 1.0, 2.82))
	_append_bus_wheel(details, Vector3(4.55, 1.0, -2.82))
	_append_bus_wheel(details, Vector3(4.55, 1.0, 2.82))
	details.generate_normals()
	details.commit(result)
	return result

func _append_bus_box(surface: SurfaceTool, size: Vector3, position: Vector3) -> void:
	var box := BoxMesh.new()
	box.size = size
	surface.append_from(box, 0, Transform3D(Basis.IDENTITY, position))

func _append_bus_wheel(surface: SurfaceTool, position: Vector3) -> void:
	var wheel := CylinderMesh.new()
	wheel.top_radius = 0.92
	wheel.bottom_radius = 0.92
	wheel.height = 0.68
	wheel.radial_segments = 10
	surface.append_from(
		wheel,
		0,
		Transform3D(Basis(Vector3.RIGHT, PI * 0.5), position)
	)
