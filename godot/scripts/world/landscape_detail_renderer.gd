extends Node3D
class_name LandscapeDetailRenderer

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const WorldLayers = preload("res://scripts/world/world_layers.gd")
const DetailShader = preload("res://scripts/world/landscape_detail.gdshader")

const PATCH_RADIUS_METERS := 880.0
const SAMPLE_SPACING_METERS := 34.0
const REBUILD_DISTANCE_METERS := 175.0
const MAX_CAMERA_HEIGHT_METERS := 1900.0
const MAX_ROCKS := 1250
const MAX_SHRUBS := 2200
const ROAD_CLEARANCE_METERS := 22.0
const SETTLEMENT_CLEARANCE_FACTOR := 0.78

var _store: Node
var _rock_instance: MultiMeshInstance3D
var _shrub_instance: MultiMeshInstance3D
var _last_anchor := Vector2(INF, INF)
var _dirty := true
var _elapsed := 0.0


func _ready() -> void:
	_store = get_node_or_null("/root/GameStore")
	_create_renderers()
	if _store != null:
		if _store.has_signal("city_changed"):
			_store.city_changed.connect(_mark_dirty)
		if _store.has_signal("terrain_changed"):
			_store.terrain_changed.connect(_mark_dirty)
	_mark_dirty()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 0.34:
		return
	_elapsed = 0.0
	if _store == null:
		_store = get_node_or_null("/root/GameStore")
	if _store == null:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var anchor := Vector2(camera.global_position.x, camera.global_position.z)
	var seed := int(_store.get("city_seed"))
	var ground_height := TerrainSurface.height(seed, anchor.x, anchor.y)
	var camera_height := camera.global_position.y - ground_height
	var visible := camera_height <= MAX_CAMERA_HEIGHT_METERS
	_rock_instance.visible = visible
	_shrub_instance.visible = visible
	if not visible:
		return
	if _dirty or anchor.distance_to(_last_anchor) >= REBUILD_DISTANCE_METERS:
		_rebuild(anchor, seed)


func _create_renderers() -> void:
	_rock_instance = MultiMeshInstance3D.new()
	_rock_instance.name = "ProceduralRocks"
	_rock_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_rock_instance.visibility_range_end = 2600.0
	_rock_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_rock_instance)

	_shrub_instance = MultiMeshInstance3D.new()
	_shrub_instance.name = "ProceduralShrubs"
	_shrub_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_shrub_instance.visibility_range_end = 1900.0
	_shrub_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_shrub_instance)


func _mark_dirty() -> void:
	_dirty = true


func _rebuild(anchor: Vector2, seed: int) -> void:
	_dirty = false
	_last_anchor = anchor
	var roads := _active_roads()
	var settlements := _settlements()
	var rock_transforms: Array[Transform3D] = []
	var rock_custom: Array[Color] = []
	var shrub_transforms: Array[Transform3D] = []
	var shrub_custom: Array[Color] = []
	var snapped := Vector2(
		round(anchor.x / SAMPLE_SPACING_METERS) * SAMPLE_SPACING_METERS,
		round(anchor.y / SAMPLE_SPACING_METERS) * SAMPLE_SPACING_METERS
	)
	var radius_steps := ceili(PATCH_RADIUS_METERS / SAMPLE_SPACING_METERS)

	for dz in range(-radius_steps, radius_steps + 1):
		for dx in range(-radius_steps, radius_steps + 1):
			if rock_transforms.size() >= MAX_ROCKS and shrub_transforms.size() >= MAX_SHRUBS:
				break
			var base := snapped + Vector2(float(dx), float(dz)) * SAMPLE_SPACING_METERS
			if base.distance_to(anchor) > PATCH_RADIUS_METERS:
				continue
			var point := base + Vector2(
				(_pseudo(base.x, base.y, 1, seed) - 0.5) * SAMPLE_SPACING_METERS * 0.84,
				(_pseudo(base.x, base.y, 2, seed) - 0.5) * SAMPLE_SPACING_METERS * 0.84
			)
			if _inside_settlement(point, settlements) or _near_any_road(point, roads):
				continue
			var sample := WorldLayers.sample_route_terrain(seed, point)
			var water_depth := float(sample.get("water_depth", 0.0))
			var slope := float(sample.get("slope_degrees", 0.0))
			if water_depth > 0.01 or slope > 38.0:
				continue
			var moisture := Terrain.regional_moisture(seed, point.x, point.y)
			var cover := Terrain.regional_ground_cover_potential(seed, point.x, point.y)
			var forest := Terrain.regional_forest_potential(seed, point.x, point.y)
			var ground := TerrainSurface.height(seed, point.x, point.y)
			var random_pick := _pseudo(point.x, point.y, 3, seed)

			if rock_transforms.size() < MAX_ROCKS:
				var rock_likelihood := clampf(
					0.08
					+ clampf((slope - 6.0) / 26.0, 0.0, 1.0) * 0.52
					+ (1.0 - cover) * 0.20
					+ abs(_pseudo(point.x, point.y, 8, seed) - 0.5) * 0.12,
					0.0,
					0.72
				)
				if random_pick < rock_likelihood * 0.48:
					var sx := lerpf(0.45, 1.65, _pseudo(point.x, point.y, 4, seed))
					var sy := lerpf(0.38, 1.20, _pseudo(point.x, point.y, 5, seed))
					var sz := lerpf(0.48, 1.55, _pseudo(point.x, point.y, 6, seed))
					var rotation := _pseudo(point.x, point.y, 7, seed) * TAU
					var basis := Basis(Vector3.UP, rotation).scaled(Vector3(sx, sy, sz))
					rock_transforms.append(Transform3D(basis, Vector3(point.x, ground + sy * 0.30, point.y)))
					rock_custom.append(Color(
						_pseudo(point.x, point.y, 9, seed),
						_pseudo(point.x, point.y, 10, seed),
						_pseudo(point.x, point.y, 11, seed),
						1.0
					))

			if shrub_transforms.size() < MAX_SHRUBS and slope < 28.0:
				var shrub_likelihood := clampf(
					(cover - 0.30) * 0.82
					+ (forest - 0.36) * 0.38
					+ moisture * 0.16,
					0.0,
					0.78
				)
				if _pseudo(point.x, point.y, 12, seed) < shrub_likelihood * 0.58:
					var shrub_scale := lerpf(0.62, 1.42, _pseudo(point.x, point.y, 13, seed))
					var shrub_width := shrub_scale * lerpf(0.82, 1.28, _pseudo(point.x, point.y, 14, seed))
					var shrub_height := shrub_scale * lerpf(0.65, 1.18, _pseudo(point.x, point.y, 15, seed))
					var rotation := _pseudo(point.x, point.y, 16, seed) * TAU
					var basis := Basis(Vector3.UP, rotation).scaled(Vector3(shrub_width, shrub_height, shrub_width))
					shrub_transforms.append(Transform3D(basis, Vector3(point.x, ground + shrub_height * 0.46, point.y)))
					shrub_custom.append(Color(
						_pseudo(point.x, point.y, 17, seed),
						_pseudo(point.x, point.y, 18, seed),
						clampf(moisture, 0.0, 1.0),
						1.0
					))
		if rock_transforms.size() >= MAX_ROCKS and shrub_transforms.size() >= MAX_SHRUBS:
			break

	_apply_multimesh(_rock_instance, _rock_mesh(), rock_transforms, rock_custom)
	_apply_multimesh(_shrub_instance, _shrub_mesh(), shrub_transforms, shrub_custom)


func _rock_mesh() -> Mesh:
	var mesh := SphereMesh.new()
	mesh.radius = 0.72
	mesh.height = 1.15
	mesh.radial_segments = 8
	mesh.rings = 5
	var material := ShaderMaterial.new()
	material.shader = DetailShader
	material.set_shader_parameter("base_color", Color(0.36, 0.37, 0.34))
	material.set_shader_parameter("roughness_value", 0.92)
	material.set_shader_parameter("color_variation", 0.18)
	material.set_shader_parameter("wind_strength", 0.0)
	mesh.material = material
	return mesh


func _shrub_mesh() -> Mesh:
	var mesh := SphereMesh.new()
	mesh.radius = 0.78
	mesh.height = 1.42
	mesh.radial_segments = 10
	mesh.rings = 6
	var material := ShaderMaterial.new()
	material.shader = DetailShader
	material.set_shader_parameter("base_color", Color(0.16, 0.31, 0.12))
	material.set_shader_parameter("roughness_value", 0.94)
	material.set_shader_parameter("color_variation", 0.24)
	material.set_shader_parameter("wind_strength", 0.055)
	material.set_shader_parameter("wind_speed", 0.78)
	mesh.material = material
	return mesh


func _apply_multimesh(
	instance: MultiMeshInstance3D,
	mesh: Mesh,
	transforms: Array[Transform3D],
	custom_data: Array[Color]
) -> void:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for index in range(transforms.size()):
		multi.set_instance_transform(index, transforms[index])
		multi.set_instance_custom_data(index, custom_data[index])
	instance.multimesh = multi


func _active_roads() -> Array:
	var result: Array = []
	if _store == null:
		return result
	var city: Dictionary = _store.get("city")
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("status", "")) in ["built", "constructing"]:
			result.append(road)
	return result


func _settlements() -> Array:
	if _store == null:
		return []
	var city: Dictionary = _store.get("city")
	return city.get("regional_settlements", [])


func _inside_settlement(point: Vector2, settlements: Array) -> bool:
	for settlement_value in settlements:
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var center: Vector2 = settlement.get("position", Vector2.ZERO)
		var radius := float(settlement.get("built_up_radius_m", 0.0)) * SETTLEMENT_CLEARANCE_FACTOR
		if radius > 0.0 and point.distance_to(center) <= radius:
			return true
	return false


func _near_any_road(point: Vector2, roads: Array) -> bool:
	for road_value in roads:
		var road: Dictionary = road_value
		var width := 15.0
		match str(road.get("class", "local")):
			"arterial": width = 31.0
			"collector": width = 21.0
			"service": width = 12.0
		var points: Array = road.get("points", [])
		for index in range(points.size() - 1):
			var a := _road_point(points[index])
			var b := _road_point(points[index + 1])
			if _distance_to_segment(point, a, b) < width * 0.5 + ROAD_CLEARANCE_METERS:
				return true
	return false


static func _road_point(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if typeof(value) == TYPE_DICTIONARY:
		var point: Dictionary = value
		return Vector2(float(point.get("x", 0.0)), float(point.get("y", 0.0)))
	return Vector2.ZERO


static func _distance_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq <= 0.000001:
		return point.distance_to(a)
	var t := clampf((point - a).dot(ab) / length_sq, 0.0, 1.0)
	return point.distance_to(a + ab * t)


static func _pseudo(x: float, z: float, channel: int, seed: int) -> float:
	var value := sin(
		x * 12.9898
		+ z * 78.233
		+ float(seed) * 0.00317
		+ float(channel) * 19.19
	) * 43758.5453
	return value - floor(value)
