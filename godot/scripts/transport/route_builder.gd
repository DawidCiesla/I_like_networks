extends Node3D
class_name RouteBuilder

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const RoadGeometry = preload("res://scripts/render/road_geometry.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")

var _draft_root: Node3D
var _hover_root: Node3D
var _last_signature := ""

func _ready() -> void:
	_draft_root = Node3D.new()
	_draft_root.name = "DraftRoute"
	add_child(_draft_root)

	_hover_root = Node3D.new()
	_hover_root.name = "HoverPreview"
	add_child(_hover_root)

	GameStore.route_editor_changed.connect(_rebuild)
	GameStore.state_changed.connect(_rebuild)
	_rebuild()

func _process(_delta: float) -> void:
	var active := GameStore.route_editor_active()
	visible = active
	if not active:
		return
	var signature := _editor_signature()
	if signature != _last_signature:
		_rebuild()

func _unhandled_input(event: InputEvent) -> void:
	if not GameStore.route_editor_active():
		return

	if event is InputEventMouseMotion:
		var point := _screen_to_world(event.position)
		if point == null:
			GameStore.clear_route_editor_hover()
			return
		var world_point: Vector2 = point
		var snap := GameStore.snap_transit_point(world_point, true, 125.0)
		if snap.is_empty():
			GameStore.set_route_editor_hover(world_point, false)
			return
		var snapped: Vector2 = snap["point"]
		var preview: Dictionary = {}
		var points := GameStore.route_editor_points()
		var selected := int(GameStore.route_editor.get("selected_index", -1))
		if selected < 0 and not points.is_empty():
			preview = GameStore.preview_transit_route(
				points.back(),
				snapped,
				true,
				true,
				125.0
			)
		elif selected >= 0 and selected < points.size():
			var routes: Array = []
			if selected > 0:
				routes.append(GameStore.preview_transit_route(
					points[selected - 1],
					snapped,
					true,
					true,
					125.0
				))
			if selected < points.size() - 1:
				routes.append(GameStore.preview_transit_route(
					snapped,
					points[selected + 1],
					true,
					true,
					125.0
				))
			preview = {"success": true, "routes": routes}
			for route_value in routes:
				var route: Dictionary = route_value
				if not bool(route.get("success", false)):
					preview["success"] = false
					break
		GameStore.set_route_editor_hover(
			snapped,
			bool(preview.get("success", true)),
			preview
		)
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var point := _screen_to_world(event.position)
			if point == null:
				return
			var snap := GameStore.snap_transit_point(point, true, 125.0)
			if snap.is_empty():
				GameStore.show_route_editor_message("No built road under cursor.")
				get_viewport().set_input_as_handled()
				return
			var snapped: Vector2 = snap["point"]
			var points := GameStore.route_editor_points()
			var nearby := _nearest_draft_stop(points, snapped, 32.0)
			var selected := int(GameStore.route_editor.get("selected_index", -1))
			if nearby >= 0:
				GameStore.route_editor_select_stop(nearby)
			elif selected >= 0:
				if event.shift_pressed:
					GameStore.route_editor_add_point(snapped, selected)
				else:
					GameStore.route_editor_move_selected(snapped)
			else:
				GameStore.route_editor_add_point(snapped)
			get_viewport().set_input_as_handled()
			return

		if event.button_index == MOUSE_BUTTON_RIGHT:
			if int(GameStore.route_editor.get("selected_index", -1)) >= 0:
				GameStore.route_editor_remove_selected()
			else:
				GameStore.route_editor_undo_last()
			get_viewport().set_input_as_handled()
			return

	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_ESCAPE:
				GameStore.cancel_route_editor()
			KEY_ENTER, KEY_KP_ENTER:
				GameStore.commit_route_editor()
			KEY_DELETE:
				GameStore.route_editor_remove_selected()
			KEY_BACKSPACE:
				GameStore.route_editor_undo_last()
			_:
				return
		get_viewport().set_input_as_handled()

func _rebuild() -> void:
	_last_signature = _editor_signature()
	if _draft_root == null or _hover_root == null:
		return
	for child in _draft_root.get_children():
		child.queue_free()
	for child in _hover_root.get_children():
		child.queue_free()

	if not GameStore.route_editor_active():
		visible = false
		return
	visible = true

	var points := GameStore.route_editor_points()
	var selected := int(GameStore.route_editor.get("selected_index", -1))
	for index in range(points.size()):
		_add_stop_marker(_draft_root, points[index], index, index == selected, false)
		if index > 0:
			var route := GameStore.preview_transit_route(
				points[index - 1],
				points[index],
				true,
				true,
				125.0
			)
			if bool(route.get("success", false)):
				_add_route_preview(_draft_root, route, Color("#58b8ff"), 4.8, 0.16)

	var hover_value = GameStore.route_editor.get("hover_point", null)
	if hover_value is Vector2:
		var hover: Vector2 = hover_value
		var valid := bool(GameStore.route_editor.get("hover_valid", false))
		_add_stop_marker(_hover_root, hover, points.size(), false, true, valid)
		_add_catchment_disk(_hover_root, hover, valid)
		var preview: Dictionary = GameStore.route_editor.get("preview_route", {})
		if preview.has("routes"):
			for route_value in preview.get("routes", []):
				var route: Dictionary = route_value
				if bool(route.get("success", false)):
					_add_route_preview(
						_hover_root,
						route,
						Color("#8fd4ff") if valid else Color("#ff776e"),
						4.0,
						0.17
					)
		elif bool(preview.get("success", false)):
			_add_route_preview(
				_hover_root,
				preview,
				Color("#8fd4ff") if valid else Color("#ff776e"),
				4.0,
				0.17
			)

func _add_route_preview(
	parent: Node3D,
	route: Dictionary,
	color: Color,
	width: float,
	height: float
) -> void:
	var points: Array[Vector2] = []
	for point_value in route.get("points", []):
		if point_value is Vector2:
			points.append(point_value)
	if points.size() < 2:
		return
	var mesh = RoadGeometry.create_ribbon_mesh(
		GameStore.city_seed,
		points,
		width,
		color,
		height,
		RoadGeometry.DEFAULT_SAMPLE_SPACING,
		true,
		true,
		0.22
	)
	if mesh == null:
		return
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)

func _add_stop_marker(
	parent: Node3D,
	point: Vector2,
	index: int,
	selected: bool,
	ghost: bool,
	valid: bool = true
) -> void:
	var root := Node3D.new()
	root.position = Vector3(
		point.x,
		TerrainSurface.height(GameStore.city_seed, point.x, point.y) + 1.0,
		point.y
	)
	parent.add_child(root)

	var mesh_instance := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 10.0 if not ghost else 8.0
	cylinder.bottom_radius = cylinder.top_radius
	cylinder.height = 2.2 if selected else 1.5
	cylinder.radial_segments = 20
	var material := StandardMaterial3D.new()
	if not valid:
		material.albedo_color = Color(0.95, 0.22, 0.18, 0.78)
	elif selected:
		material.albedo_color = Color(1.0, 0.82, 0.22, 0.92)
	else:
		material.albedo_color = Color(0.25, 0.72, 1.0, 0.82 if ghost else 0.95)
	if ghost:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.emission_enabled = true
	material.emission = material.albedo_color
	material.emission_energy_multiplier = 0.18
	cylinder.material = material
	mesh_instance.mesh = cylinder
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh_instance)

	var label := Label3D.new()
	label.text = "%d" % (index + 1)
	if selected:
		label.text += "\nMOVE"
	label.position.y = 8.0
	label.font_size = 21
	label.outline_size = 5
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	root.add_child(label)

func _add_catchment_disk(parent: Node3D, point: Vector2, valid: bool) -> void:
	var mesh_instance := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = TransitNetwork.DEFAULT_CATCHMENT_RADIUS
	cylinder.bottom_radius = TransitNetwork.DEFAULT_CATCHMENT_RADIUS
	cylinder.height = 0.22
	cylinder.radial_segments = 48
	var material := StandardMaterial3D.new()
	material.albedo_color = (
		Color(0.18, 0.58, 0.95, 0.10)
		if valid
		else Color(0.92, 0.20, 0.16, 0.08)
	)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cylinder.material = material
	mesh_instance.mesh = cylinder
	mesh_instance.position = Vector3(
		point.x,
		TerrainSurface.height(GameStore.city_seed, point.x, point.y) + 0.11,
		point.y
	)
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh_instance)

func _screen_to_world(screen_position: Vector2):
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return null
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	if absf(direction.y) <= 0.000001:
		return null

	var t := (0.0 - origin.y) / direction.y
	if t < 0.0:
		return null
	for _iteration in range(6):
		var sample := origin + direction * t
		var terrain_y := TerrainSurface.height(
			GameStore.city_seed,
			sample.x,
			sample.z
		)
		t = (terrain_y - origin.y) / direction.y
		if t < 0.0:
			return null
	var hit := origin + direction * t
	return Vector2(hit.x, hit.z)

func _nearest_draft_stop(
	points: Array[Vector2],
	point: Vector2,
	radius: float
) -> int:
	var best_index := -1
	var best_distance := radius
	for index in range(points.size()):
		var distance := points[index].distance_to(point)
		if distance < best_distance:
			best_distance = distance
			best_index = index
	return best_index

func _editor_signature() -> String:
	if not GameStore.route_editor_active():
		return "inactive"
	var parts: Array[String] = [
		str(GameStore.route_editor.get("mode", "")),
		str(GameStore.route_editor.get("line_id", "")),
		str(GameStore.route_editor.get("selected_index", -1)),
	]
	for point in GameStore.route_editor_points():
		parts.append("%.2f,%.2f" % [point.x, point.y])
	var hover = GameStore.route_editor.get("hover_point", null)
	if hover is Vector2:
		var hover_point: Vector2 = hover
		parts.append("h:%.2f,%.2f:%s" % [
			hover_point.x,
			hover_point.y,
			GameStore.route_editor.get("hover_valid", false),
		])
	return "|".join(parts)
