extends Node3D
class_name RiparianDetailRenderer

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const WorldLayers = preload("res://scripts/world/world_layers.gd")
const DetailShader = preload("res://scripts/world/landscape_detail.gdshader")

const PATCH_RADIUS_METERS := 335.0
const SAMPLE_SPACING_METERS := 17.0
const REBUILD_DISTANCE_METERS := 105.0
const MAX_CAMERA_HEIGHT_METERS := 760.0
const MAX_INSTANCES := 1800
const BLADES_PER_CLUMP := 8
const SLICE_BUDGET_USEC := 850
const CAMERA_POLL_SECONDS := 0.12

var _store: Node
var _instance: MultiMeshInstance3D
var _reed_mesh_cache: ArrayMesh
var _last_anchor := Vector2(INF, INF)
var _dirty := true
var _elapsed := 0.0

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
var _build_started_usec := 0
var _build_compute_usec := 0
var _queued_anchor := Vector2.ZERO
var _queued_seed := 0
var _has_queued_build := false


func _ready() -> void:
	_store = get_node_or_null("/root/GameStore")
	_reed_mesh_cache = _reed_mesh()
	_instance = MultiMeshInstance3D.new()
	_instance.name = "RiparianReeds"
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_instance.visibility_range_end = 1050.0
	_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_instance)
	if _store != null and _store.has_signal("terrain_changed"):
		_store.terrain_changed.connect(_mark_dirty)
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
	var camera_height := camera.global_position.y - TerrainSurface.height(seed, anchor.x, anchor.y)
	_instance.visible = camera_height <= MAX_CAMERA_HEIGHT_METERS
	if not _instance.visible:
		return
	if _dirty or anchor.distance_to(_last_anchor) >= REBUILD_DISTANCE_METERS:
		_request_build(anchor, seed)


func _mark_dirty() -> void:
	_dirty = true


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
		var dz := floori(float(flat_index) / float(_build_side)) - _build_radius_steps
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
	var point := base + Vector2(
		(_pseudo(base.x, base.y, 1, _build_seed) - 0.5) * SAMPLE_SPACING_METERS * 0.76,
		(_pseudo(base.x, base.y, 2, _build_seed) - 0.5) * SAMPLE_SPACING_METERS * 0.76
	)
	# River floodplain data is already calculated by the terrain sampler and is
	# much cheaper than probing water four extra times around every candidate.
	var river := Terrain.river_profile(_build_seed, point.x, point.y)
	var bank_strength := maxf(
		float(river.get("major_floodplain", 0.0)),
		float(river.get("minor_floodplain", 0.0)) * 0.78
	)
	if bank_strength < 0.075:
		return
	var acceptance_roll := _pseudo(point.x, point.y, 3, _build_seed)
	if acceptance_roll > 0.90:
		return
	var route_sample := WorldLayers.sample_route_terrain(_build_seed, point)
	var depth := float(route_sample.get("water_depth", 0.0))
	if depth > 1.20:
		return
	var slope := float(route_sample.get("slope_degrees", 0.0))
	if slope > 18.0:
		return
	var moisture := Terrain.regional_moisture(_build_seed, point.x, point.y)
	if moisture < 0.46:
		return
	var shallow_bonus := 0.28 if depth > 0.01 else 0.0
	var acceptance := clampf(bank_strength * 0.60 + moisture * 0.22 + shallow_bonus, 0.0, 0.90)
	if acceptance_roll > acceptance:
		return
	var scale := lerpf(0.68, 1.48, _pseudo(point.x, point.y, 4, _build_seed))
	var width := scale * lerpf(0.72, 1.18, _pseudo(point.x, point.y, 5, _build_seed))
	var height := scale * lerpf(0.72, 1.36, _pseudo(point.x, point.y, 6, _build_seed))
	var basis := Basis(Vector3.UP, _pseudo(point.x, point.y, 7, _build_seed) * TAU).scaled(Vector3(width, height, width))
	var ground := TerrainSurface.height(_build_seed, point.x, point.y)
	_build_transforms.append(Transform3D(basis, Vector3(point.x, ground + 0.035, point.y)))
	_build_custom_data.append(Color(
		_pseudo(point.x, point.y, 8, _build_seed),
		_pseudo(point.x, point.y, 9, _build_seed),
		moisture,
		1.0
	))


func _finish_build() -> void:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = _reed_mesh_cache
	multi.instance_count = _build_transforms.size()
	for index in range(_build_transforms.size()):
		multi.set_instance_transform(index, _build_transforms[index])
		multi.set_instance_custom_data(index, _build_custom_data[index])
	_instance.multimesh = multi
	_last_anchor = _build_anchor
	_build_active = false
	PerformanceProbe.record_duration("riparian_detail_rebuild_ms", float(_build_compute_usec) / 1000.0)
	PerformanceProbe.record_duration(
		"riparian_detail_rebuild_wall_ms",
		float(Time.get_ticks_usec() - _build_started_usec) / 1000.0
	)
	if _has_queued_build:
		var next_anchor := _queued_anchor
		var next_seed := _queued_seed
		_has_queued_build = false
		_start_build(next_anchor, next_seed)


static func _reed_mesh() -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for blade_index in range(BLADES_PER_CLUMP):
		var fraction := float(blade_index) / float(BLADES_PER_CLUMP)
		var angle := TAU * fraction + sin(float(blade_index) * 2.73) * 0.35
		var radius := 0.08 + 0.26 * (0.5 + 0.5 * sin(float(blade_index) * 4.39))
		var center := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		var right := Vector3(cos(angle), 0.0, sin(angle)) * 0.045
		var height := 1.05 + 0.72 * (0.5 + 0.5 * sin(float(blade_index) * 3.91))
		var lean := Vector3(-sin(angle), 0.0, cos(angle)) * (0.035 + fraction * 0.06)
		var bottom_left := center - right
		var bottom_right := center + right
		var top := center + lean + Vector3.UP * height
		tool.set_uv(Vector2(0.0, 0.0))
		tool.add_vertex(bottom_left)
		tool.set_uv(Vector2(1.0, 0.0))
		tool.add_vertex(bottom_right)
		tool.set_uv(Vector2(0.5, 1.0))
		tool.add_vertex(top)
	tool.generate_normals()
	var result := tool.commit()
	var material := ShaderMaterial.new()
	material.shader = DetailShader
	material.set_shader_parameter("base_color", Color(0.23, 0.34, 0.095))
	material.set_shader_parameter("roughness_value", 0.93)
	material.set_shader_parameter("color_variation", 0.24)
	material.set_shader_parameter("wind_strength", 0.095)
	material.set_shader_parameter("wind_speed", 1.05)
	result.surface_set_material(0, material)
	return result


static func _pseudo(x: float, z: float, channel: int, seed: int) -> float:
	var value := sin(
		x * 12.9898
		+ z * 78.233
		+ float(seed) * 0.00317
		+ float(channel) * 19.19
	) * 43758.5453
	return value - floor(value)
