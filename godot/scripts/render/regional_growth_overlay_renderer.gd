extends Node3D
class_name RegionalGrowthOverlayRenderer

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")

const SETTLEMENT_HEIGHT := 0.30
const PARCEL_HEIGHT := 0.42
const MAX_PARCEL_MARKERS := 420

var _store: Node
var _enabled := false
var _signature := ""
var _mesh_root: Node3D
var _legend_layer: CanvasLayer
var _legend_panel: PanelContainer


func _ready() -> void:
	_store = get_node_or_null("/root/GameStore")
	_mesh_root = Node3D.new()
	_mesh_root.name = "GrowthOverlayGeometry"
	add_child(_mesh_root)
	visible = false
	_build_legend()
	if _store != null and _store.has_signal("city_changed"):
		_store.city_changed.connect(_sync)


func set_enabled(value: bool) -> void:
	_enabled = value
	visible = value
	if is_instance_valid(_legend_layer):
		_legend_layer.visible = value
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
	var signature := _growth_signature(city)
	if signature == _signature:
		return
	_signature = signature
	_rebuild(city, int(_store.get("city_seed")))


func _rebuild(city: Dictionary, seed: int) -> void:
	if not is_instance_valid(_mesh_root):
		return
	for child in _mesh_root.get_children():
		child.queue_free()

	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var center := _point(settlement.get("position", Vector2.ZERO))
		var access_available := bool(settlement.get("mobilityAccessibilityAvailable", false))
		var access := clampf(float(settlement.get("mobilityAccessibility", 0.0)), 0.0, 1.0)
		var growth := maxf(0.0, float(settlement.get("growthPressure", 0.0)))
		var development := clampf(float(settlement.get("developmentPressure", 0.0)), 0.0, 1.0)
		var radius := clampf(float(settlement.get("built_up_radius_m", 500.0)) * 0.42, 150.0, 650.0)
		_add_disk(
			seed,
			center,
			radius,
			SETTLEMENT_HEIGHT,
			_growth_color(growth),
			0.17
		)
		_add_settlement_label(seed, settlement, center, access_available, access, growth, development)

	var parcel_count := 0
	for parcel_value in city.get("parcels", []):
		if parcel_count >= MAX_PARCEL_MARKERS:
			break
		if typeof(parcel_value) != TYPE_DICTIONARY:
			continue
		var parcel: Dictionary = parcel_value
		if str(parcel.get("status", "")) != "vacant" or not bool(parcel.get("developmentPressureAvailable", false)):
			continue
		var point := Vector2(float(parcel.get("x", 0.0)), float(parcel.get("y", 0.0)))
		var pressure := clampf(float(parcel.get("developmentPressure", 0.0)), 0.0, 1.0)
		_add_disk(seed, point, 11.0, PARCEL_HEIGHT, _development_color(pressure), 0.68)
		parcel_count += 1


func _add_disk(
	seed: int,
	point: Vector2,
	radius: float,
	height_offset: float,
	color: Color,
	alpha: float
) -> void:
	if not is_instance_valid(_mesh_root):
		return
	var instance := MeshInstance3D.new()
	var disk := CylinderMesh.new()
	disk.top_radius = radius
	disk.bottom_radius = radius
	disk.height = 0.22
	disk.radial_segments = 32
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color.r, color.g, color.b, alpha)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disk.material = material
	instance.mesh = disk
	instance.position = Vector3(
		point.x,
		TerrainSurface.height(seed, point.x, point.y) + height_offset,
		point.y
	)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_root.add_child(instance)


func _add_settlement_label(
	seed: int,
	settlement: Dictionary,
	point: Vector2,
	access_available: bool,
	access: float,
	growth: float,
	development: float
) -> void:
	if not is_instance_valid(_mesh_root):
		return
	var label := Label3D.new()
	var access_text := "%d" % roundi(access * 100.0) if access_available else "--"
	label.text = "%s\nA %s · G %.2f · D %d" % [
		str(settlement.get("name", settlement.get("id", "Settlement"))).to_upper(),
		access_text,
		growth,
		roundi(development * 100.0),
	]
	label.position = Vector3(
		point.x,
		TerrainSurface.height(seed, point.x, point.y) + 18.0,
		point.y
	)
	label.font_size = 18
	label.outline_size = 5
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(1.0, 1.0, 1.0, 0.94)
	_mesh_root.add_child(label)


func _build_legend() -> void:
	_legend_layer = CanvasLayer.new()
	_legend_layer.layer = 41
	add_child(_legend_layer)
	_legend_panel = PanelContainer.new()
	_legend_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_legend_panel.offset_left = 18.0
	_legend_panel.offset_top = 84.0
	_legend_panel.offset_right = 330.0
	_legend_panel.offset_bottom = 156.0
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_legend_panel.add_child(margin)
	var label := Label.new()
	label.text = "GROWTH MAP [G]\nA = accessibility · G = growth pressure · D = parcel development pressure"
	label.add_theme_font_size_override("font_size", 11)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	margin.add_child(label)
	_legend_layer.add_child(_legend_panel)
	_legend_layer.visible = false


static func _growth_color(growth_pressure: float) -> Color:
	if growth_pressure < 0.35:
		return Color(0.93, 0.20, 0.16)
	if growth_pressure < 0.58:
		return Color(0.94, 0.63, 0.18)
	if growth_pressure < 0.90:
		return Color(0.38, 0.83, 0.31)
	return Color(0.12, 0.78, 0.64)


static func _development_color(score: float) -> Color:
	if score < 0.30:
		return Color(0.90, 0.18, 0.16)
	if score < 0.50:
		return Color(0.95, 0.53, 0.16)
	if score < 0.70:
		return Color(0.88, 0.82, 0.22)
	return Color(0.24, 0.82, 0.38)


static func _growth_signature(city: Dictionary) -> String:
	var parts: Array[String] = []
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		parts.append("s:%s:%.3f:%.3f:%.3f" % [
			str(settlement.get("id", "")),
			float(settlement.get("mobilityAccessibility", 0.0)),
			float(settlement.get("growthPressure", 0.0)),
			float(settlement.get("developmentPressure", 0.0)),
		])
	for parcel_value in city.get("parcels", []):
		if typeof(parcel_value) != TYPE_DICTIONARY:
			continue
		var parcel: Dictionary = parcel_value
		if str(parcel.get("status", "")) != "vacant" or not bool(parcel.get("developmentPressureAvailable", false)):
			continue
		parts.append("p:%s:%.3f" % [
			str(parcel.get("id", "")),
			float(parcel.get("developmentPressure", 0.0)),
		])
	parts.sort()
	return "|".join(parts)


static func _point(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if typeof(value) == TYPE_DICTIONARY:
		var raw: Dictionary = value
		return Vector2(float(raw.get("x", 0.0)), float(raw.get("y", 0.0)))
	return Vector2.ZERO
