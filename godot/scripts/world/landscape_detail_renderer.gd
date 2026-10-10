extends Node3D
class_name LandscapeDetailRenderer

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const WorldLayers = preload("res://scripts/world/world_layers.gd")
const DetailShader = preload("res://scripts/world/landscape_detail.gdshader")
const RoadSpatialIndex = preload("res://scripts/world/detail_road_spatial_index.gd")

const PATCH_RADIUS_METERS := 880.0
const SAMPLE_SPACING_METERS := 38.0
const REBUILD_DISTANCE_METERS := 210.0
const MAX_CAMERA_HEIGHT_METERS := 1900.0
const MAX_ROCKS := 1000
const MAX_SHRUBS := 1700
const ROAD_CLEARANCE_METERS := 22.0
const SETTLEMENT_CLEARANCE_FACTOR := 0.78
const SLICE_BUDGET_USEC := 950
const CAMERA_POLL_SECONDS := 0.15

var _store: Node
var _rock_instance: MultiMeshInstance3D
var _shrub_instance: MultiMeshInstance3D
var _rock_mesh_cache: Mesh
var _shrub_mesh_cache: Mesh
var _last_anchor := Vector2(INF, INF)
var _dirty := true
var _elapsed := 0.0
var _road_index := RoadSpatialIndex.new()
var _road_count := -1
var _road_index_dirty := true

var _build_active := false
var _build_anchor := Vector2.ZERO
var _build_seed := 0
var _build_snapped := Vector2.ZERO
var _build_radius_steps := 0
var _build_side := 0
var _build_cursor := 0
var _build_total := 0
var _rock_transforms: Array[Transform3D] = []
var _rock_custom: Array[Color] = []
var _shrub_transforms: Array[Transform3D] = []
var _shrub_custom: Array[Color] = []
var _build_settlements: Array = []
var _build_started_usec := 0
var _build_compute_usec := 0
var _queued_anchor := Vector2.ZERO
var _queued_seed := 0
var _has_queued_build := false


func _ready() -> void:
	_store = get_node_or_null("/root/GameStore")
	_rock_mesh_cache = _rock_mesh()
	_shrub_mesh_cache = _shrub_mesh()
	_create_renderers()
	if _store != null:
		if _store.has_signal("city_changed"):
			_store.city_changed.connect(_on_city_changed)
		if _store.has_signal("terrain_changed"):
			_store.terrain_changed.connect(_mark_dirty)
	_refresh_road_count()
	_mark_dirty()


func _process(delta: float) -> void:
	if _build_active:
		_advance_build()
	_elapsed += delta
	if _elapsed < CAMERA_POLL_SECONDS:
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
		_request_build(anchor, seed)


func _create_renderers() -> void:
	_rock_instance = MultiMeshInstance3D.new()
	_rock_instance.name = "ProceduralRocks"
	_rock_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_rock_instance.visibility_range_end = 2400.0
	_rock_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_rock_instance)

	_shrub_instance = MultiMeshInstance3D.new()
	_shrub_instance.name = "ProceduralShrubs"
	_shrub_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shrub_instance.visibility_range_end = 1700.0
	_shrub_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_shrub_instance)


func _on_city_changed() -> void:
	var previous := _road_count
	_refresh_road_count()
	if previous != _road_count:
		_road_index_dirty = true
		_dirty = true


func _refresh_road_count() -> void:
	_road_count = _active_roads().size()


func _mark_dirty() -> void:
	_dirty = true
	_road_index_dirty = true


func _request_build(anchor: Vector2, seed: int) -> void:
	if _build_active:
		_queued_anchor = anchor
		_queued_seed = seed
		_has_queued_build = true
		return
	_start_build(anchor, seed)


func _start_build(anchor: Vector2, seed: int) -> void:
	_dirty = false
	_build_active = true
	_build_anchor = anchor
	_build_seed = seed
	_build_snapped = Vector2(
		round(anchor.x / SAMPLE_SPACING_METERS) * SAMPLE_SPACING_METERS,
		round(anchor.y / SAMPLE_SPACING_METERS) * SAMPLE_SPACING_METERS
	)
	_build_radius_steps = ceili(PATCH_RADIUS_METERS / SAMPLE_SPACING_METERS)
	_build_side = _build_radius_steps * 2 + 1
	_build_cursor = 0
	_build_total = _build_side * _build_side
	_rock_transforms.clear()
	_rock_custom.clear()
	_shrub_transforms.clear()
	_shrub_custom.clear()
	_build_settlements = _settlements()
	if _road_index_dirty:
		_road_index.rebuild(_active_roads())
		_road_index_dirty = false
	_build_started_usec = Time.get_ticks_usec()
	_build_compute_usec = 0


func _advance_build() -> void:
	if not _build_active:
		return
	var slice_started := Time.get_ticks_usec()
	while _build_cursor < _build_total:
		if _rock_transforms.size() >= MAX_ROCKS and _shrub_transforms.size() >= MAX_SHRUBS:
			break
		var flat_index := _build_cursor
		_build_cursor += 1
		var dx := flat_index % _build_side - _build_radius_steps
		var dz := floori(float(flat_index) / float(_build_side)) - _build_radius_steps
		_process_candidate(dx, dz)
		if Time.get_ticks_usec() - slice_started >= SLICE_BUDGET_USEC:
			break
	_build_compute_usec += Time.get_ticks_usec() - slice_started
	if _build_cursor >= _build_total or (_rock_transforms.size() >= MAX_ROCKS and _shrub_transforms.size() >= MAX_SHRUBS):
		_finish_build()


func _process_candidate(dx: int, dz: int) -> void:
	var base := _build_snapped + Vector2(float(dx), float(dz)) * SAMPLE_SPACING_METERS
	if base.distance_to(_build_anchor) > PATCH_RADIUS_METERS:
		return
	var point := base + Vector2(
		(_pseudo(base.x, base.y, 1, _build_seed) - 0.5) * SAMPLE_SPACING_METERS * 0.84,
		(_pseudo(base.x, base.y, 2, _build_seed) - 0.5) * SAMPLE_SPACING_METERS * 0.84
	)
	if _inside_settlement(point, _build_settlements) or _road_index.point_near_road(point, ROAD_CLEARANCE_METERS):
		return
	var rock_roll := _pseudo(point.x, point.y, 3, _build_seed)
	var shrub_roll := _pseudo(point.x, point.y, 12, _build_seed)
	if rock_roll >= 0.346 and shrub_roll >= 0.453:
		return
	var sample := WorldLayers.sample_route_terrain(_build_seed, point)
	var water_depth := float(sample.get("water_depth", 0.0))
	var slope := float(sample.get("slope_degrees", 0.0))
	if water_depth > 0.01 or slope > 38.0:
		return
	var moisture := Terrain.regional_moisture(_build_seed, point.x, point.y)
	var cover := Terrain.regional_ground_cover_potential(_build_seed, point.x, point.y)
	var forest := Terrain.regional_forest_potential(_build_seed, point.x, point.y)
	var ground := TerrainSurface.height(_build_seed, point.x, point.y)

	if _rock_transforms.size() < MAX_ROCKS:
		var rock_likelihood := clampf(
			0.08
			+ clampf((slope - 6.0) / 26.0, 0.0, 1.0) * 0.52
			+ (1.0 - cover) * 0.20
			+ abs(_pseudo(point.x, point.y, 8, _build_seed) - 0.5) * 0.12,
			0.0,
			0.72
		)
		if rock_roll < rock_likelihood * 0.48:
			var sx := lerpf(0.45, 1.65, _pseudo(point.x, point.y, 4, _build_seed))
			var sy := lerpf(0.38, 1.20, _pseudo(point.x, point.y, 5, _build_seed))
			var sz := lerpf(0.48, 1.55, _pseudo(point.x, point.y, 6, _build_seed))
			var rotation := _pseudo(point.x, point.y, 7, _build_seed) * TAU
			var basis := Basis(Vector3.UP, rotation).scaled(Vector3(sx, sy, sz))
			_rock_transforms.append(Transform3D(basis, Vector3(point.x, ground + sy * 0.30, point.y)))
			_rock_custom.append(Color(
				_pseudo(point.x, point.y, 9, _build_seed),
				_pseudo(point.x, point.y, 10, _build_seed),
				_pseudo(point.x, point.y, 11, _build_seed),
				1.0
			))

	if _shrub_transforms.size() < MAX_SHRUBS and slope < 28.0:
		var shrub_likelihood := clampf(
			(cover - 0.30) * 0.82
			+ (forest - 0.36) * 0.38
			+ moisture * 0.16,
			0.0,
			0.78
		)
		if shrub_roll < shrub_likelihood * 0.58:
			var shrub_scale := lerpf(0.62, 1.42, _pseudo(point.x, point.y, 13, _build_seed))
			var shrub_width := shrub_scale * lerpf(0.82, 1.28, _pseudo(point.x, point.y, 14, _build_seed))
			var shrub_height := shrub_scale * lerpf(0.65, 1.18, _pseudo(point.x, point.y, 15, _build_seed))
			var rotation := _pseudo(point.x, point.y, 16, _build_seed) * TAU
			var basis := Basis(Vector3.UP, rotation).scaled(Vector3(shrub_width, shrub_height, shrub_width))
			_shrub_transforms.append(Transform3D(basis, Vector3(point.x, ground + shrub_height * 0.46, point.y)))
			_shrub_custom.append(Color(
				_pseudo(point.x, point.y, 17, _build_seed),
				_pseudo(point.x, point.y, 18, _build_seed),
				clampf(moisture, 0.0, 1.0),
				1.0
			))


func _finish_build() -> void:
	_apply_multimesh(_rock_instance, _rock_mesh_cache, _rock_transforms, _rock_custom)
	_apply_multimesh(_shrub_instance, _shrub_mesh_cache, _shrub_transforms, _shrub_custom)
	_last_anchor = _build_anchor
	_build_active = false
	PerformanceProbe.record_duration("landscape_detail_rebuild_ms", float(_build_compute_usec) / 1000.0)
	PerformanceProbe.record_duration(
		"landscape_detail_rebuild_wall_ms",
		float(Time.get_ticks_usec() - _build_started_usec) / 1000.0
	)
	if _has_queued_build:
		var next_anchor := _queued_anchor
		var next_seed := _queued_seed
		_has_queued_build = false
		_start_build(next_anchor, next_seed)


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
	mesh.radial_segments = 8
	mesh.rings = 5
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


static func _pseudo(x: float, z: float, channel: int, seed: int) -> float:
	var value := sin(
		x * 12.9898
		+ z * 78.233
		+ float(seed) * 0.00317
		+ float(channel) * 19.19
	) * 43758.5453
	return value - floor(value)
