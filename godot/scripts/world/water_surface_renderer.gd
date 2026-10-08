extends MeshInstance3D
class_name WaterSurfaceRenderer

const WorldLayers = preload("res://scripts/world/world_layers.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const GameData = preload("res://scripts/core/game_data.gd")

const DEFAULT_RESOLUTION := Vector2i(28, 28)
const MAX_GRID_STEPS := 128
const WATER_SURFACE_OFFSET := 0.22
const RIVER_SHALLOWS_COLOR := Color(0.20, 0.62, 0.65, 1.0)
const RIVER_DEEP_COLOR := Color(0.045, 0.20, 0.31, 1.0)
const LAKE_SHALLOWS_COLOR := Color(0.26, 0.66, 0.71, 1.0)
const LAKE_DEEP_COLOR := Color(0.035, 0.16, 0.32, 1.0)
const RIVER_MAX_DEPTH := 4.2
const LAKE_MAX_DEPTH := 9.0


func _ready() -> void:
	# Keep the water extent tied to the active map definition and use the same
	# world seed as the terrain, so legacy saves and new regions stay aligned.
	var active_map := MapDefinition.active_definition()
	var seed := int(active_map.get("seed", GameData.DEFAULT_CITY_SEED))
	var store := get_node_or_null("/root/GameStore")
	if store != null and store.has_signal("terrain_changed"):
		store.terrain_changed.connect(_on_terrain_changed)
	rebuild(seed, TerrainSurface.world_bounds(), Vector2i(64, 64))


func _on_terrain_changed() -> void:
	var active_map := MapDefinition.active_definition()
	rebuild(
		int(active_map.get("seed", GameData.DEFAULT_CITY_SEED)),
		TerrainSurface.world_bounds(),
		Vector2i(64, 64)
	)


## Rebuilds a world-space water mesh for the supplied rectangle and terrain seed.
## The rectangle uses x/z in its x/y components; keep this node at world origin.
func rebuild(
	seed: int,
	bounds: Rect2,
	resolution: Vector2i = DEFAULT_RESOLUTION
) -> void:
	mesh = build_mesh(seed, bounds, resolution)
	material_override = create_water_material()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Creates a bounded low-resolution transparent surface from point samples.
static func build_mesh(
	seed: int,
	bounds: Rect2,
	resolution: Vector2i = DEFAULT_RESOLUTION
) -> ArrayMesh:
	var empty_mesh := ArrayMesh.new()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return empty_mesh
	var steps := Vector2i(
	clampi(resolution.x, 1, MAX_GRID_STEPS),
	clampi(resolution.y, 1, MAX_GRID_STEPS)
	)
	var point_count := (steps.x + 1) * (steps.y + 1)
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(point_count)
	colors.resize(point_count)
	var stride := steps.x + 1

	for grid_z in range(steps.y + 1):
		var tz := float(grid_z) / float(steps.y)
		var world_z := bounds.position.y + bounds.size.y * tz
		for grid_x in range(steps.x + 1):
			var tx := float(grid_x) / float(steps.x)
			var world_x := bounds.position.x + bounds.size.x * tx
			var world_point := Vector2(world_x, world_z)
			var layer_sample: Dictionary = WorldLayers.sample_water(seed, world_point)
			var water_depth := float(layer_sample["water_depth"])
			var water_kind := str(layer_sample["water_kind"])
			var vertex_index := grid_z * stride + grid_x
			vertices[vertex_index] = Vector3(
				world_x,
				TerrainSurface.height(seed, world_x, world_z) + WATER_SURFACE_OFFSET,
				world_z
			)
			colors[vertex_index] = water_color_for_depth(water_kind, water_depth)

	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var has_geometry := false
	for grid_z in range(steps.y):
		for grid_x in range(steps.x):
			var top_left := grid_z * stride + grid_x
			var top_right := top_left + 1
			var bottom_left := top_left + stride
			var bottom_right := bottom_left + 1
			# Winding faces upward in Godot's y-up world.
			has_geometry = _append_triangle(tool, vertices, colors, top_left, bottom_left, top_right) or has_geometry
			has_geometry = _append_triangle(tool, vertices, colors, top_right, bottom_left, bottom_right) or has_geometry

	if not has_geometry:
		return empty_mesh
	tool.generate_normals()
	var generated := tool.commit()
	return generated if generated != null else empty_mesh


static func create_water_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color.WHITE
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 0.22
	material.metallic = 0.0
	return material


static func _append_triangle(
	tool: SurfaceTool,
	vertices: PackedVector3Array,
	colors: PackedColorArray,
	first: int,
	second: int,
	third: int
) -> bool:
	if maxf(colors[first].a, maxf(colors[second].a, colors[third].a)) <= 0.0:
		return false
	tool.set_color(colors[first])
	tool.add_vertex(vertices[first])
	tool.set_color(colors[second])
	tool.add_vertex(vertices[second])
	tool.set_color(colors[third])
	tool.add_vertex(vertices[third])
	return true


static func water_color_for_depth(kind: String, depth: float) -> Color:
	if not is_finite(depth) or depth <= 0.0 or kind == "none":
		return Color(1.0, 1.0, 1.0, 0.0)
	var is_lake := kind == "lake"
	var max_depth := LAKE_MAX_DEPTH if is_lake else RIVER_MAX_DEPTH
	var depth_ratio := clampf(depth / max_depth, 0.0, 1.0)
	var shade := _smoothstep(0.08, 0.78, depth_ratio)
	var shallows := LAKE_SHALLOWS_COLOR if is_lake else RIVER_SHALLOWS_COLOR
	var deep_water := LAKE_DEEP_COLOR if is_lake else RIVER_DEEP_COLOR
	var water_color := shallows.lerp(deep_water, shade)
	water_color.a = lerpf(0.32, 0.68, _smoothstep(0.04, 0.70, depth_ratio))
	return water_color


static func _smoothstep(edge_low: float, edge_high: float, value: float) -> float:
	var weight := clampf((value - edge_low) / (edge_high - edge_low), 0.0, 1.0)
	return weight * weight * (3.0 - 2.0 * weight)
