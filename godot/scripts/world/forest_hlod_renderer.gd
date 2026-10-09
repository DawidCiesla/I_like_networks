extends Node3D
class_name ForestHlodRenderer

const Terrain = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const ForestHlodShader = preload("res://scripts/world/forest_hlod.gdshader")

const GRID_SPACING := 220.0
const VISIBILITY_BEGIN := 4700.0
const VISIBILITY_END := 22000.0
const MAX_INSTANCES := 6200

var _store: Node
var _instance: MultiMeshInstance3D
var _last_seed := -1


func _ready() -> void:
	_store = get_node_or_null("/root/GameStore")
	_create_instance()
	if _store != null and _store.has_signal("terrain_changed"):
		_store.terrain_changed.connect(rebuild)
	rebuild()


func _create_instance() -> void:
	_instance = MultiMeshInstance3D.new()
	_instance.name = "ForestHLOD"
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_instance.visibility_range_begin = VISIBILITY_BEGIN
	_instance.visibility_range_end = VISIBILITY_END
	_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES
	add_child(_instance)


func rebuild() -> void:
	if _store == null:
		_store = get_node_or_null("/root/GameStore")
	if _store == null:
		return
	var seed := int(_store.get("city_seed"))
	if seed == _last_seed and _instance.multimesh != null:
		return
	_last_seed = seed
	var bounds := TerrainSurface.world_bounds()
	var transforms: Array[Transform3D] = []
	var custom_data: Array[Color] = []
	var x := bounds.position.x + GRID_SPACING * 0.5
	while x < bounds.end.x and transforms.size() < MAX_INSTANCES:
		var z := bounds.position.y + GRID_SPACING * 0.5
		while z < bounds.end.y and transforms.size() < MAX_INSTANCES:
			var jitter_x := (_pseudo(x, z, 1, seed) - 0.5) * GRID_SPACING * 0.72
			var jitter_z := (_pseudo(x, z, 2, seed) - 0.5) * GRID_SPACING * 0.72
			var px := x + jitter_x
			var pz := z + jitter_z
			var forest := Terrain.regional_forest_potential(seed, px, pz)
			var accept := _pseudo(px, pz, 3, seed)
			var probability := clampf((forest - 0.50) * 2.15, 0.0, 0.95)
			if forest >= 0.52 and accept < probability:
				var ground := TerrainSurface.height(seed, px, pz)
				var width := lerpf(24.0, 52.0, forest) * lerpf(0.80, 1.25, _pseudo(px, pz, 4, seed))
				var height := lerpf(30.0, 64.0, forest) * lerpf(0.82, 1.18, _pseudo(px, pz, 5, seed))
				var basis := Basis(Vector3.UP, _pseudo(px, pz, 6, seed) * TAU).scaled(Vector3(width, height, width))
				transforms.append(Transform3D(basis, Vector3(px, ground + height * 0.5, pz)))
				custom_data.append(_forest_color(forest, px, pz, seed))
			z += GRID_SPACING
		x += GRID_SPACING

	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.18
	mesh.bottom_radius = 0.52
	mesh.height = 1.0
	mesh.radial_segments = 7
	mesh.rings = 1
	var material := ShaderMaterial.new()
	material.shader = ForestHlodShader
	mesh.material = material

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for index in range(transforms.size()):
		multi.set_instance_transform(index, transforms[index])
		multi.set_instance_custom_data(index, custom_data[index])
	_instance.multimesh = multi


func _forest_color(forest: float, x: float, z: float, seed: int) -> Color:
	var dry := Color(0.20, 0.30, 0.13)
	var lush := Color(0.10, 0.24, 0.095)
	var base := dry.lerp(lush, clampf(forest, 0.0, 1.0))
	var variation := _pseudo(x, z, 7, seed)
	var brightness := lerpf(0.86, 1.10, variation)
	return Color(
		clampf(base.r * brightness, 0.03, 1.0),
		clampf(base.g * brightness, 0.03, 1.0),
		clampf(base.b * brightness, 0.03, 1.0),
		variation
	)


static func _pseudo(x: float, z: float, channel: int, seed: int) -> float:
	var value := sin(
		x * 12.9898
		+ z * 78.233
		+ float(seed) * 0.00317
		+ float(channel) * 19.19
	) * 43758.5453
	return value - floor(value)
