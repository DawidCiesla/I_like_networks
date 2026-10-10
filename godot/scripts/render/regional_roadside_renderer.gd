extends Node3D
class_name RegionalRoadsideRenderer

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const RoadGeometry = preload("res://scripts/render/road_geometry.gd")
const ShoulderShader = preload("res://scripts/render/regional_shoulder.gdshader")

const SHOULDER_WIDTH := {
	"arterial": 44.0,
	"collector": 33.0,
	"local": 25.0,
	"service": 21.0,
}
const SHOULDER_SURFACE_HEIGHT := 0.052
# The shoulder is a low-frequency terrain transition, so sampling every ~16 m
# remains visually smooth while avoiding thousands of redundant height queries.
const SHOULDER_SAMPLE_SPACING := 16.0

var _store: Node
var _signature := ""


func _ready() -> void:
	_store = get_node_or_null("/root/GameStore")
	if _store != null:
		if _store.has_signal("city_changed"):
			_store.city_changed.connect(_sync)
		if _store.has_signal("terrain_changed"):
			_store.terrain_changed.connect(_force_sync)
	_sync()


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
		if not _uses_natural_shoulder(road):
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
	for child in get_children():
		child.queue_free()
	for road_value in roads:
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if not _uses_natural_shoulder(road):
			continue
		var points: Array[Vector2] = _road_points(road)
		if points.size() < 2:
			continue
		var road_class := str(road.get("class", "local"))
		var shoulder_width := float(SHOULDER_WIDTH.get(road_class, 25.0))
		var mesh: Mesh = _create_shoulder_mesh(seed, points, shoulder_width)
		if mesh == null:
			continue
		var instance := MeshInstance3D.new()
		instance.name = "RegionalShoulder_%s" % str(road.get("id", ""))
		instance.mesh = mesh
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(instance)


func _create_shoulder_mesh(seed: int, source_points: Array[Vector2], width: float) -> Mesh:
	var points := RoadGeometry.resample_polyline(source_points, SHOULDER_SAMPLE_SPACING)
	if points.size() < 2:
		return null
	var material := ShaderMaterial.new()
	material.shader = ShoulderShader
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
	var half_width := width * 0.5
	var cumulative: Array[float] = [0.0]
	var left_vertices: Array[Vector3] = []
	var right_vertices: Array[Vector3] = []

	# Compute both terrain-conforming edge vertices once per polyline sample.
	# The old triangle-by-triangle path queried TerrainSurface up to three times
	# for the same location, which made long regional roads expensive at startup.
	for index in range(points.size()):
		if index > 0:
			cumulative.append(cumulative.back() + points[index - 1].distance_to(points[index]))
		var tangent := _tangent(points, index)
		var normal := Vector2(-tangent.y, tangent.x)
		var left_point := points[index] + normal * half_width
		var right_point := points[index] - normal * half_width
		left_vertices.append(_terrain_vertex(seed, left_point))
		right_vertices.append(_terrain_vertex(seed, right_point))

	for index in range(points.size() - 1):
		var u0 := cumulative[index] / 18.0
		var u1 := cumulative[index + 1] / 18.0
		_add_cached_vertex(mesh, left_vertices[index], Vector2(u0, 0.0))
		_add_cached_vertex(mesh, left_vertices[index + 1], Vector2(u1, 0.0))
		_add_cached_vertex(mesh, right_vertices[index], Vector2(u0, 1.0))
		_add_cached_vertex(mesh, right_vertices[index], Vector2(u0, 1.0))
		_add_cached_vertex(mesh, left_vertices[index + 1], Vector2(u1, 0.0))
		_add_cached_vertex(mesh, right_vertices[index + 1], Vector2(u1, 1.0))
	mesh.surface_end()
	return mesh


func _tangent(points: Array[Vector2], index: int) -> Vector2:
	if index <= 0:
		return (points[1] - points[0]).normalized()
	if index >= points.size() - 1:
		return (points[index] - points[index - 1]).normalized()
	var tangent := (points[index + 1] - points[index - 1]).normalized()
	if tangent.length_squared() <= 0.000001:
		return (points[index] - points[index - 1]).normalized()
	return tangent


func _terrain_vertex(seed: int, point: Vector2) -> Vector3:
	return Vector3(
		point.x,
		TerrainSurface.height(seed, point.x, point.y) + SHOULDER_SURFACE_HEIGHT,
		point.y
	)


func _add_cached_vertex(mesh: ImmediateMesh, vertex: Vector3, uv: Vector2) -> void:
	mesh.surface_set_normal(Vector3.UP)
	mesh.surface_set_uv(uv)
	mesh.surface_add_vertex(vertex)


func _uses_natural_shoulder(road: Dictionary) -> bool:
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
