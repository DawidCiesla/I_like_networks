extends Node3D
class_name BuildingHlodRenderer

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const HlodShader = preload("res://scripts/render/building_hlod.gdshader")

const MAX_INSTANCES := 5200
const VISIBILITY_BEGIN := 1700.0
const VISIBILITY_END := 18000.0

var _store: Node
var _instance: MultiMeshInstance3D
var _material: ShaderMaterial
var _signature := ""
var _last_night_strength := -1.0


func _ready() -> void:
	_store = get_node_or_null("/root/GameStore")
	_create_instance()
	if _store != null:
		if _store.has_signal("city_changed"):
			_store.city_changed.connect(_sync)
		if _store.has_signal("terrain_changed"):
			_store.terrain_changed.connect(_force_sync)
	_sync()
	_update_night_strength()


func _process(_delta: float) -> void:
	_update_night_strength()


func _create_instance() -> void:
	_instance = MultiMeshInstance3D.new()
	_instance.name = "RegionalBuildingHLOD"
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_instance.visibility_range_begin = VISIBILITY_BEGIN
	_instance.visibility_range_end = VISIBILITY_END
	_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES
	add_child(_instance)


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
	var buildings: Array = city.get("buildings", [])
	var parcels: Array = city.get("parcels", [])
	var seed := int(_store.get("city_seed"))
	var signature := _signature_for(buildings, parcels, seed)
	if signature == _signature:
		return
	_signature = signature
	_rebuild(buildings, parcels, seed)


func _signature_for(buildings: Array, parcels: Array, seed: int) -> String:
	var parts: Array[String] = ["seed:%d" % seed, "p:%d" % parcels.size(), "b:%d" % buildings.size()]
	for building_value in buildings:
		if typeof(building_value) != TYPE_DICTIONARY:
			continue
		var building: Dictionary = building_value
		var profile: Dictionary = building.get("profile", {})
		parts.append("%s:%s:%s:%d:%.1f:%.1f" % [
			str(building.get("id", "")),
			str(building.get("status", "")),
			str(profile.get("kind", "")),
			int(profile.get("floors", 1)),
			float(building.get("x", 0.0)),
			float(building.get("y", 0.0)),
		])
	parts.sort()
	return "|".join(parts)


func _rebuild(buildings: Array, parcels: Array, seed: int) -> void:
	var parcel_lookup: Dictionary = {}
	for parcel_value in parcels:
		if typeof(parcel_value) != TYPE_DICTIONARY:
			continue
		var parcel: Dictionary = parcel_value
		parcel_lookup[str(parcel.get("id", ""))] = parcel

	var transforms: Array[Transform3D] = []
	var custom_data: Array[Color] = []
	for building_value in buildings:
		if transforms.size() >= MAX_INSTANCES:
			break
		if typeof(building_value) != TYPE_DICTIONARY:
			continue
		var building: Dictionary = building_value
		if str(building.get("status", "built")) != "built":
			continue
		var parcel: Dictionary = parcel_lookup.get(str(building.get("parcelId", "")), {})
		if parcel.is_empty():
			continue
		var center := Vector2(
			float(building.get("x", parcel.get("x", 0.0))),
			float(building.get("y", parcel.get("y", 0.0)))
		)
		var profile: Dictionary = building.get("profile", {})
		var width := clampf(float(parcel.get("w", 18.0)) * 0.70, 7.0, 46.0)
		var depth := clampf(float(parcel.get("h", 18.0)) * 0.70, 7.0, 52.0)
		var floors := maxi(1, int(profile.get("floors", 1)))
		var height := maxf(3.6, float(profile.get("heightMeters", float(floors) * 3.2)))
		var angle := float(building.get("rotationRadians", 0.0))
		var ground := TerrainSurface.height(seed, center.x, center.y)
		var basis := Basis(Vector3.UP, -angle).scaled(Vector3(width, height, depth))
		transforms.append(Transform3D(basis, Vector3(center.x, ground + 0.7 + height * 0.5, center.y)))
		custom_data.append(_building_color(building, profile))

	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	_material = ShaderMaterial.new()
	_material.shader = HlodShader
	mesh.material = _material

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for index in range(transforms.size()):
		multi.set_instance_transform(index, transforms[index])
		multi.set_instance_custom_data(index, custom_data[index])
	_instance.multimesh = multi
	_last_night_strength = -1.0
	_update_night_strength()


func _building_color(building: Dictionary, profile: Dictionary) -> Color:
	var zone := str(building.get("zone", "residential"))
	var kind := str(profile.get("kind", "house"))
	var base := Color(0.58, 0.56, 0.50)
	match zone:
		"residential":
			base = Color(0.62, 0.57, 0.48)
		"commercial", "mixed":
			base = Color(0.55, 0.58, 0.58)
		"industrial":
			base = Color(0.45, 0.47, 0.45)
		"civic":
			base = Color(0.63, 0.63, 0.60)
	if kind in ["tower", "midrise", "apartment"]:
		base = base.lerp(Color(0.68, 0.70, 0.70), 0.28)
	var id_hash := posmod(hash(str(building.get("id", ""))), 1000)
	var variation := float(id_hash) / 999.0
	var brightness := lerpf(0.90, 1.08, variation)
	return Color(
		clampf(base.r * brightness, 0.05, 1.0),
		clampf(base.g * brightness, 0.05, 1.0),
		clampf(base.b * brightness, 0.05, 1.0),
		variation
	)


func _update_night_strength() -> void:
	if _material == null or _store == null:
		return
	var city_value: Variant = _store.get("city")
	if typeof(city_value) != TYPE_DICTIONARY:
		return
	var city: Dictionary = city_value
	var simulation_seconds := maxf(0.0, float(city.get("time_seconds", 0.0)))
	var hour := fposmod(8.0 + simulation_seconds / 3600.0, 24.0)
	var evening := smoothstep(18.0, 20.5, hour)
	var morning := 1.0 - smoothstep(5.4, 7.4, hour)
	var strength := clampf(maxf(evening, morning), 0.0, 1.0)
	if absf(strength - _last_night_strength) < 0.01:
		return
	_last_night_strength = strength
	_material.set_shader_parameter("night_strength", strength)
