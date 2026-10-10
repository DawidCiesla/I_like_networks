extends Node3D
class_name RiparianDetailRenderer

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const WorldLayers = preload("res://scripts/world/world_layers.gd")
const DetailShader = preload("res://scripts/world/landscape_detail.gdshader")

const PATCH_RADIUS_METERS := 335.0
const SAMPLE_SPACING_METERS := 13.5
const BANK_PROBE_METERS := 18.0
const REBUILD_DISTANCE_METERS := 86.0
const MAX_CAMERA_HEIGHT_METERS := 760.0
const MAX_INSTANCES := 2800
const BLADES_PER_CLUMP := 9

var _store: Node
var _instance: MultiMeshInstance3D
var _last_anchor := Vector2(INF, INF)
var _dirty := true
var _elapsed := 0.0


func _ready() -> void:
	_store = get_node_or_null("/root/GameStore")
	_instance = MultiMeshInstance3D.new()
	_instance.name = "RiparianReeds"
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_instance.visibility_range_end = 1200.0
	_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_instance)
	if _store != null and _store.has_signal("terrain_changed"):
		_store.terrain_changed.connect(_mark_dirty)
	_mark_dirty()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 0.31:
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
		_rebuild(anchor, seed)


func _mark_dirty() -> void:
	_dirty = true


func _rebuild(anchor: Vector2, seed: int) -> void:
	var perf_started_usec := Time.get_ticks_usec()
	_dirty = false
	_last_anchor = anchor
	var transforms: Array[Transform3D] = []
	var custom_data: Array[Color] = []
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
			var point := base + Vector2(
				(_pseudo(base.x, base.y, 1, seed) - 0.5) * SAMPLE_SPACING_METERS * 0.76,
				(_pseudo(base.x, base.y, 2, seed) - 0.5) * SAMPLE_SPACING_METERS * 0.76
			)
			var water := WorldLayers.sample_water(seed, point)
			var depth := float(water.get("water_depth", 0.0))
			var bank_strength := _bank_strength(seed, point, depth)
			if bank_strength <= 0.0:
				continue
			var route_sample := WorldLayers.sample_route_terrain(seed, point)
			if float(route_sample.get("slope_degrees", 0.0)) > 18.0:
				continue
			var moisture := Terrain.regional_moisture(seed, point.x, point.y)
			if moisture < 0.48:
				continue
			var acceptance := clampf(bank_strength * 0.68 + moisture * 0.24, 0.0, 0.90)
			if _pseudo(point.x, point.y, 3, seed) > acceptance:
				continue
			var scale := lerpf(0.68, 1.48, _pseudo(point.x, point.y, 4, seed))
			var width := scale * lerpf(0.72, 1.18, _pseudo(point.x, point.y, 5, seed))
			var height := scale * lerpf(0.72, 1.36, _pseudo(point.x, point.y, 6, seed))
			var basis := Basis(Vector3.UP, _pseudo(point.x, point.y, 7, seed) * TAU).scaled(Vector3(width, height, width))
			var ground := TerrainSurface.height(seed, point.x, point.y)
			transforms.append(Transform3D(basis, Vector3(point.x, ground + 0.035, point.y)))
			custom_data.append(Color(
				_pseudo(point.x, point.y, 8, seed),
				_pseudo(point.x, point.y, 9, seed),
				moisture,
				1.0
			))
		if transforms.size() >= MAX_INSTANCES:
			break

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = _reed_mesh()
	multi.instance_count = transforms.size()
	for index in range(transforms.size()):
		multi.set_instance_transform(index, transforms[index])
		multi.set_instance_custom_data(index, custom_data[index])
	_instance.multimesh = multi
	PerformanceProbe.record_duration(
		"riparian_detail_rebuild_ms",
		float(Time.get_ticks_usec() - perf_started_usec) / 1000.0
	)


func _bank_strength(seed: int, point: Vector2, depth: float) -> float:
	if depth > 0.02 and depth <= 1.15:
		return clampf(1.0 - depth / 1.35, 0.18, 0.88)
	if depth > 1.15:
		return 0.0
	var nearest_water := 0.0
	for offset in [
		Vector2(BANK_PROBE_METERS, 0.0),
		Vector2(-BANK_PROBE_METERS, 0.0),
		Vector2(0.0, BANK_PROBE_METERS),
		Vector2(0.0, -BANK_PROBE_METERS),
	]:
		var neighbor := WorldLayers.sample_water(seed, point + offset)
		nearest_water = maxf(nearest_water, float(neighbor.get("water_depth", 0.0)))
	return clampf(nearest_water / 0.9, 0.0, 0.82)


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
