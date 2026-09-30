extends Node3D

const Terrain = preload("res://scripts/world/terrain_model.gd")

const ROAD_WIDTH := {
	"arterial": 31.0,
	"collector": 21.0,
	"local": 15.0,
	"service": 12.0,
}

const SIDEWALK_WIDTH := {
	"arterial": 42.0,
	"collector": 31.0,
	"local": 23.0,
	"service": 19.0,
}

const BUILDING_COLORS := {
	"residential": Color("#b5a98e"),
	"mixed": Color("#9f9a88"),
	"commercial": Color("#b8aa7c"),
	"civic": Color("#a4aaa9"),
	"industrial": Color("#8d8d82"),
}

var _roads_root: Node3D
var _junction_root: Node3D
var _buildings_root: Node3D

var _road_cache: Dictionary = {}
var _building_cache: Dictionary = {}
var _junction_signature := ""

func _ready() -> void:
	_roads_root = Node3D.new()
	_roads_root.name = "Roads"
	add_child(_roads_root)

	_junction_root = Node3D.new()
	_junction_root.name = "Junctions"
	add_child(_junction_root)

	_buildings_root = Node3D.new()
	_buildings_root.name = "Buildings"
	add_child(_buildings_root)

	GameStore.city_changed.connect(sync_city)
	GameStore.state_changed.connect(_on_state_changed)
	sync_city()

func _on_state_changed() -> void:
	sync_city()

func sync_city() -> void:
	if GameStore.city.is_empty():
		return
	_sync_roads()
	_sync_junctions()
	_sync_buildings()

func _road_signature(road: Dictionary) -> String:
	var status := str(road.get("status", "planned"))
	if status == "constructing":
		var bucket := clampi(floori(float(road.get("constructionProgress", 0.0)) * 20.0), 1, 20)
		return "constructing:%d" % bucket
	if status == "planned":
		return "planned:%s" % _road_planned_visible(road)
	return status

func _road_planned_visible(road: Dictionary) -> bool:
	var district_id := str(road.get("districtId", ""))
	for district in GameStore.city["districts"]:
		if str(district.get("id", "")) == district_id:
			return str(district.get("status", "")) == "active"
	return false

func _sync_roads() -> void:
	var live: Dictionary = {}

	for road in GameStore.city["roads"]:
		var road_id := str(road["id"])
		live[road_id] = true
		var signature := _road_signature(road)
		var previous: Dictionary = _road_cache.get(road_id, {})

		if not previous.is_empty() and str(previous.get("signature", "")) == signature:
			continue

		if not previous.is_empty():
			var old_node: Node = previous.get("node")
			if old_node:
				old_node.queue_free()
			_road_cache.erase(road_id)

		var node := _create_road_node(road, signature)
		if node != null:
			_roads_root.add_child(node)
			_road_cache[road_id] = {
				"signature": signature,
				"node": node,
			}

	for road_id in _road_cache.keys():
		if not live.has(road_id):
			var entry: Dictionary = _road_cache[road_id]
			var node: Node = entry.get("node")
			if node:
				node.queue_free()
			_road_cache.erase(road_id)

func _create_road_node(road: Dictionary, signature: String) -> Node3D:
	if signature == "planned:false":
		return null

	var points := _road_points(road)
	if points.size() < 2:
		return null

	var root := Node3D.new()
	root.name = str(road["id"])

	if signature.begins_with("constructing:"):
		var bucket := int(signature.get_slice(":", 1))
		points = _polyline_prefix(points, float(bucket) / 20.0)

	if signature == "planned:true":
		_add_ribbon(root, points, 3.0, Color(0.55, 0.57, 0.54, 0.30), 0.50)
		return root

	var road_class := str(road.get("class", "local"))
	_add_ribbon(
		root,
		points,
		float(SIDEWALK_WIDTH.get(road_class, 23.0)),
		Color("#777a74"),
		0.34
	)
	_add_ribbon(
		root,
		points,
		float(ROAD_WIDTH.get(road_class, 15.0)),
		Color("#3b3d3b"),
		0.58
	)
	return root

func _add_ribbon(
	parent: Node3D,
	points: Array[Vector2],
	width: float,
	color: Color,
	height_offset: float
) -> void:
	if points.size() < 2:
		return

	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.96
	if color.a < 0.99:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, material)
	for index in range(points.size()):
		var previous := points[maxi(0, index - 1)]
		var next := points[mini(points.size() - 1, index + 1)]
		var direction := (next - previous).normalized()
		var normal := Vector2(-direction.y, direction.x)

		for side in [-1.0, 1.0]:
			var point := points[index] + normal * width * 0.5 * side
			mesh.surface_add_vertex(Vector3(
				point.x,
				Terrain.height(GameStore.city_seed, point.x, point.y) + height_offset,
				point.y
			))
	mesh.surface_end()

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)

func _road_points(road: Dictionary) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for raw in road.get("points", []):
		result.append(Vector2(float(raw["x"]), float(raw["y"])))
	return result

func _polyline_prefix(points: Array[Vector2], progress: float) -> Array[Vector2]:
	var clamped := clamp(progress, 0.0, 1.0)
	if clamped >= 1.0:
		return points.duplicate()
	if clamped <= 0.0 or points.size() < 2:
		return []

	var lengths: Array[float] = []
	var total := 0.0
	for index in range(points.size() - 1):
		var length := points[index].distance_to(points[index + 1])
		lengths.append(length)
		total += length

	var target := total * clamped
	var travelled := 0.0
	var result: Array[Vector2] = [points[0]]

	for index in range(lengths.size()):
		var length := lengths[index]
		if travelled + length <= target:
			result.append(points[index + 1])
			travelled += length
			continue

		var local := 0.0 if length <= 0.000001 else (target - travelled) / length
		result.append(points[index].lerp(points[index + 1], local))
		break

	return result

func _sync_junctions() -> void:
	var built_ids: Array[String] = []
	var built_lookup: Dictionary = {}

	for road in GameStore.city["roads"]:
		if str(road.get("status", "")) == "built":
			var id := str(road["id"])
			built_ids.append(id)
			built_lookup[id] = road

	built_ids.sort()
	var signature := "|".join(built_ids)
	if signature == _junction_signature:
		return
	_junction_signature = signature

	for child in _junction_root.get_children():
		child.queue_free()

	for junction in GameStore.city.get("junctions", []):
		var built_roads: Array = []
		for road_id in junction.get("roadIds", []):
			if built_lookup.has(str(road_id)):
				built_roads.append(built_lookup[str(road_id)])

		if built_roads.size() < 2:
			continue

		var sidewalk_radius := 0.0
		var road_radius := 0.0
		for road in built_roads:
			var road_class := str(road.get("class", "local"))
			sidewalk_radius = max(sidewalk_radius, float(SIDEWALK_WIDTH.get(road_class, 23.0)) * 0.52)
			road_radius = max(road_radius, float(ROAD_WIDTH.get(road_class, 15.0)) * 0.52)

		var x := float(junction["x"])
		var z := float(junction["y"])
		var ground := Terrain.height(GameStore.city_seed, x, z)

		_add_junction_disc(Vector3(x, ground + 0.34, z), sidewalk_radius, 0.45, Color("#777a74"))
		_add_junction_disc(Vector3(x, ground + 0.60, z), road_radius, 0.48, Color("#3b3d3b"))

func _add_junction_disc(position_value: Vector3, radius: float, height: float, color: Color) -> void:
	var mesh_instance := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = height
	cylinder.radial_segments = 12
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.96
	cylinder.material = material
	mesh_instance.mesh = cylinder
	mesh_instance.position = position_value
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_junction_root.add_child(mesh_instance)

func _sync_buildings() -> void:
	var live: Dictionary = {}
	var parcel_lookup: Dictionary = {}
	for parcel in GameStore.city["parcels"]:
		parcel_lookup[str(parcel["id"])] = parcel

	for building in GameStore.city["buildings"]:
		var building_id := str(building["id"])
		live[building_id] = true
		var parcel: Dictionary = parcel_lookup.get(str(building["parcelId"]), {})
		if parcel.is_empty():
			continue

		var entry: Dictionary = _building_cache.get(building_id, {})
		if entry.is_empty():
			entry = _create_building(building, parcel)
			_building_cache[building_id] = entry

		_update_building(entry, building)

	for building_id in _building_cache.keys():
		if not live.has(building_id):
			var entry: Dictionary = _building_cache[building_id]
			var node: Node = entry.get("root")
			if node:
				node.queue_free()
			_building_cache.erase(building_id)

func _create_building(building: Dictionary, parcel: Dictionary) -> Dictionary:
	var root := Node3D.new()
	root.name = str(building["id"])
	_buildings_root.add_child(root)

	var inset := max(4.0, float(parcel.get("setback", 6.0)))
	var width := max(14.0, float(parcel.get("w", 38.0)) - inset * 1.4)
	var depth := max(12.0, float(parcel.get("h", 34.0)) - inset * 1.4)
	var height := float(building.get("profile", {}).get("heightMeters", 8.0))

	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, height, depth)
	var material := StandardMaterial3D.new()
	material.albedo_color = BUILDING_COLORS.get(str(building.get("zone", "")), Color("#a09b88"))
	material.roughness = 0.92
	box.material = material
	mesh_instance.mesh = box
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(mesh_instance)

	var x := float(building["x"])
	var z := float(building["y"])
	var ground := Terrain.height(GameStore.city_seed, x, z)
	root.position = Vector3(x, 0.0, z)
	root.rotation.y = -float(building.get("rotationRadians", 0.0))

	return {
		"root": root,
		"mesh": mesh_instance,
		"material": material,
		"height": height,
		"width": width,
		"depth": depth,
		"ground": ground,
		"roof": null,
	}

func _update_building(entry: Dictionary, building: Dictionary) -> void:
	var progress := 1.0 if str(building.get("status", "")) == "built" else clamp(float(building.get("constructionProgress", 0.0)), 0.04, 1.0)
	var mesh_instance: MeshInstance3D = entry["mesh"]
	var height := float(entry["height"])
	mesh_instance.scale.y = progress
	mesh_instance.position.y = float(entry["ground"]) + height * progress * 0.5 + 0.7

	if str(building.get("status", "")) != "built":
		var material: StandardMaterial3D = entry["material"]
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color.a = 0.78
		return

	var built_material: StandardMaterial3D = entry["material"]
	built_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	built_material.albedo_color.a = 1.0

	if entry["roof"] != null:
		return

	var kind := str(building.get("profile", {}).get("kind", ""))
	if kind not in ["house", "townhouse"]:
		return

	var roof := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(
		float(entry["width"]) * 1.05,
		5.5,
		float(entry["depth"]) * 1.05
	)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#654a3b")
	material.roughness = 1.0
	prism.material = material
	roof.mesh = prism
	roof.position.y = float(entry["ground"]) + height + 3.0
	entry["root"].add_child(roof)
	entry["roof"] = roof
