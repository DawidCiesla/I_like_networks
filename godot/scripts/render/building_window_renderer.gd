extends Node3D
class_name BuildingWindowRenderer

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const WindowShader = preload("res://scripts/render/building_windows.gdshader")

const MAX_WINDOWS := 9000
const VISIBILITY_END := 2300.0

var _store: Node
var _windows: MultiMeshInstance3D
var _material: ShaderMaterial
var _signature := ""
var _last_night_strength := -1.0


func _ready() -> void:
	_store = get_node_or_null("/root/GameStore")
	_create_renderer()
	if _store != null:
		if _store.has_signal("city_changed"):
			_store.city_changed.connect(_sync)
		if _store.has_signal("terrain_changed"):
			_store.terrain_changed.connect(_force_sync)
	_sync()
	_update_night_strength()


func _process(_delta: float) -> void:
	_update_night_strength()


func _create_renderer() -> void:
	_windows = MultiMeshInstance3D.new()
	_windows.name = "BuildingWindows"
	_windows.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_windows.visibility_range_end = VISIBILITY_END
	_windows.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_windows)


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
		parts.append("%s:%s:%d:%.1f:%.1f:%.2f" % [
			str(building.get("id", "")),
			str(building.get("status", "")),
			int(profile.get("floors", 1)),
			float(building.get("x", 0.0)),
			float(building.get("y", 0.0)),
			float(building.get("rotationRadians", 0.0)),
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
		if transforms.size() >= MAX_WINDOWS:
			break
		if typeof(building_value) != TYPE_DICTIONARY:
			continue
		var building: Dictionary = building_value
		if str(building.get("status", "built")) != "built":
			continue
		var parcel: Dictionary = parcel_lookup.get(str(building.get("parcelId", "")), {})
		if parcel.is_empty():
			continue
		_append_building_windows(building, parcel, seed, transforms, custom_data)

	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	_material = ShaderMaterial.new()
	_material.shader = WindowShader
	mesh.material = _material

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for index in range(transforms.size()):
		multi.set_instance_transform(index, transforms[index])
		multi.set_instance_custom_data(index, custom_data[index])
	_windows.multimesh = multi
	_last_night_strength = -1.0
	_update_night_strength()


func _append_building_windows(
	building: Dictionary,
	parcel: Dictionary,
	seed: int,
	transforms: Array[Transform3D],
	custom_data: Array[Color]
) -> void:
	var center := Vector2(
		float(building.get("x", parcel.get("x", 0.0))),
		float(building.get("y", parcel.get("y", 0.0)))
	)
	var profile: Dictionary = building.get("profile", {})
	var floors := clampi(int(profile.get("floors", 1)), 1, 10)
	var kind := str(profile.get("kind", "house"))
	var angle := float(building.get("rotationRadians", 0.0))
	var lateral := Vector2(cos(angle), sin(angle))
	var frontage := Vector2(-sin(angle), cos(angle))
	var parcel_width := maxf(8.0, float(parcel.get("w", 16.0)))
	var parcel_depth := maxf(8.0, float(parcel.get("h", 16.0)))
	var facade_point := center + frontage * parcel_depth * 0.345
	var ground := TerrainSurface.height(seed, center.x, center.y)
	var columns := clampi(roundi(parcel_width / 6.0), 1, 5)
	if kind in ["warehouse", "workshop"]:
		columns = mini(columns, 3)
	var rows := floors
	if kind == "shop":
		rows = mini(2, floors)
	var span := minf(parcel_width * 0.58, float(columns - 1) * 4.4)
	for row in range(rows):
		for column in range(columns):
			if transforms.size() >= MAX_WINDOWS:
				return
			var normalized := 0.0 if columns <= 1 else float(column) / float(columns - 1) - 0.5
			var point := facade_point + lateral * span * normalized
			var random_value := _pseudo(point.x, point.y, row * 17 + column, seed)
			if random_value < 0.30:
				continue
			var window_width := 1.05 + _pseudo(point.x, point.y, 101 + row, seed) * 0.60
			var window_height := 1.05 + _pseudo(point.x, point.y, 131 + column, seed) * 0.55
			if kind == "shop" and row == 0:
				window_width *= 1.65
				window_height *= 1.30
			var y := ground + 1.65 + float(row) * 3.05
			var basis := Basis(Vector3.UP, -angle).scaled(Vector3(window_width, window_height, 0.07))
			transforms.append(Transform3D(basis, Vector3(point.x, y, point.y)))
			custom_data.append(_window_style(building, point, row, column, seed))


func _window_style(building: Dictionary, point: Vector2, row: int, column: int, seed: int) -> Color:
	var warmth := _pseudo(point.x, point.y, 200 + row * 7 + column, seed)
	var occupancy := 0.42 + _pseudo(point.x, point.y, 260 + row * 11 + column, seed) * 0.58
	var warm := Color(1.0, 0.68, 0.34)
	var neutral := Color(0.76, 0.86, 1.0)
	var tint := warm.lerp(neutral, smoothstep(0.58, 0.88, warmth))
	var zone := str(building.get("zone", "residential"))
	if zone == "commercial":
		tint = tint.lerp(Color(0.91, 0.94, 1.0), 0.22)
	return Color(tint.r, tint.g, tint.b, occupancy)


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


static func _pseudo(x: float, z: float, channel: int, seed: int) -> float:
	var value := sin(
		x * 12.9898
		+ z * 78.233
		+ float(seed) * 0.00317
		+ float(channel) * 19.19
	) * 43758.5453
	return value - floor(value)
