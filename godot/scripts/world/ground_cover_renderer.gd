extends Node3D
class_name GroundCoverRenderer

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const WorldLayers = preload("res://scripts/world/world_layers.gd")
const GrassShader = preload("res://scripts/world/ground_cover.gdshader")

const PATCH_RADIUS_METERS := 380.0
const SAMPLE_SPACING_METERS := 8.5
const REBUILD_DISTANCE_METERS := 92.0
const MAX_CAMERA_HEIGHT_METERS := 980.0
const ROAD_CLEARANCE_METERS := 18.0
const SETTLEMENT_CORE_FACTOR := 0.56
const MAX_INSTANCES := 7800
const BLADES_PER_TUFT := 10

var _instance: MultiMeshInstance3D
var _store: Node
var _last_anchor := Vector2(INF, INF)
var _dirty := true
var _elapsed := 0.0


func _ready() -> void:
	_instance = MultiMeshInstance3D.new()
	_instance.name = "ProceduralGrass"
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_instance.visibility_range_end = 1500.0
	_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_instance)
	_store = get_node_or_null("/root/GameStore")
	if _store != null:
		if _store.has_signal("city_changed"):
			_store.connect("city_changed", _mark_dirty)
		if _store.has_signal("terrain_changed"):
			_store.connect("terrain_changed", _mark_dirty)
	_mark_dirty()


func _process(delta: float) -> void:
	if _store == null:
		_store = get_node_or_null("/root/GameStore")
		if _store == null:
			return
	_elapsed += delta
	if _elapsed < 0.28:
		return
	_elapsed = 0.0
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var ground_xz := Vector2(camera.global_position.x, camera.global_position.z)
	var seed := _city_seed()
	var ground_height := TerrainSurface.height(seed, ground_xz.x, ground_xz.y)
	var camera_height := camera.global_position.y - ground_height
	if camera_height > MAX_CAMERA_HEIGHT_METERS:
		_instance.visible = false
		return
	_instance.visible = true
	if _dirty or ground_xz.distance_to(_last_anchor) >= REBUILD_DISTANCE_METERS:
		_rebuild(ground_xz)


func _mark_dirty() -> void:
	_dirty = true


func _rebuild(anchor: Vector2) -> void:
	var perf_started_usec := Time.get_ticks_usec()
	_dirty = false
	_last_anchor = anchor
	var mesh: ArrayMesh = _grass_mesh()
	var transforms: Array[Transform3D] = []
	var custom_data: Array[Color] = []
	var roads: Array = _active_roads()
	var city := _city_state()
	var settlements: Array = []
	var settlement_value: Variant = city.get("regional_settlements", [])
	if typeof(settlement_value) == TYPE_ARRAY:
		settlements = settlement_value
	var seed := _city_seed()
	var snapped := Vector2(
		round(anchor.x / SAMPLE_SPACING_METERS) * SAMPLE_SPACING_METERS,
		round(anchor.y / SAMPLE_SPACING_METERS) * SAMPLE_SPACING_METERS
	)
	var radius_steps := ceili(PATCH_RADIUS_METERS / SAMPLE_SPACING_METERS)
	for dz in range(-radius_steps, radius_steps + 1):
		for dx in range(-radius_steps, radius_steps + 1):
			if transforms.size() >= MAX_INSTANCES:
				break
			var base := snapped + Vector2(float(dx), float(dz)) * SAMPLE_SPACING_METERS
			if base.distance_to(anchor) > PATCH_RADIUS_METERS:
				continue
			var jitter := Vector2(
				(_pseudo(base.x, base.y, 1, seed) - 0.5) * SAMPLE_SPACING_METERS * 0.82,
				(_pseudo(base.x, base.y, 2, seed) - 0.5) * SAMPLE_SPACING_METERS * 0.82
			)
			var point := base + jitter
			if _inside_settlement_core(point, settlements):
				continue
			if _near_any_road(point, roads):
				continue
			var terrain_sample := WorldLayers.sample_route_terrain(seed, point)
			if float(terrain_sample.get("water_depth", 0.0)) > 0.01:
				continue
			if float(terrain_sample.get("slope_degrees", 0.0)) > 27.0:
				continue
			var potential := Terrain.regional_ground_cover_potential(seed, point.x, point.y)
			if potential < 0.24:
				continue
			var acceptance := clampf((potential - 0.18) * 1.18, 0.0, 0.94)
			if _pseudo(point.x, point.y, 3, seed) > acceptance:
				continue
			var ground := TerrainSurface.height(seed, point.x, point.y)
			var rotation := _pseudo(point.x, point.y, 4, seed) * TAU
			var width_scale := lerpf(0.70, 1.48, _pseudo(point.x, point.y, 5, seed))
			var height_scale := lerpf(0.44, 1.10, _pseudo(point.x, point.y, 6, seed))
			var basis := Basis(Vector3.UP, rotation).scaled(Vector3(width_scale, height_scale, width_scale))
			transforms.append(Transform3D(basis, Vector3(point.x, ground + 0.018, point.y)))
			var moisture := Terrain.regional_moisture(seed, point.x, point.y)
			custom_data.append(Color(
				_pseudo(point.x, point.y, 7, seed),
				_pseudo(point.x, point.y, 8, seed),
				moisture,
				1.0
			))
		if transforms.size() >= MAX_INSTANCES:
			break

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for index in range(transforms.size()):
		multi.set_instance_transform(index, transforms[index])
		multi.set_instance_custom_data(index, custom_data[index])
	_instance.multimesh = multi
	PerformanceProbe.record_duration(
		"ground_cover_rebuild_ms",
		float(Time.get_ticks_usec() - perf_started_usec) / 1000.0
	)


static func _grass_mesh() -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for blade_index in range(BLADES_PER_TUFT):
		var fraction := float(blade_index) / float(BLADES_PER_TUFT)
		var angle := TAU * fraction + sin(float(blade_index) * 2.37) * 0.31
		var radial := 0.055 + 0.19 * (0.5 + 0.5 * sin(float(blade_index) * 4.17))
		var center := Vector3(cos(angle) * radial, 0.0, sin(angle) * radial)
		var width := 0.075 + 0.045 * (0.5 + 0.5 * sin(float(blade_index) * 3.11))
		var height := 0.72 + 0.33 * (0.5 + 0.5 * sin(float(blade_index) * 5.07))
		var right := Vector3(cos(angle), 0.0, sin(angle)) * width
		var lean := Vector3(-sin(angle), 0.0, cos(angle)) * (0.055 + 0.075 * fraction)
		var bottom_left := center - right
		var bottom_right := center + right
		var top_center := center + lean + Vector3.UP * height
		var top_left := top_center - right * 0.18
		var top_right := top_center + right * 0.18

		tool.set_uv(Vector2(0.0, 0.0))
		tool.add_vertex(bottom_left)
		tool.set_uv(Vector2(1.0, 0.0))
		tool.add_vertex(bottom_right)
		tool.set_uv(Vector2(1.0, 1.0))
		tool.add_vertex(top_right)

		tool.set_uv(Vector2(0.0, 0.0))
		tool.add_vertex(bottom_left)
		tool.set_uv(Vector2(1.0, 1.0))
		tool.add_vertex(top_right)
		tool.set_uv(Vector2(0.0, 1.0))
		tool.add_vertex(top_left)
	tool.generate_normals()
	var result := tool.commit()
	var material := ShaderMaterial.new()
	material.shader = GrassShader
	result.surface_set_material(0, material)
	return result


func _city_seed() -> int:
	return int(_store.get("city_seed")) if _store != null else 0


func _city_state() -> Dictionary:
	if _store == null:
		return {}
	var value: Variant = _store.get("city")
	return value if typeof(value) == TYPE_DICTIONARY else {}


func _active_roads() -> Array:
	var result: Array = []
	var city := _city_state()
	if city.is_empty():
		return result
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("status", "")) in ["built", "constructing"]:
			result.append(road)
	return result


func _inside_settlement_core(point: Vector2, settlements: Array) -> bool:
	for settlement_value in settlements:
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var center: Vector2 = settlement.get("position", Vector2.ZERO)
		var radius := float(settlement.get("built_up_radius_m", 0.0)) * SETTLEMENT_CORE_FACTOR
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
