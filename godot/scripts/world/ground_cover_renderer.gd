extends Node3D
class_name GroundCoverRenderer

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const WorldLayers = preload("res://scripts/world/world_layers.gd")
const GrassShader = preload("res://scripts/world/ground_cover.gdshader")
const RoadSpatialIndex = preload("res://scripts/world/detail_road_spatial_index.gd")

const PATCH_RADIUS_METERS := 380.0
const SAMPLE_SPACING_METERS := 10.5
const REBUILD_DISTANCE_METERS := 110.0
const MAX_CAMERA_HEIGHT_METERS := 980.0
const ROAD_CLEARANCE_METERS := 18.0
const SETTLEMENT_CORE_FACTOR := 0.56
const MAX_INSTANCES := 5200
const BLADES_PER_TUFT := 10
const SLICE_BUDGET_USEC := 1200
const CAMERA_POLL_SECONDS := 0.12

var _instance: MultiMeshInstance3D
var _store: Node
var _last_anchor := Vector2(INF, INF)
var _dirty := true
var _elapsed := 0.0
var _grass_mesh_cache: ArrayMesh
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
var _build_transforms: Array[Transform3D] = []
var _build_custom_data: Array[Color] = []
var _build_settlements: Array = []
var _build_started_usec := 0
var _build_compute_usec := 0
var _queued_anchor := Vector2.ZERO
var _queued_seed := 0
var _has_queued_build := false


func _ready() -> void:
	_grass_mesh_cache = _grass_mesh()
	_instance = MultiMeshInstance3D.new()
	_instance.name = "ProceduralGrass"
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_instance.visibility_range_end = 1350.0
	_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_instance)
	_store = get_node_or_null("/root/GameStore")
	if _store != null:
		if _store.has_signal("city_changed"):
			_store.connect("city_changed", _on_city_changed)
		if _store.has_signal("terrain_changed"):
			_store.connect("terrain_changed", _mark_dirty)
	_refresh_road_count()
	_mark_dirty()


func _process(delta: float) -> void:
	if _build_active:
		_advance_build()
	if _store == null:
		_store = get_node_or_null("/root/GameStore")
		if _store == null:
			return
	_elapsed += delta
	if _elapsed < CAMERA_POLL_SECONDS:
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
		_request_build(ground_xz, seed)


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
	_build_transforms.clear()
	_build_custom_data.clear()
	_build_settlements.clear()
	var settlement_value: Variant = _city_state().get("regional_settlements", [])
	if typeof(settlement_value) == TYPE_ARRAY:
		_build_settlements = settlement_value
	if _road_index_dirty:
		_road_index.rebuild(_active_roads())
		_road_index_dirty = false
	_build_started_usec = Time.get_ticks_usec()
	_build_compute_usec = 0


func _advance_build() -> void:
	if not _build_active:
		return
	var slice_started := Time.get_ticks_usec()
	while _build_cursor < _build_total and _build_transforms.size() < MAX_INSTANCES:
		var flat_index := _build_cursor
		_build_cursor += 1
		var dx := flat_index % _build_side - _build_radius_steps
		var dz := flat_index / _build_side - _build_radius_steps
		_process_candidate(dx, dz)
		if Time.get_ticks_usec() - slice_started >= SLICE_BUDGET_USEC:
			break
	_build_compute_usec += Time.get_ticks_usec() - slice_started
	if _build_cursor >= _build_total or _build_transforms.size() >= MAX_INSTANCES:
		_finish_build()


func _process_candidate(dx: int, dz: int) -> void:
	var base := _build_snapped + Vector2(float(dx), float(dz)) * SAMPLE_SPACING_METERS
	if base.distance_to(_build_anchor) > PATCH_RADIUS_METERS:
		return
	var jitter := Vector2(
		(_pseudo(base.x, base.y, 1, _build_seed) - 0.5) * SAMPLE_SPACING_METERS * 0.82,
		(_pseudo(base.x, base.y, 2, _build_seed) - 0.5) * SAMPLE_SPACING_METERS * 0.82
	)
	var point := base + jitter
	if _inside_settlement_core(point, _build_settlements):
		return
	if _road_index.point_near_road(point, ROAD_CLEARANCE_METERS):
		return
	# The maximum acceptance is 0.94, so this is an exact cheap rejection.
	var acceptance_roll := _pseudo(point.x, point.y, 3, _build_seed)
	if acceptance_roll > 0.94:
		return
	var terrain_sample := WorldLayers.sample_route_terrain(_build_seed, point)
	if float(terrain_sample.get("water_depth", 0.0)) > 0.01:
		return
	if float(terrain_sample.get("slope_degrees", 0.0)) > 27.0:
		return
	var potential := Terrain.regional_ground_cover_potential(_build_seed, point.x, point.y)
	if potential < 0.24:
		return
	var acceptance := clampf((potential - 0.18) * 1.18, 0.0, 0.94)
	if acceptance_roll > acceptance:
		return
	var ground := TerrainSurface.height(_build_seed, point.x, point.y)
	var rotation := _pseudo(point.x, point.y, 4, _build_seed) * TAU
	var width_scale := lerpf(0.70, 1.48, _pseudo(point.x, point.y, 5, _build_seed))
	var height_scale := lerpf(0.44, 1.10, _pseudo(point.x, point.y, 6, _build_seed))
	var basis := Basis(Vector3.UP, rotation).scaled(Vector3(width_scale, height_scale, width_scale))
	_build_transforms.append(Transform3D(basis, Vector3(point.x, ground + 0.018, point.y)))
	var moisture := Terrain.regional_moisture(_build_seed, point.x, point.y)
	_build_custom_data.append(Color(
		_pseudo(point.x, point.y, 7, _build_seed),
		_pseudo(point.x, point.y, 8, _build_seed),
		moisture,
		1.0
	))


func _finish_build() -> void:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = _grass_mesh_cache
	multi.instance_count = _build_transforms.size()
	for index in range(_build_transforms.size()):
		multi.set_instance_transform(index, _build_transforms[index])
		multi.set_instance_custom_data(index, _build_custom_data[index])
	_instance.multimesh = multi
	_last_anchor = _build_anchor
	_build_active = false
	PerformanceProbe.record_duration("ground_cover_rebuild_ms", float(_build_compute_usec) / 1000.0)
	PerformanceProbe.record_duration(
		"ground_cover_rebuild_wall_ms",
		float(Time.get_ticks_usec() - _build_started_usec) / 1000.0
	)
	if _has_queued_build:
		var next_anchor := _queued_anchor
		var next_seed := _queued_seed
		_has_queued_build = false
		_start_build(next_anchor, next_seed)


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


static func _pseudo(x: float, z: float, channel: int, seed: int) -> float:
	var value := sin(
		x * 12.9898
		+ z * 78.233
		+ float(seed) * 0.00317
		+ float(channel) * 19.19
	) * 43758.5453
	return value - floor(value)
