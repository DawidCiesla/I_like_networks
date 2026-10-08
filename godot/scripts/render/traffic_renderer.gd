extends Node3D

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const TrafficDemandModel = preload("res://scripts/render/traffic_demand.gd")

const MAX_CARS := 24
const TRAFFIC_SYNC_INTERVAL_SECONDS := 0.5
const CAR_COLORS := [
	Color("#d1d0c9"),
	Color("#8fa0a8"),
	Color("#9b6f62"),
	Color("#60786a"),
	Color("#c1a65a"),
	Color("#6b7284"),
]

var _cars: Array[Dictionary] = []
var _road_signature := ""
var _traffic_sync_requested := true
var _traffic_sync_elapsed := TRAFFIC_SYNC_INTERVAL_SECONDS

func _ready() -> void:
	GameStore.city_changed.connect(_request_traffic_sync)
	GameStore.state_changed.connect(_request_traffic_sync)
	GameStore.terrain_changed.connect(_on_terrain_changed)
	_sync_traffic()
	_traffic_sync_requested = false
	_traffic_sync_elapsed = 0.0

func _request_traffic_sync() -> void:
	_traffic_sync_requested = true

func _on_terrain_changed() -> void:
	_road_signature = ""
	_request_traffic_sync()

func _process(delta: float) -> void:
	_traffic_sync_elapsed += delta
	if _traffic_sync_requested and _traffic_sync_elapsed >= TRAFFIC_SYNC_INTERVAL_SECONDS:
		_traffic_sync_requested = false
		_traffic_sync_elapsed = 0.0
		_sync_traffic()

	var scaled := delta * float(GameStore.simulation_speed)
	for index in range(_cars.size()):
		var car: Dictionary = _cars[index]
		var node: MeshInstance3D = car["node"]
		if not is_instance_valid(node):
			continue
		node.transparency = move_toward(
			node.transparency,
			float(car.get("target_transparency", 0.0)),
			delta * 1.6
		)
		node.visible = node.transparency < 0.999
		if not node.visible:
			_cars[index] = car
			continue
		if GameStore.simulation_speed <= 0:
			_cars[index] = car
			continue

		var length := float(car["length"])
		if length <= 0.0:
			continue

		car["distance"] = fposmod(
			float(car["distance"])
			+ float(car["speed"]) * scaled * float(car["direction"]),
			length
		)

		var point := _point_on_polyline(
			car["points"],
			car["cumulative_lengths"],
			float(car["distance"])
		)
		var position_2d := Vector2(point.x, point.y)
		var tangent := Vector2(point.z, point.w)
		var normal := Vector2(-tangent.y, tangent.x) * float(car["lane_offset"])
		position_2d += normal

		node.position = Vector3(
			position_2d.x,
			TerrainSurface.height(GameStore.city_seed, position_2d.x, position_2d.y) + 2.1,
			position_2d.y
		)
		node.rotation.y = -atan2(tangent.y, tangent.x)
		_cars[index] = car

func _sync_traffic() -> void:
	if GameStore.city.is_empty():
		return

	var roads := _eligible_roads()
	var target := _target_car_count()
	if roads.is_empty():
		target = 0

	var ids: Array[String] = []
	for road in roads:
		ids.append(str(road["id"]))
	ids.sort()
	var signature := "|".join(ids)
	if signature != _road_signature:
		_road_signature = signature
		for car in _cars:
			var node: Node = car["node"]
			if is_instance_valid(node):
				node.queue_free()
		_cars.clear()

	if roads.is_empty():
		return

	for index in range(_cars.size(), target):
		var road_index := int(_hash32("%d:road:%d" % [GameStore.city_seed, index]) % roads.size())
		var road: Dictionary = roads[road_index]
		var points := _road_points(road)
		var cumulative_lengths := _cumulative_lengths(points)
		var length := float(cumulative_lengths.back()) if not cumulative_lengths.is_empty() else 0.0
		if length < 60.0:
			continue

		var node := _create_car(index)
		node.transparency = 1.0
		add_child(node)
		var lane_side := -1.0 if index % 2 == 0 else 1.0
		_cars.append({
			"node": node,
			"points": points,
			"cumulative_lengths": cumulative_lengths,
			"length": length,
			"distance": fposmod(float(_hash32("%d:phase:%d" % [GameStore.city_seed, index]) % 10000) / 10000.0 * length, length),
			"speed": 8.0 + float(_hash32("%d:speed:%d" % [GameStore.city_seed, index]) % 600) / 100.0,
			"direction": -1.0 if index % 3 == 0 else 1.0,
			"lane_offset": lane_side * (4.5 if str(road.get("class", "")) == "arterial" else 3.2),
			"target_transparency": 0.0,
		})

	for index in range(_cars.size()):
		var car: Dictionary = _cars[index]
		car["target_transparency"] = 0.0 if index < target else 1.0
		_cars[index] = car


func _target_car_count() -> int:
	if GameStore.is_sandbox():
		return TrafficDemandModel.visible_vehicle_target(
			GameStore.resident_transport_metrics(),
			MAX_CARS
		)
	var legacy_target := maxi(0, int(GameStore.city.get("buildings", []).size() / 2))
	if not _eligible_roads().is_empty() and legacy_target == 0:
		legacy_target = 1
	return mini(MAX_CARS, legacy_target)

func _eligible_roads() -> Array:
	var result: Array = []
	for road in GameStore.city.get("roads", []):
		if str(road.get("status", "")) != "built":
			continue
		if str(road.get("class", "")) not in ["arterial", "collector"]:
			continue
		if road.get("points", []).size() < 2:
			continue
		result.append(road)
	return result

func _create_car(index: int) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = "AmbientCar_%d" % index

	var box := BoxMesh.new()
	box.size = Vector3(7.4, 3.0, 4.2)
	var material := StandardMaterial3D.new()
	material.albedo_color = CAR_COLORS[index % CAR_COLORS.size()]
	material.roughness = 0.72
	box.material = material
	node.mesh = box
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _road_points(road: Dictionary) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for raw in road.get("points", []):
		result.append(Vector2(float(raw["x"]), float(raw["y"])))
	return result

func _cumulative_lengths(points: Array[Vector2]) -> Array[float]:
	var result: Array[float] = []
	result.append(0.0)
	for index in range(points.size() - 1):
		result.append(result.back() + points[index].distance_to(points[index + 1]))
	return result

func _point_on_polyline(
	points: Array[Vector2],
	cumulative_lengths: Array[float],
	distance_along: float
) -> Vector4:
	if points.is_empty():
		return Vector4(0.0, 0.0, 1.0, 0.0)
	if points.size() == 1:
		return Vector4(points[0].x, points[0].y, 1.0, 0.0)

	var target_distance := maxf(0.0, distance_along)
	var low := 0
	var high := points.size() - 2
	while low < high:
		var middle := (low + high) >> 1
		if cumulative_lengths[middle + 1] < target_distance:
			low = middle + 1
		else:
			high = middle

	var a := points[low]
	var b := points[low + 1]
	var segment_length := cumulative_lengths[low + 1] - cumulative_lengths[low]
	var t := (
		0.0
		if segment_length <= 0.000001
		else (target_distance - cumulative_lengths[low]) / segment_length
	)
	var position := a.lerp(b, t)
	var tangent := (b - a).normalized()
	return Vector4(position.x, position.y, tangent.x, tangent.y)

func _hash32(value: String) -> int:
	var hash_value: int = 2166136261
	for index in range(value.length()):
		hash_value = (hash_value ^ value.unicode_at(index)) & 0xffffffff
		hash_value = (hash_value * 16777619) & 0xffffffff
	return hash_value
