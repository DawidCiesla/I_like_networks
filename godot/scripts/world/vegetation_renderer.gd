extends Node3D

const Terrain = preload("res://scripts/world/terrain_model.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")

@export var spacing := 92.0
@export var margin := 560.0

var _trees: MultiMeshInstance3D

func _ready() -> void:
	rebuild()

func rebuild() -> void:
	for child in get_children():
		child.queue_free()

	var bounds := _world_bounds()
	var transforms: Array[Transform3D] = []

	var x := bounds.position.x
	while x <= bounds.end.x:
		var z := bounds.position.y
		while z <= bounds.end.y:
			var jitter_x := (_pseudo(x, z, 1) - 0.5) * spacing * 0.68
			var jitter_z := (_pseudo(x, z, 2) - 0.5) * spacing * 0.68
			var px := x + jitter_x
			var pz := z + jitter_z

			if _should_place_tree(px, pz):
				var scale := 0.75 + _pseudo(px, pz, 4) * 0.75
				var transform := Transform3D.IDENTITY
				transform = transform.rotated(Vector3.UP, _pseudo(px, pz, 5) * TAU)
				transform = transform.scaled(Vector3.ONE * scale)
				transform.origin = Vector3(
					px,
					Terrain.height(GameStore.city_seed, px, pz) + 8.5 * scale,
					pz
				)
				transforms.append(transform)
			z += spacing
		x += spacing

	var tree_mesh := CylinderMesh.new()
	tree_mesh.top_radius = 0.0
	tree_mesh.bottom_radius = 7.0
	tree_mesh.height = 17.0
	tree_mesh.radial_segments = 6
	tree_mesh.rings = 1

	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#315b31")
	material.roughness = 1.0
	tree_mesh.material = material

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.instance_count = transforms.size()
	multi.mesh = tree_mesh

	for index in range(transforms.size()):
		multi.set_instance_transform(index, transforms[index])

	_trees = MultiMeshInstance3D.new()
	_trees.multimesh = multi
	_trees.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_trees)

func _should_place_tree(x: float, z: float) -> bool:
	var forest := Terrain.forest_potential(GameStore.city_seed, x, z)
	if forest < 0.59:
		return false
	if _pseudo(x, z, 3) < 0.46:
		return false

	for line_key in ["line1", "line2", "line3", "line4"]:
		for segment_index in range(Layout.BASE_SEGMENTS[line_key].size()):
			var points := Layout.segment_points(line_key, segment_index)
			for index in range(points.size() - 1):
				if _distance_to_segment(Vector2(x, z), points[index], points[index + 1]) < 30.0:
					return false

	return true

func _distance_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq <= 0.000001:
		return point.distance_to(a)
	var t := clamp((point - a).dot(ab) / length_sq, 0.0, 1.0)
	return point.distance_to(a + ab * t)

func _pseudo(x: float, z: float, channel: int) -> float:
	var value := sin(
		x * 12.9898
		+ z * 78.233
		+ float(GameStore.city_seed) * 0.00317
		+ float(channel) * 19.19
	) * 43758.5453
	return value - floor(value)

func _world_bounds() -> Rect2:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for line_key in ["line1", "line2", "line3", "line4"]:
		for point in Layout.line_stops(line_key):
			min_x = min(min_x, point.x)
			max_x = max(max_x, point.x)
			min_z = min(min_z, point.y)
			max_z = max(max_z, point.y)
	return Rect2(
		Vector2(min_x - margin, min_z - margin),
		Vector2(max_x - min_x + margin * 2.0, max_z - min_z + margin * 2.0)
	)
