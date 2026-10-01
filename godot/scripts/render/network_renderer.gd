extends Node3D

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const RoadGeometry = preload("res://scripts/render/road_geometry.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")

var _static_root: Node3D
var _selection_root: Node3D
var _bus_root: Node3D
var _bus_meshes: Dictionary = {}
var _bus_model_mesh: ArrayMesh
var _bus_details_material: StandardMaterial3D
var _station_mesh_cache: Dictionary = {}
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
		parts.append("%s:%s:%s:%s" % [
			line_id,
			custom_line.get("status", ""),
			custom_line.get("stop_ids", []),
			custom_line.get("route_length_world", 0.0),
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

	parts.append("depot:%s" % GameStore.depot.built)
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
	for line_id in TransitNetwork.custom_line_ids(GameStore.transit_network):
		var custom_line: Dictionary = network_lines.get(line_id, {})
		if str(custom_line.get("status", "")) != "active":
			continue
		var route := TransitNetwork.line_route_points(GameStore.transit_network, line_id)
		if route.size() >= 2:
			_add_ribbon(route, 4.2, _line_color(line_id), 0.145, true)
		for stop_id in TransitNetwork.line_stop_ids(GameStore.transit_network, line_id):
			if rendered_stations.has(stop_id):
				continue
			_add_free_station(stop_id, line_id)
			rendered_stations[stop_id] = true

	if bool(GameStore.depot.built) or GameStore.can_build_depot():
		_add_depot(not bool(GameStore.depot.built))
	_rebuild_selection_overlay()

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

func _add_station(
	station_id: String,
	line_key: String,
	stop_index: int,
	ghost: bool,
	override_selection: String
) -> void:
	var point := Layout.stop_position(line_key, stop_index)
	var y := Terrain.height(GameStore.city_seed, point.x, point.y)
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

func _add_free_station(stop_id: String, line_id: String) -> void:
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
	if served.size() > 1:
		color = Color("#e6e5dd")

	var area := Area3D.new()
	area.name = "FreeStation_%s" % stop_id
	area.position = Vector3(point.x, y + 2.0, point.y)
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
	station_model.mesh = _station_mesh_for_level(level)
	station_model.set_surface_override_material(0, _station_body_material(color, false))
	station_model.set_surface_override_material(1, _station_details_material(false))
	station_model.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	area.add_child(station_model)

	var label := Label3D.new()
	label.text = str(stop.get("name", stop_id))
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
	var y := Terrain.height(GameStore.city_seed, point.x, point.y)

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
	label.text = "BUS DEPOT" if not ghost else "BUS DEPOT\n$%d" % int(Data.ECONOMY.depot_build_cost)
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
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		GameStore.set_selection(str(area.get_meta("selection")))
		get_viewport().set_input_as_handled()

func _update_buses() -> void:
	var visible_keys: Dictionary = {}
	for visual in GameStore.bus_visuals():
		var key: String = visual.key
		visible_keys[key] = true
		var bus: MeshInstance3D = _bus_meshes.get(key)
		if bus == null:
			bus = _create_bus(visual.line_key)
			_bus_meshes[key] = bus
			_bus_root.add_child(bus)

		var point: Vector2 = visual.position
		var tangent: Vector2 = visual.tangent
		bus.visible = true
		bus.position = Vector3(
			point.x,
			TerrainSurface.height(GameStore.city_seed, point.x, point.y) + 0.58,
			point.y
		)
		bus.rotation.y = -atan2(tangent.y, tangent.x)

	for key in _bus_meshes:
		if not visible_keys.has(key):
			_bus_meshes[key].visible = false

func _create_bus(line_key: String) -> MeshInstance3D:
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
	bus.mesh = _bus_model_mesh
	bus.set_surface_override_material(0, material)
	bus.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return bus

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
