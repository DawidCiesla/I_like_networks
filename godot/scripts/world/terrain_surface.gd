extends RefCounted
class_name TerrainSurface

const Terrain = preload("res://scripts/world/terrain_model.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const TerrainEditData = preload("res://scripts/world/terrain_edit_data.gd")

# These constants define the actual triangulated surface rendered by
# terrain_renderer.gd. Anything that must sit flush on the visible terrain
# should query this class instead of sampling TerrainModel directly.
const SAMPLE_STEP := 58.0
const MARGIN := 620.0
const VERTEX_HEIGHT_CACHE_CAPACITY := 32768

static var _world_bounds_cached := false
static var _cached_world_bounds := Rect2()
static var _cached_world_bounds_key := ""
static var _vertex_height_cache_seed := 0
static var _vertex_height_cache_seed_initialized := false
static var _vertex_height_cache_profile := ""
static var _vertex_height_cache: Dictionary = {}
static var _vertex_height_cache_order: Array = []
static var _vertex_height_cache_next_eviction := 0
static var _vertex_height_cache_size := 0
static var _terrain_edit_layer: Variant = null
static var _terrain_edit_seed := 0


static func set_terrain_edit_payload(payload: Variant) -> void:
	_terrain_edit_layer = null
	_terrain_edit_seed = 0
	if typeof(payload) != TYPE_DICTIONARY or (payload as Dictionary).is_empty():
		return
	var imported: Dictionary = TerrainEditData.from_dict(payload)
	if not bool(imported.get("ok", false)):
		return
	_terrain_edit_layer = imported.get("data")
	_terrain_edit_seed = int(payload.get("seed", 0))


static func world_bounds() -> Rect2:
	var map_payload := MapDefinition.active_definition()
	var map_id := str(map_payload.get("id", MapDefinition.LEGACY_CITY_MAP_ID))
	var bounds_payload: Dictionary = map_payload.get("bounds", {})
	var cache_key := "%s|%s|%s|%s|%s" % [
		map_id,
		str(bounds_payload.get("x", "")),
		str(bounds_payload.get("y", "")),
		str(bounds_payload.get("width", "")),
		str(bounds_payload.get("height", "")),
	]
	if _world_bounds_cached and cache_key == _cached_world_bounds_key:
		return _cached_world_bounds

	if map_id != MapDefinition.LEGACY_CITY_MAP_ID or not bounds_payload.is_empty():
		_cached_world_bounds = MapDefinition.rect_from_payload(
			MapDefinition.normalize(map_payload, int(map_payload.get("seed", 0)), true)
		)
		_cached_world_bounds_key = cache_key
		_world_bounds_cached = true
		return _cached_world_bounds

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
	_cached_world_bounds = Rect2(
		Vector2(min_x - MARGIN, min_z - MARGIN),
		Vector2(max_x - min_x + MARGIN * 2.0, max_z - min_z + MARGIN * 2.0)
	)
	_cached_world_bounds_key = cache_key
	_world_bounds_cached = true
	return _cached_world_bounds


static func grid_steps(rect: Rect2) -> Vector2i:
	return Vector2i(
		maxi(2, ceili(rect.size.x / SAMPLE_STEP)),
		maxi(2, ceili(rect.size.y / SAMPLE_STEP))
	)


static func height(seed: int, x: float, z: float) -> float:
	var rect := world_bounds()
	var rect_end := rect.position + rect.size
	if x < rect.position.x or x > rect_end.x or z < rect.position.y or z > rect_end.y:
		return _analytic_height(seed, x, z) + _terrain_edit_delta(seed, x, z)

	var steps := grid_steps(rect)
	var step_x := rect.size.x / float(steps.x)
	var step_z := rect.size.y / float(steps.y)
	var local_x := (x - rect.position.x) / step_x
	var local_z := (z - rect.position.y) / step_z
	var x_index := clampi(floori(local_x), 0, steps.x - 1)
	var z_index := clampi(floori(local_z), 0, steps.y - 1)
	var tx := clampf(local_x - float(x_index), 0.0, 1.0)
	var tz := clampf(local_z - float(z_index), 0.0, 1.0)
	var x0 := rect.position.x + step_x * float(x_index)
	var x1 := x0 + step_x
	var z0 := rect.position.y + step_z * float(z_index)
	var z1 := z0 + step_z
	var h00 := _vertex_height(seed, x0, z0)
	var h10 := _vertex_height(seed, x1, z0)
	var h01 := _vertex_height(seed, x0, z1)
	var h11 := _vertex_height(seed, x1, z1)
	var surface_height := 0.0
	if tz <= tx:
		surface_height = h00 + tx * (h10 - h00) + tz * (h11 - h10)
	else:
		surface_height = h00 + tx * (h11 - h01) + tz * (h01 - h00)
	return surface_height + _terrain_edit_delta(seed, x, z)


static func _terrain_edit_delta(seed: int, x: float, z: float) -> float:
	if _terrain_edit_layer == null or seed != _terrain_edit_seed:
		return 0.0
	return float(_terrain_edit_layer.edit_delta_at(x, z))


static func _uses_regional_profile() -> bool:
	return str(MapDefinition.active_definition().get("id", MapDefinition.LEGACY_CITY_MAP_ID)) != MapDefinition.LEGACY_CITY_MAP_ID


static func _profile_key() -> String:
	return "regional" if _uses_regional_profile() else "legacy"


static func _analytic_height(seed: int, x: float, z: float) -> float:
	return Terrain.regional_height(seed, x, z) if _uses_regional_profile() else Terrain.height(seed, x, z)


static func _vertex_height(seed: int, x: float, z: float) -> float:
	var profile := _profile_key()
	if (
		not _vertex_height_cache_seed_initialized
		or seed != _vertex_height_cache_seed
		or profile != _vertex_height_cache_profile
	):
		_vertex_height_cache_seed = seed
		_vertex_height_cache_seed_initialized = true
		_vertex_height_cache_profile = profile
		_vertex_height_cache.clear()
		_vertex_height_cache_order.clear()
		_vertex_height_cache_next_eviction = 0
		_vertex_height_cache_size = 0

	var column: Dictionary = _vertex_height_cache.get(x, {})
	if column.has(z):
		var cached_height: float = column[z]
		return cached_height

	var value := _analytic_height(seed, x, z)
	if _vertex_height_cache_size < VERTEX_HEIGHT_CACHE_CAPACITY:
		column[z] = value
		_vertex_height_cache[x] = column
		_vertex_height_cache_order.append([x, z])
		_vertex_height_cache_size += 1
	else:
		var evicted_point: Array = _vertex_height_cache_order[_vertex_height_cache_next_eviction]
		var evicted_x: float = evicted_point[0]
		var evicted_z: float = evicted_point[1]
		var evicted_column: Dictionary = _vertex_height_cache[evicted_x]
		evicted_column.erase(evicted_z)
		_vertex_height_cache_size -= 1
		if evicted_column.is_empty():
			_vertex_height_cache.erase(evicted_x)
		else:
			_vertex_height_cache[evicted_x] = evicted_column
		column = _vertex_height_cache.get(x, {})
		column[z] = value
		_vertex_height_cache[x] = column
		_vertex_height_cache_order[_vertex_height_cache_next_eviction] = [x, z]
		_vertex_height_cache_size += 1
		_vertex_height_cache_next_eviction = (
			_vertex_height_cache_next_eviction + 1
		) % VERTEX_HEIGHT_CACHE_CAPACITY
	return value
