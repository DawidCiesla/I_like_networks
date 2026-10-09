extends Node3D
class_name BuildingDetailRenderer

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")

const MAX_HEDGES := 1800
const MAX_SHRUBS := 2600
const MAX_UTILITY_DETAILS := 1400

var _store: Node
var _hedges: MultiMeshInstance3D
var _shrubs: MultiMeshInstance3D
var _utilities: MultiMeshInstance3D
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
	_hedges = MultiMeshInstance3D.new()
	_hedges.name = "ParcelHedges"
	_hedges.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_hedges.visibility_range_end = 2400.0
	_hedges.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_hedges)

	_shrubs = MultiMeshInstance3D.new()
	_shrubs.name = "ParcelShrubs"
	_shrubs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_shrubs.visibility_range_end = 1900.0
	_shrubs.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_shrubs)

	_utilities = MultiMeshInstance3D.new()
	_utilities.name = "BuildingUtilities"
	_utilities.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_utilities.visibility_range_end = 2100.0
	_utilities.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_utilities)


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
	var signature := _detail_signature(buildings, parcels, seed)
	if signature == _signature:
		return
	_signature = signature
	_rebuild(buildings, parcels, seed)


func _detail_signature(buildings: Array, parcels: Array, seed: int) -> String:
	var parts: Array[String] = ["seed:%d" % seed, "p:%d" % parcels.size()]
	for building_value in buildings:
		if typeof(building_value) != TYPE_DICTIONARY:
			continue
		var building: Dictionary = building_value
		var profile: Dictionary = building.get("profile", {})
		parts.append("%s:%s:%s:%.1f:%.1f:%.2f:%d" % [
			str(building.get("id", "")),
			str(building.get("parcelId", "")),
			str(profile.get("kind", "")),
			float(building.get("x", 0.0)),
			float(building.get("y", 0.0)),
			float(building.get("rotationRadians", 0.0)),
			int(profile.get("floors", 1)),
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

	var hedge_transforms: Array[Transform3D] = []
	var hedge_custom: Array[Color] = []
	var shrub_transforms: Array[Transform3D] = []
	var shrub_custom: Array[Color] = []
	var utility_transforms: Array[Transform3D] = []
	var utility_custom: Array[Color] = []

	for building_value in buildings:
		if typeof(building_value) != TYPE_DICTIONARY:
			continue
		var building: Dictionary = building_value
		if str(building.get("status", "built")) != "built":
			continue
		var parcel: Dictionary = parcel_lookup.get(str(building.get("parcelId", "")), {})
		if parcel.is_empty():
			continue
		var profile: Dictionary = building.get("profile", {})
		var kind := str(profile.get("kind", "house"))
		var center := Vector2(
			float(building.get("x", parcel.get("x", 0.0))),
			float(building.get("y", parcel.get("y", 0.0)))
		)
		var angle := float(building.get("rotationRadians", 0.0))
		var lateral := Vector2(cos(angle), sin(angle))
		var frontage := Vector2(-sin(angle), cos(angle))
		var parcel_width := maxf(8.0, float(parcel.get("w", 16.0)))
		var parcel_depth := maxf(8.0, float(parcel.get("h", 16.0)))
		var rear := center - frontage * parcel_depth * 0.34

		if kind in ["house", "townhouse"]:
			if hedge_transforms.size() < MAX_HEDGES:
				var hedge_length := clampf(parcel_width * 0.72, 5.0, 20.0)
				_append_hedge(hedge_transforms, hedge_custom, rear, lateral, hedge_length, seed)
			for side in [-1.0, 1.0]:
				if shrub_transforms.size() >= MAX_SHRUBS:
					break
				var shrub_point: Vector2 = rear + lateral * parcel_width * 0.29 * float(side) + frontage * 1.3
				_append_shrub(shrub_transforms, shrub_custom, shrub_point, building, seed)
		elif kind in ["apartment", "midrise", "tower", "shop", "civic", "campus"]:
			if shrub_transforms.size() < MAX_SHRUBS:
				var planter: Vector2 = center + frontage * parcel_depth * 0.30 + lateral * parcel_width * 0.26
				_append_shrub(shrub_transforms, shrub_custom, planter, building, seed)
			if utility_transforms.size() < MAX_UTILITY_DETAILS:
				var roof_point: Vector2 = center + lateral * parcel_width * 0.10 - frontage * parcel_depth * 0.06
				_append_utility(
					utility_transforms,
					utility_custom,
					roof_point,
					angle,
					building,
					seed,
					false,
					true
				)
		elif kind in ["workshop", "warehouse"]:
			for side in [-1.0, 1.0]:
				if utility_transforms.size() >= MAX_UTILITY_DETAILS:
					break
				var utility_point: Vector2 = rear + lateral * parcel_width * 0.20 * float(side)
				_append_utility(
					utility_transforms,
					utility_custom,
					utility_point,
					angle,
					building,
					seed,
					true,
					false
				)

	_apply_multimesh(_hedges, _hedge_mesh(), hedge_transforms, hedge_custom)
	_apply_multimesh(_shrubs, _shrub_mesh(), shrub_transforms, shrub_custom)
	_apply_multimesh(_utilities, _utility_mesh(), utility_transforms, utility_custom)


func _append_hedge(
	transforms: Array[Transform3D],
	custom_data: Array[Color],
	point: Vector2,
	direction: Vector2,
	length: float,
	seed: int
) -> void:
	var ground := TerrainSurface.height(seed, point.x, point.y)
	var yaw := -atan2(direction.y, direction.x)
	var height := 0.78 + _pseudo(point.x, point.y, 1, seed) * 0.44
	var basis := Basis(Vector3.UP, yaw).scaled(Vector3(length, height, 0.62))
	transforms.append(Transform3D(basis, Vector3(point.x, ground + height * 0.5, point.y)))
	custom_data.append(Color(
		_pseudo(point.x, point.y, 2, seed),
		_pseudo(point.x, point.y, 3, seed),
		0.78,
		1.0
	))


func _append_shrub(
	transforms: Array[Transform3D],
	custom_data: Array[Color],
	point: Vector2,
	building: Dictionary,
	seed: int
) -> void:
	var ground := TerrainSurface.height(seed, point.x, point.y)
	var scale := 0.55 + _pseudo(point.x, point.y, 4, seed) * 0.75
	var basis := Basis(Vector3.UP, _pseudo(point.x, point.y, 5, seed) * TAU).scaled(Vector3(scale, scale * 0.82, scale))
	transforms.append(Transform3D(basis, Vector3(point.x, ground + scale * 0.50, point.y)))
	custom_data.append(Color(
		_pseudo(point.x, point.y, 6, seed),
		_pseudo(point.x, point.y, 7, seed),
		float(posmod(hash(str(building.get("id", ""))), 100)) / 100.0,
		1.0
	))


func _append_utility(
	transforms: Array[Transform3D],
	custom_data: Array[Color],
	point: Vector2,
	angle: float,
	building: Dictionary,
	seed: int,
	industrial: bool,
	rooftop: bool
) -> void:
	var ground := TerrainSurface.height(seed, point.x, point.y)
	var size_x := (1.6 + _pseudo(point.x, point.y, 8, seed) * 1.9) if industrial else (1.0 + _pseudo(point.x, point.y, 8, seed) * 1.2)
	var size_z := (1.1 + _pseudo(point.x, point.y, 9, seed) * 1.6) if industrial else (0.8 + _pseudo(point.x, point.y, 9, seed) * 0.9)
	var size_y := (1.15 + _pseudo(point.x, point.y, 10, seed) * 1.1) if industrial else (0.7 + _pseudo(point.x, point.y, 10, seed) * 0.7)
	var profile: Dictionary = building.get("profile", {})
	var roof_height := maxf(2.8, float(profile.get("heightMeters", 3.2 * maxi(1, int(profile.get("floors", 1))))))
	var base_y := ground + roof_height + 0.18 if rooftop else ground
	var basis := Basis(Vector3.UP, -angle).scaled(Vector3(size_x, size_y, size_z))
	transforms.append(Transform3D(basis, Vector3(point.x, base_y + size_y * 0.5, point.y)))
	custom_data.append(Color(
		_pseudo(point.x, point.y, 11, seed),
		_pseudo(point.x, point.y, 12, seed),
		float(posmod(hash(str(building.get("zone", ""))), 100)) / 100.0,
		1.0
	))


func _hedge_mesh() -> Mesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.13, 0.27, 0.09)
	material.roughness = 0.96
	mesh.material = material
	return mesh


func _shrub_mesh() -> Mesh:
	var mesh := SphereMesh.new()
	mesh.radius = 0.78
	mesh.height = 1.15
	mesh.radial_segments = 9
	mesh.rings = 5
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.14, 0.31, 0.10)
	material.roughness = 0.94
	mesh.material = material
	return mesh


func _utility_mesh() -> Mesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.33, 0.35, 0.34)
	material.roughness = 0.74
	material.metallic = 0.16
	mesh.material = material
	return mesh


func _apply_multimesh(
	instance: MultiMeshInstance3D,
	mesh: Mesh,
	transforms: Array[Transform3D],
	custom_data: Array[Color]
) -> void:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for index in range(transforms.size()):
		multi.set_instance_transform(index, transforms[index])
		multi.set_instance_custom_data(index, custom_data[index])
	instance.multimesh = multi


static func _pseudo(x: float, z: float, channel: int, seed: int) -> float:
	var value := sin(
		x * 12.9898
		+ z * 78.233
		+ float(seed) * 0.00317
		+ float(channel) * 19.19
	) * 43758.5453
	return value - floor(value)
