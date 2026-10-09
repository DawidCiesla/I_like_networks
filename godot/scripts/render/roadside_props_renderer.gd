extends Node3D
class_name RoadsidePropsRenderer

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const RoadGeometry = preload("res://scripts/render/road_geometry.gd")

const ROAD_HALF_WIDTH := {
	"arterial": 15.5,
	"collector": 10.5,
	"local": 7.5,
	"service": 6.0,
}
const DELINEATOR_SPACING := 52.0
const DELINEATOR_CLEARANCE := 4.2
const GUARDRAIL_SAMPLE_SPACING := 13.0
const GUARDRAIL_CLEARANCE := 3.2
const GUARDRAIL_DROP_THRESHOLD := 1.35
const MAX_POSTS := 6200
const MAX_REFLECTORS := 6200
const MAX_RAILS := 2600

var _store: Node
var _posts: MultiMeshInstance3D
var _reflectors: MultiMeshInstance3D
var _rails: MultiMeshInstance3D
var _signature := ""


func _ready() -> void:
	_store = get_node_or_null("/root/GameStore")
	_create_renderers()
	if _store != null:
		if _store.has_signal("city_changed"):
			_store.city_changed.connect(_sync)
		if _store.has_signal("terrain_changed"):
			_store.terrain_changed.connect(_force_sync)
	_sync()


func _create_renderers() -> void:
	_posts = _new_instance("RoadsideDelineators", 5200.0)
	_reflectors = _new_instance("RoadsideReflectors", 4200.0)
	_rails = _new_instance("RoadsideGuardrails", 5200.0)


func _new_instance(instance_name: String, visibility_end: float) -> MultiMeshInstance3D:
	var instance := MultiMeshInstance3D.new()
	instance.name = instance_name
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	instance.visibility_range_end = visibility_end
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(instance)
	return instance


func _force_sync() -> void:
	_signature = ""
	_sync()


func _sync() -> void:
	if _store == null:
		_store = get_node_or_null("/root/GameStore")
	if _store == null:
		return
	var city_value: Variant = _store.get("city")
	if typeof(city_value) != TYPE_DICTIONARY:
		return
	var city: Dictionary = city_value
	var roads: Array = city.get("roads", [])
	var signature_parts: Array[String] = []
	for road_value in roads:
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if not _eligible_road(road):
			continue
		signature_parts.append("%s:%s:%s" % [
			str(road.get("id", "")),
			str(road.get("status", "")),
			str(road.get("class", "")),
		])
	signature_parts.sort()
	var signature := "|".join(signature_parts)
	if signature == _signature:
		return
	_signature = signature
	_rebuild(roads, int(_store.get("city_seed")))


func _rebuild(roads: Array, seed: int) -> void:
	var post_transforms: Array[Transform3D] = []
	var reflector_transforms: Array[Transform3D] = []
	var rail_transforms: Array[Transform3D] = []

	for road_value in roads:
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if not _eligible_road(road):
			continue
		var points := _road_points(road)
		if points.size() < 2:
			continue
		var road_class := str(road.get("class", "collector"))
		var half_width := float(ROAD_HALF_WIDTH.get(road_class, 8.0))
		_append_delineators(points, half_width, seed, post_transforms, reflector_transforms)
		_append_guardrails(points, half_width, seed, rail_transforms)

	_apply_multimesh(_posts, _post_mesh(), post_transforms)
	_apply_multimesh(_reflectors, _reflector_mesh(), reflector_transforms)
	_apply_multimesh(_rails, _rail_mesh(), rail_transforms)


func _append_delineators(
	points: Array[Vector2],
	half_width: float,
	seed: int,
	posts: Array[Transform3D],
	reflectors: Array[Transform3D]
) -> void:
	var samples := RoadGeometry.resample_polyline(points, DELINEATOR_SPACING)
	for index in range(1, samples.size() - 1):
		if posts.size() + 2 > MAX_POSTS or reflectors.size() + 2 > MAX_REFLECTORS:
			return
		var tangent := (samples[index + 1] - samples[index - 1]).normalized()
		if tangent.length_squared() <= 0.000001:
			continue
		var normal := Vector2(-tangent.y, tangent.x)
		var yaw := -atan2(tangent.y, tangent.x)
		for side in [-1.0, 1.0]:
			var point: Vector2 = samples[index] + normal * (half_width + DELINEATOR_CLEARANCE) * float(side)
			var ground := TerrainSurface.height(seed, point.x, point.y)
			var post_basis := Basis(Vector3.UP, yaw).scaled(Vector3(0.22, 1.15, 0.16))
			posts.append(Transform3D(post_basis, Vector3(point.x, ground + 0.575, point.y)))
			var reflector_point := point - normal * 0.10 * float(side)
			var reflector_basis := Basis(Vector3.UP, yaw).scaled(Vector3(0.20, 0.12, 0.035))
			reflectors.append(Transform3D(
				reflector_basis,
				Vector3(reflector_point.x, ground + 0.86, reflector_point.y)
			))


func _append_guardrails(
	points: Array[Vector2],
	half_width: float,
	seed: int,
	rails: Array[Transform3D]
) -> void:
	var samples := RoadGeometry.resample_polyline(points, GUARDRAIL_SAMPLE_SPACING)
	for index in range(samples.size() - 1):
		if rails.size() + 2 > MAX_RAILS:
			return
		var start: Vector2 = samples[index]
		var finish: Vector2 = samples[index + 1]
		var delta := finish - start
		var length := delta.length()
		if length <= 1.0:
			continue
		var tangent := delta / length
		var normal := Vector2(-tangent.y, tangent.x)
		var center := (start + finish) * 0.5
		var road_ground := TerrainSurface.height(seed, center.x, center.y)
		var yaw := -atan2(tangent.y, tangent.x)
		for side in [-1.0, 1.0]:
			var offset := half_width + GUARDRAIL_CLEARANCE
			var rail_point: Vector2 = center + normal * offset * float(side)
			var outside_point: Vector2 = center + normal * (offset + 5.5) * float(side)
			var outside_ground := TerrainSurface.height(seed, outside_point.x, outside_point.y)
			if road_ground - outside_ground < GUARDRAIL_DROP_THRESHOLD:
				continue
			var local_ground := TerrainSurface.height(seed, rail_point.x, rail_point.y)
			var rail_basis := Basis(Vector3.UP, yaw).scaled(Vector3(length + 0.4, 0.34, 0.18))
			rails.append(Transform3D(rail_basis, Vector3(rail_point.x, local_ground + 0.76, rail_point.y)))


func _eligible_road(road: Dictionary) -> bool:
	if str(road.get("status", "")) != "built":
		return false
	var role := str(road.get("regionalRole", ""))
	if role.is_empty():
		return false
	return role not in ["local_street", "city_connector"]


func _road_points(road: Dictionary) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for point_value in road.get("points", []):
		if point_value is Vector2:
			result.append(point_value)
		elif typeof(point_value) == TYPE_DICTIONARY:
			var point: Dictionary = point_value
			result.append(Vector2(float(point.get("x", 0.0)), float(point.get("y", 0.0))))
	return result


func _post_mesh() -> Mesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.88, 0.88, 0.82)
	material.roughness = 0.80
	mesh.material = material
	return mesh


func _reflector_mesh() -> Mesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.96, 0.80, 0.32)
	material.roughness = 0.28
	material.metallic = 0.08
	mesh.material = material
	return mesh


func _rail_mesh() -> Mesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.54, 0.56, 0.54)
	material.roughness = 0.48
	material.metallic = 0.72
	mesh.material = material
	return mesh


func _apply_multimesh(instance: MultiMeshInstance3D, mesh: Mesh, transforms: Array[Transform3D]) -> void:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for index in range(transforms.size()):
		multi.set_instance_transform(index, transforms[index])
	instance.multimesh = multi
