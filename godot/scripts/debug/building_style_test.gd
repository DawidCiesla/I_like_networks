extends SceneTree

const BuildingAssets = preload("res://scripts/render/building_asset_library.gd")

var _failed := false
var _pending_cleanup: Array[Node] = []

func _initialize() -> void:
	_test_stable_palette_variation()
	await _test_instance_material_isolation()
	_test_archetype_instantiation()
	for node in _pending_cleanup:
		node.queue_free()
	await process_frame
	if _failed:
		push_error("BUILDING STYLE TEST: FAIL")
		quit(1)
		return
	print("BUILDING STYLE TEST: PASS")
	quit(0)

func _test_stable_palette_variation() -> void:
	var themes := [
		{"zone": "residential", "kind": "house"},
		{"zone": "commercial", "kind": "shop"},
		{"zone": "industrial", "kind": "warehouse"},
		{"zone": "civic", "kind": "campus"},
		{"zone": "mixed", "kind": "apartment"},
	]
	var theme_tints: Array[Color] = []
	for theme in themes:
		var zone := str(theme["zone"])
		var kind := str(theme["kind"])
		var stable := BuildingAssets.style_tint(zone, kind, "stable-id")
		_expect(stable.is_equal_approx(BuildingAssets.style_tint(zone, kind, "stable-id")))
		_expect(_is_subtle_tint(stable))
		theme_tints.append(stable)
	_expect(not theme_tints[0].is_equal_approx(theme_tints[2]))
	_expect(not theme_tints[1].is_equal_approx(theme_tints[3]))
	var seen := {}
	for index in range(48):
		var tint := BuildingAssets.style_tint("residential", "house", "district-house-%d" % index)
		seen[tint.to_html(false)] = true
	_expect(seen.size() >= 4)

func _test_instance_material_isolation() -> void:
	var building := {
		"id": "style-instance-check",
		"zone": "residential",
		"profile": {"kind": "house", "floors": 1, "density": 1},
	}
	var choices := BuildingAssets._variant_choices("house", 1, 1)
	var model_index := posmod(hash("style-instance-check:1:1"), choices.size())
	var source_scene: PackedScene = BuildingAssets.MODEL_SCENES[str(choices[model_index])]
	var source_root := source_scene.instantiate()
	var source_material := _first_standard_material(source_root)
	_expect(source_material != null)
	if source_material == null:
		source_root.free()
		return
	var original_color := source_material.albedo_color
	var original_roughness := source_material.roughness
	var original_texture := source_material.albedo_texture
	var first: Dictionary = BuildingAssets.create_visual(building, 30.0, 24.0, 26.0, 0.0)
	var second: Dictionary = BuildingAssets.create_visual(building, 30.0, 24.0, 26.0, 0.0)
	_expect(not first.is_empty() and not second.is_empty())
	if first.is_empty() or second.is_empty():
		source_root.free()
		return
	get_root().add_child(first["visual"])
	get_root().add_child(second["visual"])
	await process_frame
	var first_material := _first_standard_material(first["visual"])
	var second_material := _first_standard_material(second["visual"])
	_expect(source_material != null and first_material != null and second_material != null)
	if source_material != null and first_material != null and second_material != null:
		_expect(source_material != first_material)
		_expect(first_material != second_material)
		_expect(first_material.albedo_color != source_material.albedo_color)
		_expect(is_equal_approx(first_material.roughness, original_roughness))
		_expect(first_material.albedo_texture == original_texture)
		_expect(source_material.albedo_color.is_equal_approx(original_color))
	_pending_cleanup.append(first["visual"])
	_pending_cleanup.append(second["visual"])
	source_root.free()

func _test_archetype_instantiation() -> void:
	var profiles := [
		{"id": "house", "zone": "residential", "kind": "house", "floors": 1, "density": 1},
		{"id": "townhouse", "zone": "residential", "kind": "townhouse", "floors": 2, "density": 2},
		{"id": "shop", "zone": "commercial", "kind": "shop", "floors": 1, "density": 2},
		{"id": "apartment", "zone": "residential", "kind": "apartment", "floors": 6, "density": 3},
		{"id": "midrise", "zone": "commercial", "kind": "midrise", "floors": 7, "density": 3},
		{"id": "tower", "zone": "commercial", "kind": "tower", "floors": 10, "density": 4},
		{"id": "workshop", "zone": "industrial", "kind": "workshop", "floors": 1, "density": 2},
		{"id": "warehouse", "zone": "industrial", "kind": "warehouse", "floors": 2, "density": 4},
		{"id": "civic", "zone": "civic", "kind": "civic", "floors": 3, "density": 2},
		{"id": "campus", "zone": "civic", "kind": "campus", "floors": 4, "density": 3},
	]
	for profile in profiles:
		var visual_data: Dictionary = BuildingAssets.create_visual({
			"id": "style-%s" % profile["id"],
			"zone": profile["zone"],
			"profile": profile,
		}, 32.0, 28.0, 24.0, 0.0)
		_expect(not visual_data.is_empty())
		if not visual_data.is_empty():
			_expect(float(visual_data["footprint_width"]) > 0.0)
			_expect(float(visual_data["footprint_depth"]) > 0.0)
			_expect(_is_subtle_tint(visual_data["style_tint"]))
			get_root().add_child(visual_data["visual"])
			_pending_cleanup.append(visual_data["visual"])

func _first_standard_material(node: Node) -> StandardMaterial3D:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			for surface_index in range(mesh_instance.mesh.get_surface_count()):
				var material := mesh_instance.get_active_material(surface_index)
				if material is StandardMaterial3D:
					return material as StandardMaterial3D
	for child in node.get_children():
		var material := _first_standard_material(child)
		if material != null:
			return material
	return null

func _is_subtle_tint(color: Color) -> bool:
	var minimum := minf(color.r, minf(color.g, color.b))
	var maximum := maxf(color.r, maxf(color.g, color.b))
	return minimum >= 0.85 and maximum <= 1.08 and maximum - minimum <= 0.15

func _expect(condition: bool) -> void:
	if not condition:
		_failed = true
		push_error("BUILDING STYLE CHECK FAILED")
