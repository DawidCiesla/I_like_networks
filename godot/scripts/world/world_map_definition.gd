extends RefCounted
class_name WorldMapDefinition

const Layout = preload("res://scripts/transport/transport_layout.gd")

const SCHEMA_VERSION := 1
const GENERATOR_VERSION := 2
const LEGACY_CITY_MAP_ID := "bus-era-city"
const DEFAULT_MAP_ID := "starter-region"
const LEGACY_MARGIN := 620.0
# Regional sandbox uses real-world metres. A 24 x 24 km region leaves enough
# space for several independent small towns, villages and rural corridors.
const REGION_HALF_EXTENT := 12000.0

static var _active_definition: Dictionary = {}
static var _active_revision := 0

static func set_active(map_definition: Dictionary) -> void:
	_active_definition = normalize(map_definition, int(map_definition.get("seed", 0)), true)
	_active_revision += 1


static func active_revision() -> int:
	return _active_revision


static func active_map_id() -> String:
	return str(_active_definition.get("id", LEGACY_CITY_MAP_ID))

static func active_definition() -> Dictionary:
	return _active_definition.duplicate(true)

static func create(map_id: String, seed: int) -> Dictionary:
	var normalized_id := map_id.strip_edges().to_lower()
	if normalized_id.is_empty():
		normalized_id = DEFAULT_MAP_ID
	var map_bounds := bounds_for(normalized_id)
	return {
		"schema_version": SCHEMA_VERSION,
		"id": normalized_id,
		"seed": seed,
		"generator_version": GENERATOR_VERSION,
		"bounds": _serialize_bounds(map_bounds),
		"outside_connections": _outside_connections(map_bounds),
		"hand_edits": [],
		"terrain_edits": {
			"version": 1,
			"seed": seed,
			"grid_step": 58.0,
			"source": "terrain_model",
			"edits": [],
		},
	}

static func normalize(raw: Variant, seed: int, legacy_fallback: bool = true) -> Dictionary:
	var source: Dictionary = raw if typeof(raw) == TYPE_DICTIONARY else {}
	if source.is_empty():
		return create(LEGACY_CITY_MAP_ID if legacy_fallback else DEFAULT_MAP_ID, seed)

	var result := create(str(source.get("id", DEFAULT_MAP_ID)), int(source.get("seed", seed)))
	result["generator_version"] = maxi(1, int(source.get("generator_version", GENERATOR_VERSION)))
	if typeof(source.get("bounds", null)) == TYPE_DICTIONARY:
		var raw_bounds: Dictionary = source["bounds"]
		var width := maxf(500.0, float(raw_bounds.get("width", 0.0)))
		var height := maxf(500.0, float(raw_bounds.get("height", 0.0)))
		result["bounds"] = {
			"x": float(raw_bounds.get("x", -width * 0.5)),
			"y": float(raw_bounds.get("y", -height * 0.5)),
			"width": width,
			"height": height,
		}
	if typeof(source.get("outside_connections", null)) == TYPE_ARRAY:
		result["outside_connections"] = source["outside_connections"].duplicate(true)
	if typeof(source.get("hand_edits", null)) == TYPE_ARRAY:
		result["hand_edits"] = source["hand_edits"].duplicate(true)
	if typeof(source.get("terrain_edits", null)) == TYPE_DICTIONARY:
		result["terrain_edits"] = source["terrain_edits"].duplicate(true)
	return result

static func bounds_for(map_id: String) -> Rect2:
	if map_id != LEGACY_CITY_MAP_ID:
		return Rect2(
			Vector2(-REGION_HALF_EXTENT, -REGION_HALF_EXTENT),
			Vector2(REGION_HALF_EXTENT * 2.0, REGION_HALF_EXTENT * 2.0)
		)

	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for line_key in ["line1", "line2", "line3", "line4"]:
		for point in Layout.line_stops(line_key):
			min_x = minf(min_x, point.x)
			max_x = maxf(max_x, point.x)
			min_z = minf(min_z, point.y)
			max_z = maxf(max_z, point.y)
	var depot := Layout.depot_position()
	min_x = minf(min_x, depot.x)
	max_x = maxf(max_x, depot.x)
	min_z = minf(min_z, depot.y)
	max_z = maxf(max_z, depot.y)
	return Rect2(
		Vector2(min_x - LEGACY_MARGIN, min_z - LEGACY_MARGIN),
		Vector2(max_x - min_x + LEGACY_MARGIN * 2.0, max_z - min_z + LEGACY_MARGIN * 2.0)
	)

static func rect_from_payload(map_definition: Dictionary) -> Rect2:
	var raw: Dictionary = map_definition.get("bounds", {})
	var width := maxf(500.0, float(raw.get("width", REGION_HALF_EXTENT * 2.0)))
	var height := maxf(500.0, float(raw.get("height", REGION_HALF_EXTENT * 2.0)))
	return Rect2(Vector2(float(raw.get("x", -width * 0.5)), float(raw.get("y", -height * 0.5))), Vector2(width, height))

static func _serialize_bounds(rect: Rect2) -> Dictionary:
	return {
		"x": rect.position.x,
		"y": rect.position.y,
		"width": rect.size.x,
		"height": rect.size.y,
	}

static func _outside_connections(rect: Rect2) -> Array:
	var center := rect.get_center()
	var edge_x := rect.position.x + rect.size.x
	var edge_y := rect.position.y + rect.size.y
	return [
		{"id": "north-gateway", "kind": "road", "position": {"x": center.x, "y": rect.position.y}},
		{"id": "east-gateway", "kind": "rail", "position": {"x": edge_x, "y": center.y}},
		{"id": "south-gateway", "kind": "road", "position": {"x": center.x, "y": edge_y}},
		{"id": "west-gateway", "kind": "utility", "position": {"x": rect.position.x, "y": center.y}},
	]
