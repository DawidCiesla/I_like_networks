extends Node3D
class_name BridgeDetailRenderer

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")

const ROAD_WIDTH := {
	"arterial": 31.0,
	"collector": 21.0,
	"local": 15.0,
	"service": 12.0,
}
const DECK_OFFSET := 2.865
const PIER_SPACING := 72.0
const MAX_PIERS := 1800
const MAX_GIRDERS := 2200
const MAX_ABUTMENTS := 600

var _store: Node
var _piers: MultiMeshInstance3D
var _girders: MultiMeshInstance3D
var _abutments: MultiMeshInstance3D
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
	_piers = _new_instance("BridgePiers", 9000.0)
	_girders = _new_instance("BridgeGirders", 10000.0)
	_abutments = _new_instance("BridgeAbutments", 9000.0)


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
	var signature := _bridge_signature(roads)
	if signature == _signature:
		return
	_signature = signature
	_rebuild(roads, int(_store.get("city_seed")))


func _bridge_signature(roads: Array) -> String:
	var parts: Array[String] = []
	for road_value in roads:
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		var crossings: Array = road.get("bridgeCrossings", [])
		if crossings.is_empty() or str(road.get("status", "")) != "built":
			continue
		parts.append("%s:%s:%d" % [
			str(road.get("id", "")),
			str(road.get("class", "")),
			crossings.size(),
		])
	parts.sort()
	return "|".join(parts)


func _rebuild(roads: Array, seed: int) -> void:
	var pier_transforms: Array[Transform3D] = []
	var girder_transforms: Array[Transform3D] = []
	var abutment_transforms: Array[Transform3D] = []

	for road_value in roads:
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("status", "")) != "built":
			continue
		var crossings: Array = road.get("bridgeCrossings", [])
		if crossings.is_empty():
			continue
		var road_width := float(ROAD_WIDTH.get(str(road.get("class", "local")), 15.0))
		for crossing_value in crossings:
			if typeof(crossing_value) != TYPE_DICTIONARY:
				continue
			var crossing: Dictionary = crossing_value
			var path := _crossing_path(crossing)
			if path.size() < 2:
				continue
			_append_girders(path, road_width, seed, girder_transforms)
			_append_piers(path, road_width, seed, pier_transforms)
			_append_abutments(path, road_width, seed, abutment_transforms)

	_apply_multimesh(_piers, _pier_mesh(), pier_transforms)
	_apply_multimesh(_girders, _girder_mesh(), girder_transforms)
	_apply_multimesh(_abutments, _abutment_mesh(), abutment_transforms)


func _crossing_path(crossing: Dictionary) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var start := _point(crossing.get("start", Vector2.ZERO))
	var finish := _point(crossing.get("end", Vector2.ZERO))
	result.append(start)
	for water_value in crossing.get("water_points", []):
		var water_point := _point(water_value)
		if result.back().distance_to(water_point) > 0.5:
			result.append(water_point)
	if result.back().distance_to(finish) > 0.5:
		result.append(finish)
	return result


func _append_girders(
	path: Array[Vector2],
	road_width: float,
	seed: int,
	transforms: Array[Transform3D]
) -> void:
	for index in range(path.size() - 1):
		if transforms.size() + 2 > MAX_GIRDERS:
			return
		var start := path[index]
		var finish := path[index + 1]
		var delta := finish - start
		var length := delta.length()
		if length <= 1.0:
			continue
		var tangent := delta / length
		var normal := Vector2(-tangent.y, tangent.x)
		var center := (start + finish) * 0.5
		var yaw := -atan2(tangent.y, tangent.x)
		for side in [-1.0, 1.0]:
			var point := center + normal * road_width * 0.43 * float(side)
			var deck_y := _deck_height(seed, center)
			var basis := Basis(Vector3.UP, yaw).scaled(Vector3(length + 0.6, 0.72, 0.42))
			transforms.append(Transform3D(basis, Vector3(point.x, deck_y - 0.72, point.y)))


func _append_piers(
	path: Array[Vector2],
	road_width: float,
	seed: int,
	transforms: Array[Transform3D]
) -> void:
	var samples := _resample_path(path, PIER_SPACING)
	for index in range(1, samples.size() - 1):
		if transforms.size() + 2 > MAX_PIERS:
			return
		var point := samples[index]
		var tangent := (samples[index + 1] - samples[index - 1]).normalized()
		if tangent.length_squared() <= 0.000001:
			continue
		var normal := Vector2(-tangent.y, tangent.x)
		var yaw := -atan2(tangent.y, tangent.x)
		var deck_y := _deck_height(seed, point) - 0.65
		for side in [-1.0, 1.0]:
			var pier_point := point + normal * road_width * 0.27 * float(side)
			var ground_y := TerrainSurface.height(seed, pier_point.x, pier_point.y)
			var height := maxf(1.4, deck_y - ground_y)
			if height <= 1.55:
				continue
			var width := clampf(road_width * 0.10, 1.1, 2.6)
			var depth := clampf(road_width * 0.12, 1.3, 3.0)
			var basis := Basis(Vector3.UP, yaw).scaled(Vector3(width, height, depth))
			transforms.append(Transform3D(
				basis,
				Vector3(pier_point.x, ground_y + height * 0.5, pier_point.y)
			))


func _append_abutments(
	path: Array[Vector2],
	road_width: float,
	seed: int,
	transforms: Array[Transform3D]
) -> void:
	if path.size() < 2 or transforms.size() + 2 > MAX_ABUTMENTS:
		return
	for endpoint_index in [0, path.size() - 1]:
		var endpoint := path[endpoint_index]
		var neighbor := path[1] if endpoint_index == 0 else path[path.size() - 2]
		var tangent := (neighbor - endpoint).normalized()
		if tangent.length_squared() <= 0.000001:
			continue
		var yaw := -atan2(tangent.y, tangent.x)
		var ground_y := TerrainSurface.height(seed, endpoint.x, endpoint.y)
		var deck_y := _deck_height(seed, endpoint)
		var height := maxf(1.2, deck_y - ground_y)
		var basis := Basis(Vector3.UP, yaw).scaled(Vector3(
			clampf(road_width * 0.96, 9.0, 32.0),
			height,
			2.4
		))
		transforms.append(Transform3D(basis, Vector3(endpoint.x, ground_y + height * 0.5, endpoint.y)))


func _deck_height(seed: int, point: Vector2) -> float:
	return TerrainSurface.height(seed, point.x, point.y) + DECK_OFFSET


func _resample_path(path: Array[Vector2], spacing: float) -> Array[Vector2]:
	var result: Array[Vector2] = []
	if path.is_empty():
		return result
	result.append(path[0])
	for segment_index in range(path.size() - 1):
		var start := path[segment_index]
		var finish := path[segment_index + 1]
		var length := start.distance_to(finish)
		if length <= 0.5:
			continue
		var steps := maxi(1, ceili(length / maxf(4.0, spacing)))
		for step in range(1, steps + 1):
			var point := start.lerp(finish, float(step) / float(steps))
			if result.back().distance_to(point) > 0.5:
				result.append(point)
	return result


func _point(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if typeof(value) == TYPE_DICTIONARY:
		var point: Dictionary = value
		return Vector2(float(point.get("x", 0.0)), float(point.get("y", 0.0)))
	return Vector2.ZERO


func _pier_mesh() -> Mesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.47, 0.49, 0.47)
	material.roughness = 0.91
	mesh.material = material
	return mesh


func _girder_mesh() -> Mesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.28, 0.31, 0.30)
	material.roughness = 0.50
	material.metallic = 0.62
	mesh.material = material
	return mesh


func _abutment_mesh() -> Mesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.43, 0.44, 0.41)
	material.roughness = 0.94
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
