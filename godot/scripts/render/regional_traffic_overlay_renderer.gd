extends Node3D
class_name RegionalTrafficOverlayRenderer

const RoadGeometry = preload("res://scripts/render/road_geometry.gd")

const OVERLAY_HEIGHT := 0.42
const SAMPLE_SPACING := 18.0
const ROAD_WIDTHS := {
	"service": 9.0,
	"local": 11.0,
	"collector": 15.0,
	"arterial": 22.0,
}

var _store: Node
var _enabled := false
var _signature := ""


func _ready() -> void:
	_store = get_node_or_null("/root/GameStore")
	visible = false
	if _store != null and _store.has_signal("city_changed"):
		_store.city_changed.connect(_sync)


func set_enabled(value: bool) -> void:
	_enabled = value
	visible = value
	if value:
		_signature = ""
		_sync()


func toggle() -> bool:
	set_enabled(not _enabled)
	return _enabled


func is_enabled() -> bool:
	return _enabled


func _sync() -> void:
	if not _enabled:
		return
	if _store == null:
		_store = get_node_or_null("/root/GameStore")
	if _store == null:
		return
	var city_value: Variant = _store.get("city")
	if typeof(city_value) != TYPE_DICTIONARY:
		return
	var city: Dictionary = city_value
	var roads: Array = city.get("roads", [])
	var signature := _traffic_signature(roads)
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
		if str(road.get("status", "")) != "built":
			continue
		var traffic_value: Variant = road.get("traffic", {})
		if typeof(traffic_value) != TYPE_DICTIONARY or (traffic_value as Dictionary).is_empty():
			continue
		var points := _road_points(road)
		if points.size() < 2:
			continue
		var road_class := str(road.get("class", "local"))
		var width := float(ROAD_WIDTHS.get(road_class, 11.0))
		var vc := maxf(0.0, float((traffic_value as Dictionary).get("vc_ratio", 0.0)))
		var mesh: Mesh = RoadGeometry.create_ribbon_mesh(
			seed,
			points,
			width,
			_traffic_color(vc),
			OVERLAY_HEIGHT,
			SAMPLE_SPACING,
			true,
			true,
			0.08
		)
		if mesh == null:
			continue
		var instance := MeshInstance3D.new()
		instance.name = "Traffic_%s" % str(road.get("id", ""))
		instance.mesh = mesh
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(instance)


static func _traffic_color(vc_ratio: float) -> Color:
	var vc := maxf(0.0, vc_ratio)
	if vc < 0.65:
		return Color(0.20, 0.84, 0.42, 0.58)
	if vc < 0.85:
		return Color(0.92, 0.82, 0.24, 0.62)
	if vc < 1.0:
		return Color(0.97, 0.48, 0.14, 0.66)
	return Color(0.95, 0.16, 0.12, 0.72)


static func _road_points(road: Dictionary) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for point_value in road.get("points", []):
		if point_value is Vector2:
			result.append(point_value)
		elif typeof(point_value) == TYPE_DICTIONARY:
			var point: Dictionary = point_value
			result.append(Vector2(float(point.get("x", 0.0)), float(point.get("y", 0.0))))
	return result


static func _traffic_signature(roads: Array) -> String:
	var parts: Array[String] = []
	for road_value in roads:
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		var traffic_value: Variant = road.get("traffic", {})
		if typeof(traffic_value) != TYPE_DICTIONARY:
			continue
		var traffic: Dictionary = traffic_value
		parts.append("%s:%s:%.3f:%.2f" % [
			str(road.get("id", "")),
			str(road.get("status", "")),
			float(traffic.get("vc_ratio", 0.0)),
			float(traffic.get("flow_vph", 0.0)),
		])
	parts.sort()
	return "|".join(parts)
