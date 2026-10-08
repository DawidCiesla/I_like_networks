extends RefCounted

const BuildingStyleApplier = preload("res://scripts/render/building_style_applier.gd")

const MODEL_SCENES := {
	"suburban_a": preload("res://assets/kenney/suburban/models/building-type-a.glb"),
	"suburban_b": preload("res://assets/kenney/suburban/models/building-type-b.glb"),
	"suburban_f": preload("res://assets/kenney/suburban/models/building-type-f.glb"),
	"suburban_u": preload("res://assets/kenney/suburban/models/building-type-u.glb"),
	"commercial_shop_a": preload("res://assets/kenney/commercial/models/building-e.glb"),
	"commercial_shop_b": preload("res://assets/kenney/commercial/models/building-j.glb"),
	"commercial_shop_c": preload("res://assets/kenney/commercial/models/building-k.glb"),
	"commercial_midrise": preload("res://assets/kenney/commercial/models/building-m.glb"),
	"commercial_wide": preload("res://assets/kenney/commercial/models/building-n.glb"),
	"commercial_tower_a": preload("res://assets/kenney/commercial/models/building-skyscraper-a.glb"),
	"commercial_tower_e": preload("res://assets/kenney/commercial/models/building-skyscraper-e.glb"),
	"industrial_a": preload("res://assets/kenney/industrial/models/building-a.glb"),
	"industrial_c": preload("res://assets/kenney/industrial/models/building-c.glb"),
	"industrial_e": preload("res://assets/kenney/industrial/models/building-e.glb"),
	"industrial_j": preload("res://assets/kenney/industrial/models/building-j.glb"),
	"industrial_t": preload("res://assets/kenney/industrial/models/building-t.glb"),
	"industrial_q": preload("res://assets/kenney/industrial/models/building-q.glb"),
	"industrial_r": preload("res://assets/kenney/industrial/models/building-r.glb"),
	"industrial_s": preload("res://assets/kenney/industrial/models/building-s.glb"),
}

const MODELS_BY_KIND := {
	"house": ["suburban_a", "suburban_f", "suburban_u"],
	"townhouse": ["suburban_b", "suburban_u"],
	"shop": ["commercial_shop_a", "commercial_shop_b", "commercial_shop_c"],
	"apartment": ["commercial_shop_b", "commercial_wide"],
	"midrise": ["commercial_midrise", "commercial_wide", "commercial_shop_b"],
	"tower": ["commercial_tower_a", "commercial_tower_e"],
	"workshop": ["industrial_c", "industrial_e", "industrial_j"],
	"warehouse": ["industrial_a", "industrial_t", "industrial_q", "industrial_r", "industrial_s"],
	"civic": ["commercial_wide", "commercial_shop_b"],
	"campus": ["commercial_wide", "commercial_shop_b"],
}

# GLBs do not encode semantic frontage metadata. Keep the authored front side
# explicit per model so verified asset orientations can be corrected without
# changing parcel or simulation orientation.
const FRONT_SIDE_BY_MODEL := {
	"suburban_a": 1.0,
	"suburban_b": 1.0,
	"suburban_f": 1.0,
	"suburban_u": 1.0,
	"commercial_shop_a": 1.0,
	"commercial_shop_b": 1.0,
	"commercial_shop_c": 1.0,
	"commercial_midrise": 1.0,
	"commercial_wide": 1.0,
	"commercial_tower_a": 1.0,
	"commercial_tower_e": 1.0,
	"industrial_a": 1.0,
	"industrial_c": 1.0,
	"industrial_e": 1.0,
	"industrial_j": 1.0,
	"industrial_t": 1.0,
	"industrial_q": 1.0,
	"industrial_r": 1.0,
	"industrial_s": 1.0,
}

# Kenney's buildings use shared imported StandardMaterial3D resources. Keep the
# source materials and their texture/roughness values intact, then apply a
# restrained per-building modulation to a local material copy. The palettes
# are deliberately close in value so the original authored PBR look remains
# visible instead of turning each building into a flat color block.
const STYLE_PALETTES := {
	"residential": [
		Color(1.00, 0.96, 0.92),
		Color(0.91, 0.97, 1.00),
		Color(0.93, 1.00, 0.93),
		Color(1.00, 0.98, 0.93),
	],
	"commercial": [
		Color(0.91, 0.97, 1.00),
		Color(1.00, 0.95, 0.90),
		Color(0.93, 1.00, 0.97),
		Color(0.96, 0.93, 1.00),
	],
	"industrial": [
		Color(1.00, 0.95, 0.90),
		Color(0.91, 0.96, 0.93),
		Color(0.91, 0.95, 1.00),
		Color(0.98, 0.98, 0.92),
	],
	"civic": [
		Color(0.91, 0.97, 0.98),
		Color(1.00, 0.97, 0.90),
		Color(0.95, 0.94, 1.00),
	],
}

static func create_visual(
	building: Dictionary,
	width: float,
	height: float,
	depth: float,
	ground: float
) -> Dictionary:
	var profile: Dictionary = building.get("profile", {})
	var kind := str(profile.get("kind", ""))
	var floors := maxi(1, int(profile.get("floors", 1)))
	var density := maxi(1, int(profile.get("density", 1)))
	var choices: Array = _variant_choices(kind, floors, density)
	if choices.is_empty():
		return {}

	var building_id := str(building.get("id", ""))
	var choice_index := posmod(hash("%s:%d:%d" % [building_id, floors, density]), choices.size())
	var model_key := str(choices[choice_index])
	var packed_scene: PackedScene = MODEL_SCENES.get(model_key)
	if packed_scene == null:
		return {}

	var imported_root := packed_scene.instantiate() as Node3D
	if imported_root == null:
		return {}
	var tint := style_tint(str(building.get("zone", "")), kind, building_id)
	# The renderer adds this root after it positions the asset; apply its local
	# materials on tree entry so the authored scene stays reusable and tests do
	# not allocate transient render materials for discarded off-tree instances.
	imported_root.set_script(BuildingStyleApplier)
	imported_root.set("tint", tint)

	var bounds := _scene_bounds(imported_root)
	if bounds.size.x <= 0.0001 or bounds.size.y <= 0.0001 or bounds.size.z <= 0.0001:
		imported_root.free()
		return {}

	var target_size := Vector3(width * 0.78, height, depth * 0.78)
	var scale_x := target_size.x / bounds.size.x
	var scale_y := target_size.y / bounds.size.y
	var scale_z := target_size.z / bounds.size.z
	var uniform_scale := minf(scale_x, minf(scale_y, scale_z))
	if uniform_scale <= 0.0:
		imported_root.free()
		return {}

	imported_root.name = "KenneyBuilding"
	imported_root.scale = Vector3.ONE * uniform_scale
	imported_root.position = Vector3(
		-(bounds.position.x + bounds.size.x * 0.5) * uniform_scale,
		ground + 0.7 - bounds.position.y * uniform_scale,
		-(bounds.position.z + bounds.size.z * 0.5) * uniform_scale
	)

	return {
		"visual": imported_root,
		"scale": uniform_scale,
		"bottom": bounds.position.y,
		"footprint_width": bounds.size.x * uniform_scale,
		"footprint_depth": bounds.size.z * uniform_scale,
		"model_key": model_key,
		"front_side": front_side_sign(model_key),
		"style_tint": tint,
	}

static func style_tint(zone: String, kind: String, building_id: String) -> Color:
	var family := _style_family(zone, kind)
	var palette: Array = STYLE_PALETTES[family]
	var style_hash := hash("%s|%s|%s" % [zone, kind, building_id])
	var palette_index := posmod(style_hash, palette.size())
	var tone_index := posmod(style_hash >> 5, 5)
	var tone_scale := 0.975 + float(tone_index) * 0.012
	var palette_color: Color = palette[palette_index]
	return Color(
		clampf(palette_color.r * tone_scale, 0.88, 1.08),
		clampf(palette_color.g * tone_scale, 0.88, 1.08),
		clampf(palette_color.b * tone_scale, 0.88, 1.08),
		1.0
	)

static func _style_family(zone: String, kind: String) -> String:
	match zone:
		"residential":
			return "residential"
		"commercial":
			return "commercial"
		"industrial":
			return "industrial"
		"civic":
			return "civic"
		"mixed":
			if kind in ["house", "townhouse", "apartment"]:
				return "residential"
			if kind in ["workshop", "warehouse"]:
				return "industrial"
			return "commercial"
	match kind:
		"house", "townhouse", "apartment":
			return "residential"
		"workshop", "warehouse":
			return "industrial"
		"civic", "campus":
			return "civic"
		_:
			return "commercial"

static func front_side_sign(model_key: String) -> float:
	return float(FRONT_SIDE_BY_MODEL.get(model_key, 1.0))

static func _variant_choices(kind: String, floors: int, density: int) -> Array:
	var defaults: Array = MODELS_BY_KIND.get(kind, [])
	if defaults.is_empty():
		return []

	match kind:
		"apartment":
			if floors >= 6 or density >= 4:
				return ["commercial_wide", "commercial_midrise"]
			return ["commercial_midrise", "commercial_shop_b", "commercial_wide"]
		"midrise":
			if floors >= 7:
				return ["commercial_wide", "commercial_midrise"]
			return ["commercial_midrise", "commercial_shop_b", "commercial_wide"]
		"tower":
			return ["commercial_tower_a", "commercial_tower_e"]
		"civic", "campus":
			if floors >= 4 or density >= 3:
				return ["commercial_wide", "commercial_midrise", "commercial_shop_b"]
			return ["commercial_shop_b", "commercial_wide"]
		"warehouse":
			if floors >= 2 and density >= 4:
				return ["industrial_a", "industrial_t", "industrial_q"]
			return ["industrial_s", "industrial_r", "industrial_a", "industrial_t", "industrial_q"]
		"workshop":
			if floors >= 2 or density >= 3:
				return ["industrial_e", "industrial_c", "industrial_j"]
		"shop":
			if floors >= 2:
				return ["commercial_shop_b", "commercial_shop_c", "commercial_shop_a"]
	return defaults

static func _scene_bounds(root: Node3D) -> AABB:
	var state := {
		"has_bounds": false,
		"bounds": AABB(),
	}
	_accumulate_bounds(root, Transform3D.IDENTITY, state)
	var bounds: AABB = state["bounds"]
	return bounds

static func _accumulate_bounds(node: Node, parent_transform: Transform3D, state: Dictionary) -> void:
	var transform := parent_transform
	if node is Node3D:
		transform = parent_transform * (node as Node3D).transform

	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			var mesh_bounds := _transform_bounds(mesh_instance.mesh.get_aabb(), transform)
			if state["has_bounds"]:
				var existing_bounds: AABB = state["bounds"]
				state["bounds"] = existing_bounds.merge(mesh_bounds)
			else:
				state["bounds"] = mesh_bounds
				state["has_bounds"] = true

	for child in node.get_children():
		_accumulate_bounds(child, transform, state)

static func _transform_bounds(bounds: AABB, transform: Transform3D) -> AABB:
	var first_corner := transform * bounds.position
	var result := AABB(first_corner, Vector3.ZERO)
	for x in [0.0, 1.0]:
		for y in [0.0, 1.0]:
			for z in [0.0, 1.0]:
				var corner := bounds.position + Vector3(
					bounds.size.x * x,
					bounds.size.y * y,
					bounds.size.z * z
				)
				result = result.expand(transform * corner)
	return result
