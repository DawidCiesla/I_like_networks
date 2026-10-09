extends SceneTree

const WaterSurfaceRenderer = preload("res://scripts/world/water_surface_renderer.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")

var _failures := 0


func _init() -> void:
	_run_tests()
	if _failures == 0:
		print("WATER SURFACE RENDERER TEST: PASS")
		quit(0)
		return
	push_error("WATER SURFACE RENDERER TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _run_tests() -> void:
	var seed := 41731
	var bounds := Rect2(Vector2(-2700.0, -2700.0), Vector2(5400.0, 5400.0))
	var river_shallows := WaterSurfaceRenderer.water_color_for_depth("river", 0.2)
	var river_deep := WaterSurfaceRenderer.water_color_for_depth("river", WaterSurfaceRenderer.RIVER_MAX_DEPTH)
	var lake_shallows := WaterSurfaceRenderer.water_color_for_depth("lake", 0.3)
	var lake_deep := WaterSurfaceRenderer.water_color_for_depth("lake", WaterSurfaceRenderer.LAKE_MAX_DEPTH)
	_expect(
		river_shallows.r > river_deep.r and river_shallows.g > river_deep.g,
		"river shallows keep a brighter teal tone than deep water"
	)
	_expect(
		lake_shallows.r > lake_deep.r and lake_shallows.g > lake_deep.g,
		"lake shallows keep a brighter turquoise tone than deep water"
	)
	_expect(river_deep.a > river_shallows.a, "water opacity increases gradually with depth")
	_expect(
		absf(river_shallows.b - lake_shallows.b) > 0.01,
		"rivers and lakes retain distinct shallow-water palettes"
	)
	_expect(
		WaterSurfaceRenderer.water_color_for_depth("none", 1.0).a == 0.0,
		"non-water samples stay transparent"
	)
	_expect(
		WaterSurfaceRenderer.water_color_for_depth("lake", NAN).a == 0.0,
		"non-finite depth samples stay transparent"
	)

	var generated := WaterSurfaceRenderer.build_mesh(seed, bounds, Vector2i(18, 18))
	_expect(generated.get_surface_count() == 1, "seeded water region produces one mesh surface")
	if generated.get_surface_count() == 0:
		return

	var arrays: Array = generated.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	_expect(vertices.size() >= 3, "water surface has triangle vertices")
	_expect(vertices.size() == colors.size(), "every vertex has water color and alpha")
	var visible_water_vertices := 0
	for index in range(vertices.size()):
		var vertex := vertices[index]
		_expect(vertex.x >= bounds.position.x - 0.001, "mesh remains inside the west bound")
		_expect(vertex.x <= bounds.end.x + 0.001, "mesh remains inside the east bound")
		_expect(vertex.z >= bounds.position.y - 0.001, "mesh remains inside the north bound")
		_expect(vertex.z <= bounds.end.y + 0.001, "mesh remains inside the south bound")
		_expect(
			is_equal_approx(
				vertex.y,
				TerrainSurface.height(seed, vertex.x, vertex.z) + WaterSurfaceRenderer.WATER_SURFACE_OFFSET
			),
			"water vertices follow TerrainSurface with a small surface offset"
		)
		if colors[index].a > 0.0:
			visible_water_vertices += 1
		_expect(colors[index].a >= 0.0 and colors[index].a <= 0.66, "water alpha remains transparent and bounded")
	_expect(visible_water_vertices > 0, "water samples receive visible transparent vertices")

	var renderer := WaterSurfaceRenderer.new()
	renderer.rebuild(seed, bounds, Vector2i(8, 8))
	_expect(renderer.mesh != null, "renderer can rebuild its mesh")
	var material := renderer.material_override as ShaderMaterial
	_expect(material != null, "renderer uses the animated procedural water material")
	if material != null:
		_expect(material.shader != null, "water shader resource loads")
		if material.shader != null:
			_expect(
				material.shader.resource_path.ends_with("water_surface.gdshader"),
				"renderer material references the dedicated water shader"
			)
		_expect(float(material.get_shader_parameter("wave_strength")) > 0.0, "water exposes animated wave strength")
	renderer.free()

	var invalid_mesh := WaterSurfaceRenderer.build_mesh(seed, Rect2(Vector2.ZERO, Vector2.ZERO))
	_expect(invalid_mesh.get_surface_count() == 0, "empty bounds produce an empty mesh")


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("WaterSurfaceRenderer: %s" % message)
