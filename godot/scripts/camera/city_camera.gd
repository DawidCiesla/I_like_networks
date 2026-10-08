extends Node3D

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const WorldMapDefinition = preload("res://scripts/world/world_map_definition.gd")

@onready var camera: Camera3D = $Camera3D

@export var distance := 1350.0
@export var min_distance := 180.0
@export var max_distance := 16000.0
@export var zoom_speed := 0.12
@export var rotate_speed := 0.006
@export var pan_speed := 0.00125

var yaw := -0.72
var pitch := 0.72
var _drag_button := 0

const TERRAIN_BRUSH_RADIUS := 130.0
const TERRAIN_BRUSH_STRENGTH := 12.0

func _ready() -> void:
	camera.far = maxf(camera.far, max_distance * 1.5)
	reset_view()

func reset_view() -> void:
	if _is_sandbox_map():
		_fit_region_view()
		return
	position = Vector3(-260.0, 0.0, -120.0)
	distance = 1350.0
	yaw = -0.72
	pitch = 0.72
	_update_camera()


func _is_sandbox_map() -> bool:
	return (
		str(GameStore.world_map.get("id", WorldMapDefinition.LEGACY_CITY_MAP_ID))
		!= WorldMapDefinition.LEGACY_CITY_MAP_ID
	)


func _fit_region_view() -> void:
	var bounds := TerrainSurface.world_bounds()
	var center := bounds.get_center()
	var target_height := TerrainSurface.height(GameStore.city_seed, center.x, center.y)
	position = Vector3(center.x, target_height, center.y)
	yaw = -0.72
	pitch = 0.72
	distance = min_distance
	_update_camera()

	var right := camera.global_transform.basis.x
	var up := camera.global_transform.basis.y
	var half_width := 0.0
	var half_height := 0.0
	var min_terrain_height := target_height
	var max_terrain_height := target_height
	var end := bounds.position + bounds.size
	for x in [bounds.position.x, end.x]:
		for z in [bounds.position.y, end.y]:
			var terrain_height := TerrainSurface.height(GameStore.city_seed, x, z)
			min_terrain_height = minf(min_terrain_height, terrain_height)
			max_terrain_height = maxf(max_terrain_height, terrain_height)
			var offset := Vector3(x - center.x, terrain_height - target_height, z - center.y)
			half_width = maxf(half_width, absf(offset.dot(right)))
			half_height = maxf(half_height, absf(offset.dot(up)))

	var viewport_size := get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	var fov_tangent := tan(deg_to_rad(camera.fov) * 0.5)
	var vertical_tangent := fov_tangent
	var horizontal_tangent := fov_tangent * maxf(aspect, 0.1)
	if camera.keep_aspect == Camera3D.KEEP_WIDTH:
		horizontal_tangent = fov_tangent
		vertical_tangent = fov_tangent / maxf(aspect, 0.1)
	var relief_padding := maxf(240.0, max_terrain_height - min_terrain_height + 120.0)
	half_height += relief_padding
	var required_distance := maxf(
		half_width / maxf(horizontal_tangent, 0.001),
		half_height / maxf(vertical_tangent, 0.001)
	)
	distance = clampf(required_distance * 1.12, min_distance, max_distance)
	_update_camera()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			distance = max(min_distance, distance * (1.0 - zoom_speed))
			_update_camera()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			distance = min(max_distance, distance * (1.0 + zoom_speed))
			_update_camera()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_drag_button = event.button_index if event.pressed else 0
		elif event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			if GameStore.depot_placement_active():
				_drag_button = 0
				if event.pressed:
					if event.button_index == MOUSE_BUTTON_LEFT:
						_place_depot(event.position)
					else:
						GameStore.cancel_depot_placement()
				get_viewport().set_input_as_handled()
			elif GameStore.road_builder_active():
				_drag_button = 0
				if event.pressed:
					if event.button_index == MOUSE_BUTTON_LEFT:
						_add_road_builder_point(event.position)
					else:
						if GameStore.road_builder_points().is_empty():
							GameStore.cancel_road_builder()
						else:
							GameStore.road_builder_undo_point()
				get_viewport().set_input_as_handled()
			elif event.button_index == MOUSE_BUTTON_LEFT and not str(GameStore.terrain_tool_mode).is_empty():
				_drag_button = 0
				if event.pressed:
					_apply_terrain_tool(event.position)
				get_viewport().set_input_as_handled()
			elif GameStore.route_editor_active():
				_drag_button = 0
			else:
				_drag_button = event.button_index if event.pressed else 0

	elif event is InputEventMouseMotion and _drag_button != 0:
		if _drag_button == MOUSE_BUTTON_LEFT:
			yaw -= event.relative.x * rotate_speed
			pitch = clamp(pitch - event.relative.y * rotate_speed, 0.18, 1.42)
		else:
			_pan(event.relative)
		_update_camera()
		get_viewport().set_input_as_handled()

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if GameStore.depot_placement_active():
				GameStore.cancel_depot_placement()
				get_viewport().set_input_as_handled()
			elif GameStore.road_builder_active():
				GameStore.cancel_road_builder()
				get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_F:
			reset_view()
			get_viewport().set_input_as_handled()

func _pan(relative: Vector2) -> void:
	var right := camera.global_transform.basis.x
	var forward := -camera.global_transform.basis.z
	right.y = 0.0
	forward.y = 0.0
	right = right.normalized()
	forward = forward.normalized()

	var scale := distance * pan_speed
	position += (-right * relative.x + forward * relative.y) * scale


func _add_road_builder_point(screen_position: Vector2) -> void:
	if GameStore.road_builder_points().size() >= 2:
		GameStore.show_message("Click COMMIT ROAD or right-click to change the last point.")
		return
	var point: Variant = _screen_to_terrain(screen_position)
	if point == null:
		GameStore.show_message("Click inside the map to place a road point.")
		return
	var terrain_point: Vector2 = point
	if not GameStore.road_builder_add_point(terrain_point):
		GameStore.show_message("That road point could not be added.")


func _place_depot(screen_position: Vector2) -> void:
	var point: Variant = _screen_to_terrain(screen_position)
	if point == null:
		GameStore.show_message("Click inside the map to place the depot.")
		return
	var terrain_point: Vector2 = point
	if not GameStore.build_depot_at(terrain_point):
		GameStore.show_message("The depot could not be placed there.")


func _apply_terrain_tool(screen_position: Vector2) -> void:
	var point: Variant = _screen_to_terrain(screen_position)
	if point == null:
		GameStore.show_message("Click inside the map to sculpt terrain.")
		return
	var center: Vector2 = point
	var result: Dictionary = {}
	match str(GameStore.terrain_tool_mode):
		"raise":
			result = GameStore.raise_terrain(
				center,
				TERRAIN_BRUSH_RADIUS,
				TERRAIN_BRUSH_STRENGTH
			)
		"lower":
			result = GameStore.lower_terrain(
				center,
				TERRAIN_BRUSH_RADIUS,
				TERRAIN_BRUSH_STRENGTH
			)
		"flatten":
			result = GameStore.flatten_terrain_to_sample(center, TERRAIN_BRUSH_RADIUS, 0.8)
		"smooth":
			result = GameStore.smooth_terrain(center, TERRAIN_BRUSH_RADIUS, 0.8)
	if bool(result.get("ok", false)):
		GameStore.show_message("Terrain updated. Changes are saved with this map.")
	else:
		GameStore.show_message(
			"Terrain could not be changed: %s" % str(
				result.get("error", "no terrain samples changed")
			)
		)


func _screen_to_terrain(screen_position: Vector2) -> Variant:
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	if absf(direction.y) <= 0.000001:
		return null
	var distance_along_ray := (0.0 - origin.y) / direction.y
	if distance_along_ray < 0.0:
		return null
	for _iteration in range(8):
		var sample := origin + direction * distance_along_ray
		var terrain_y := TerrainSurface.height(GameStore.city_seed, sample.x, sample.z)
		distance_along_ray = (terrain_y - origin.y) / direction.y
		if distance_along_ray < 0.0:
			return null
	var hit := origin + direction * distance_along_ray
	var terrain_point := Vector2(hit.x, hit.z)
	return terrain_point if TerrainSurface.world_bounds().has_point(terrain_point) else null

func _update_camera() -> void:
	var horizontal := cos(pitch) * distance
	var vertical := sin(pitch) * distance
	camera.position = Vector3(
		sin(yaw) * horizontal,
		vertical,
		cos(yaw) * horizontal
	)
	camera.look_at(global_position, Vector3.UP)
