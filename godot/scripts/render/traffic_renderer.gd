extends Node3D

const Terrain = preload("res://scripts/world/terrain_model.gd")

const MAX_CARS := 24
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

func _ready() -> void:
	GameStore.city_changed.connect(_sync_traffic)
	GameStore.state_changed.connect(_sync_traffic)
	_sync_traffic()

func _process(delta: float) -> void:
	if GameStore.simulation_speed <= 0:
		return

	var scaled := delta * float(GameStore.simulation_speed)
	for index in range(_cars.size()):
		var car: Dictionary = _cars[index]
		var node: MeshInstance3D = car["node"]
		if not is_instance_valid(node):
			continue

		var length := float(car["length"])
		if length <= 0.0:
			continue

		car["distance"] = fposmod(
			float(car["distance"])
			+ float(car["speed"]) * scaled * float(car["direction"]),
			length
		)

		var point := _point_on_polyline(car["points"], float(car["distance"]))
		var position_2d: Vector2 = point["position"]
		var tangent: Vector2 = point["tangent"]
		var normal := Vector2(-tangent.y, tangent.x) * float(car["lane_offset"])
		position_2d += normal

		node.position = Vector3(
			position_2d.x,
			Terrain.height(GameStore.city_seed, position_2d.x, position_2d.y) + 2.1,
			position_2d.y
		)
		node.rotation.y = -atan2(tangent.y, tangent.x)
		_cars[index] = car

func _sync_traffic() -> void:
	if GameStore.city.is_empty():
		return

	var roads := _eligible_roads()
	var target := mini(
		MAX_CARS,
		maxi(0, int(GameStore.city.get("buildings", []).size() / 2))
	)
	if not roads.is_empty() and target == 0:
		target = 1

	var ids: Array[String] = []
	for road in roads:
		ids.append(str(road["id"]))
	ids.sort()
	var signature := "%s::%d" % ["|".join(ids), target]
	if signature == _road_signature:
		return
	_road_signature = signature

	for car in _cars:
		var node: Node = car["node"]
		if is_instance_valid(node):
			node.queue_free()
	_cars.clear()

	if roads.is_empty():
		return

	for index in range(target):
		var road_index := int(_hash32("%d:road:%d" % [GameStore.city_seed, index]) % roads.size())
		var road: Dictionary = roads[road_index]
		var points := _road_points(road)
		var length := _polyline_length(points)
		if length < 60.0:
			continue

		var node := _create_car(index)
		add_child(node)
		var lane_side := -1.0 if index % 2 == 0 else 1.0
		_cars.append({
			"node": node,
			"points": points,
			"length": length,
			"distance": fposmod(float(_hash32("%d:phase:%d" % [GameStore.city_seed, index]) % 10000) / 10000.0 * length, length),
			"speed": 8.0 + float(_hash32("%d:speed:%d" % [GameStore.city_seed, index]) % 600) / 100.0,
			"direction": -1.0 if index % 3 == 0 else 1.0,
			"lane_offset": lane_side * (4.5 if str(road.get("class", "")) == "arterial" else 3.2),
		})

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

func _polyline_length(points: Array[Vector2]) -> float:
	var total := 0.0
	for index in range(points.size() - 1):
		total += points[index].distance_to(points[index + 1])
	return total

func _point_on_polyline(points: Array[Vector2], distance_along: float) -> Dictionary:
	if points.is_empty():
		return {"position": Vector2.ZERO, "tangent": Vector2.RIGHT}
	if points.size() == 1:
		return {"position": points[0], "tangent": Vector2.RIGHT}

	var remaining: float = maxf(0.0, distance_along)
	for index in range(points.size() - 1):
		var a := points[index]
		var b := points[index + 1]
		var length := a.distance_to(b)
		if remaining <= length or index == points.size() - 2:
			var t: float = 0.0 if length <= 0.000001 else remaining / length
			return {
				"position": a.lerp(b, t),
				"tangent": (b - a).normalized(),
			}
		remaining -= length

	return {"position": points[points.size() - 1], "tangent": Vector2.RIGHT}

func _hash32(value: String) -> int:
	var hash_value: int = 2166136261
	for index in range(value.length()):
		hash_value = (hash_value ^ value.unicode_at(index)) & 0xffffffff
		hash_value = (hash_value * 16777619) & 0xffffffff
	return hash_value
