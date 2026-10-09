extends Node3D
class_name RegionalRoadsideRenderer

const RoadGeometry = preload("res://scripts/render/road_geometry.gd")

const SHOULDER_WIDTH := {
	"arterial": 44.0,
	"collector": 33.0,
	"local": 25.0,
	"service": 21.0,
}
const SHOULDER_COLOR := {
	"arterial": Color("#786f5d"),
	"collector": Color("#756d5c"),
	"local": Color("#716b5d"),
	"service": Color("#6e695e"),
}
const SHOULDER_SURFACE_HEIGHT := 0.052

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
		signature_parts.append("%s:%s" % [str(road.get("id", "")), str(road.get("status", ""))])
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
		var mesh: Mesh = RoadGeometry.create_ribbon_mesh(
			seed,
			points,
			shoulder_width,
			SHOULDER_COLOR.get(road_class, Color("#716b5d")),
			SHOULDER_SURFACE_HEIGHT,
			10.0,
			true,
			false,
			0.0
		)
		if mesh == null:
			continue
		var instance := MeshInstance3D.new()
		instance.name = "RegionalShoulder_%s" % str(road.get("id", ""))
		instance.mesh = mesh
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(instance)


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
