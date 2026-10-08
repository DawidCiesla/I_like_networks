extends SceneTree

const TerrainRenderer = preload("res://scripts/world/terrain_renderer.gd")

var _failures := 0


func _init() -> void:
	_run_tests()
	if _failures == 0:
		print("TERRAIN RENDERER MATERIAL TEST: PASS")
		quit(0)
		return
	push_error("TERRAIN RENDERER MATERIAL TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _run_tests() -> void:
	var material := TerrainRenderer.create_premium_material()
	_expect(material is ShaderMaterial, "terrain uses the procedural shader material")
	if material.shader == null:
		_expect(false, "terrain shader resource loads")
		return

	_expect(
		material.shader.resource_path.ends_with("terrain_surface.gdshader"),
		"terrain material references the dedicated terrain surface shader"
	)
	_expect(
		is_equal_approx(float(material.get_shader_parameter("grain_strength")), TerrainRenderer.DEFAULT_GRAIN_STRENGTH),
		"world grain uses its restrained default strength"
	)
	_expect(
		is_equal_approx(float(material.get_shader_parameter("height_tint_strength")), TerrainRenderer.DEFAULT_HEIGHT_TINT_STRENGTH),
		"elevation tint uses its restrained default strength"
	)
	_expect(
		is_equal_approx(float(material.get_shader_parameter("slope_tint_strength")), TerrainRenderer.DEFAULT_SLOPE_TINT_STRENGTH),
		"slope tint uses its restrained default strength"
	)

	var uniform_names: Array[String] = []
	for uniform: Dictionary in material.shader.get_shader_uniform_list():
		uniform_names.append(str(uniform.get("name", "")))
	for uniform_name in ["grain_strength", "height_tint_strength", "slope_tint_strength"]:
		_expect(uniform_names.has(uniform_name), "shader exposes %s for tuning" % uniform_name)

	var renderer := TerrainRenderer.new()
	var terrain_mesh := renderer._build_mesh(
		Rect2(Vector2(10.0, 10.0), Vector2(100.0, 100.0)),
		41731
	)
	_expect(terrain_mesh.get_surface_count() == 1, "terrain mesh has one opaque surface")
	if terrain_mesh.get_surface_count() > 0:
		var surface_material := terrain_mesh.surface_get_material(0) as ShaderMaterial
		_expect(surface_material != null, "built terrain surface uses the shader material")
		if surface_material != null:
			_expect(
				surface_material.shader == material.shader,
				"built terrain surface preserves the premium shader"
			)
	renderer.free()


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("TerrainRenderer: %s" % message)
