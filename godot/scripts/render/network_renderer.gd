extends Node3D

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const Terrain = preload("res://scripts/world/terrain_model.gd")

var _static_root: Node3D
var _bus_root: Node3D
var _bus_meshes: Dictionary = {}
var _signature := ""

func _ready() -> void:
	_static_root = Node3D.new()
	_static_root.name = "StaticNetwork"
	add_child(_static_root)

	_bus_root = Node3D.new()
	_bus_root.name = "Buses"
	add_child(_bus_root)

	GameStore.state_changed.connect(_on_state_changed)
	rebuild()

func _process(_delta: float) -> void:
	_update_buses()

func _on_state_changed() -> void:
	var next_signature := _visual_signature()
	if next_signature == _signature:
		return
	rebuild()

func _visual_signature() -> String:
	var parts: Array[String] = []
	for line_key in Data.LINE_KEYS:
		var line: Dictionary = GameStore.lines[line_key]
		parts.append("%s:%s:%s" % [line_key, line.built, line.stop_count])
	for station_id in Data.all_station_ids():
		parts.append("%s:%d" % [station_id, GameStore.station_level(station_id)])
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
			_add_ribbon(route, 16.0, Color("#3a3d3c"), 0.55, false)
			_add_ribbon(route, 3.8, Data.LINE_COLORS[line_key], 1.05, true)

		for stop_index in range(int(line.stop_count)):
			var station_id: String = Data.STATION_IDS[line_key][stop_index]
			if rendered_stations.has(station_id):
				continue
			_add_station(station_id, line_key, stop_index, false, "")
			rendered_stations[station_id] = true

		if int(line.stop_count) > 0 and int(line.stop_count) < int(Data.LINE_CONFIG[line_key].max_stops):
			var future := Layout.future_segment(line_key, int(line.stop_count))
			_add_ribbon(future, 14.0, Color(0.35, 0.37, 0.35, 0.38), 0.50, false)
			_add_ribbon(future, 3.2, Color(Data.LINE_COLORS[line_key], 0.48), 0.88, true)
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
		_add_ribbon(future, 3.2, Color(Data.LINE_COLORS[line_key], 0.42), 0.88, true)
		var station_id: String = Data.STATION_IDS[line_key][1]
		_add_station(station_id, line_key, 1, true, "future_line:%s" % line_key)

	if bool(GameStore.depot.built) or GameStore.can_build_depot():
		_add_depot(not bool(GameStore.depot.built))

func _add_ribbon(
	points: Array[Vector2],
	width: float,
	color: Color,
	height_offset: float,
	emissive: bool
) -> void:
	if points.size() < 2:
		return

	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	if color.a < 0.99:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emissive:
		material.emission_enabled = true
		material.emission = Color(color.r, color.g, color.b)
		material.emission_energy_multiplier = 0.32

	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, material)

	for index in range(points.size()):
		var previous := points[maxi(0, index - 1)]
		var next := points[mini(points.size() - 1, index + 1)]
		var direction := (next - previous).normalized()
		var normal := Vector2(-direction.y, direction.x)

		for side in [-1.0, 1.0]:
			var point := points[index] + normal * width * 0.5 * side
			mesh.surface_add_vertex(Vector3(
				point.x,
				Terrain.height(GameStore.city_seed, point.x, point.y) + height_offset,
				point.y
			))

	mesh.surface_end()
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
	cylinder_shape.radius = 19.0 + float(level) * 4.0
	cylinder_shape.height = 12.0 + float(level) * 4.0
	shape.shape = cylinder_shape
	area.add_child(shape)

	var base := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 13.0 + float(level) * 4.0
	cylinder.bottom_radius = cylinder.top_radius
	cylinder.height = 3.0 + float(level)
	cylinder.radial_segments = 16
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.14, 0.16, 0.14, 0.58) if ghost else color
	material.roughness = 0.72
	if ghost:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cylinder.material = material
	base.mesh = cylinder
	area.add_child(base)

	if not ghost and level >= 1:
		var canopy := MeshInstance3D.new()
		var canopy_mesh := BoxMesh.new()
		canopy_mesh.size = Vector3(26.0 + float(level) * 5.0, 2.6, 15.0 + float(level) * 3.0)
		var canopy_material := StandardMaterial3D.new()
		canopy_material.albedo_color = Color("#d8d7cf")
		canopy_mesh.material = canopy_material
		canopy.mesh = canopy_mesh
		canopy.position.y = 9.0 + float(level) * 1.4
		area.add_child(canopy)

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
	label.position.y = 26.0 + float(level) * 4.0
	label.font_size = 28
	label.outline_size = 8
	label.modulate = Color.WHITE
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	area.add_child(label)

	area.input_event.connect(_on_pick.bind(area))
	_static_root.add_child(area)

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
			Terrain.height(GameStore.city_seed, point.x, point.y) + 4.5,
			point.y
		)
		bus.rotation.y = -atan2(tangent.y, tangent.x)

	for key in _bus_meshes:
		if not visible_keys.has(key):
			_bus_meshes[key].visible = false

func _create_bus(line_key: String) -> MeshInstance3D:
	var bus := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(13.0, 7.0, 6.5)
	var material := StandardMaterial3D.new()
	material.albedo_color = Data.LINE_COLORS[line_key]
	material.emission_enabled = true
	material.emission = Data.LINE_COLORS[line_key]
	material.emission_energy_multiplier = 0.18
	box.material = material
	bus.mesh = box
	bus.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return bus
