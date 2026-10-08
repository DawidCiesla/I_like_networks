extends RefCounted
class_name TerrainEditData

const TerrainModel = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")

const FORMAT_VERSION := 1
const SOURCE_TERRAIN_MODEL := "terrain_model"
const SOURCE_TERRAIN_SURFACE := "terrain_surface"
const MAX_EDIT_SAMPLES := 100000
const MAX_BRUSH_RADIUS_STEPS := 128.0
const MAX_WORLD_COORDINATE := 10000000.0
const MAX_ABSOLUTE_EDIT := 100000.0
const ZERO_EPSILON := 0.000001

var seed: int
var grid_step: float
var source: String

# String keys keep the sparse lattice easy to serialize as ordinary data.
var _deltas: Dictionary = {}


func _init(
	p_seed: int = 0,
	p_grid_step: float = 58.0,
	p_source: String = SOURCE_TERRAIN_SURFACE
) -> void:
	seed = p_seed
	grid_step = p_grid_step if is_finite(p_grid_step) and p_grid_step >= 0.01 and p_grid_step <= 100000.0 else 58.0
	source = p_source if _valid_source(p_source) else SOURCE_TERRAIN_SURFACE


func edit_count() -> int:
	return _deltas.size()


func terrain_height_at(x: float, z: float) -> float:
	if not _valid_coordinate(x) or not _valid_coordinate(z):
		return 0.0
	return _sample_base_height(x, z)


func height_at(x: float, z: float) -> float:
	if not _valid_coordinate(x) or not _valid_coordinate(z):
		return 0.0
	return _sample_base_height(x, z) + _delta_at(x, z)


func edit_delta_at(x: float, z: float) -> float:
	if not _valid_coordinate(x) or not _valid_coordinate(z):
		return 0.0
	return _delta_at(x, z)


func raise_brush(center: Vector2, radius: float, strength: float) -> Dictionary:
	if not is_finite(strength) or strength < 0.0:
		return _failure("raise strength must be finite and non-negative")
	return _apply_height_offset(center, radius, strength)


func lower_brush(center: Vector2, radius: float, strength: float) -> Dictionary:
	if not is_finite(strength) or strength < 0.0:
		return _failure("lower strength must be finite and non-negative")
	return _apply_height_offset(center, radius, -strength)


func flatten_to_target(
	center: Vector2,
	radius: float,
	target_height: float,
	strength: float = 1.0
) -> Dictionary:
	if not is_finite(target_height):
		return _failure("flatten target must be finite")
	if absf(target_height) > MAX_WORLD_COORDINATE:
		return _failure("flatten target is out of bounds")
	if not _valid_strength(strength):
		return _failure("flatten strength must be between zero and one")

	var prepared := _brush_nodes(center, radius)
	if not bool(prepared.get("ok", false)):
		return prepared
	var changes: Array = []
	for node in prepared["nodes"]:
		var gx: int = node[0]
		var gz: int = node[1]
		var falloff: float = node[2]
		var x := float(gx) * grid_step
		var z := float(gz) * grid_step
		var current := _sample_base_height(x, z) + _delta_at_grid(gx, gz)
		var next_height := lerpf(current, target_height, strength * falloff)
		changes.append([gx, gz, next_height - _sample_base_height(x, z)])
	return _commit_changes(changes, prepared["nodes"].size())


func flatten_to_terrain_sample(
	center: Vector2,
	radius: float,
	strength: float = 1.0
) -> Dictionary:
	return flatten_to_target(center, radius, terrain_height_at(center.x, center.y), strength)


func smooth_brush(center: Vector2, radius: float, strength: float = 1.0) -> Dictionary:
	if not _valid_strength(strength):
		return _failure("smooth strength must be between zero and one")
	var prepared := _brush_nodes(center, radius)
	if not bool(prepared.get("ok", false)):
		return prepared

	# Read the whole neighborhood before committing, so results do not depend on
	# the order in which the brush visits lattice points.
	var changes: Array = []
	for node in prepared["nodes"]:
		var gx: int = node[0]
		var gz: int = node[1]
		var falloff: float = node[2]
		var average := 0.0
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var neighbor_x := float(gx + dx) * grid_step
				var neighbor_z := float(gz + dz) * grid_step
				average += _sample_base_height(neighbor_x, neighbor_z) + _delta_at_grid(gx + dx, gz + dz)
		average /= 9.0
		var x := float(gx) * grid_step
		var z := float(gz) * grid_step
		var base_height := _sample_base_height(x, z)
		var current := base_height + _delta_at_grid(gx, gz)
		var next_height := lerpf(current, average, strength * falloff)
		changes.append([gx, gz, next_height - base_height])
	return _commit_changes(changes, prepared["nodes"].size())


func to_dict() -> Dictionary:
	var keys: Array = _deltas.keys()
	keys.sort()
	var edits: Array = []
	for key in keys:
		var parts := str(key).split(":")
		edits.append([int(parts[0]), int(parts[1]), float(_deltas[key])])
	return {
		"version": FORMAT_VERSION,
		"seed": seed,
		"grid_step": grid_step,
		"source": source,
		"edits": edits,
	}


static func from_dict(payload: Dictionary) -> Dictionary:
	if int(payload.get("version", -1)) != FORMAT_VERSION:
		return {"ok": false, "error": "unsupported terrain edit version"}
	if not _is_integer(payload.get("seed", null)):
		return {"ok": false, "error": "terrain edit seed must be an integer"}
	var raw_step: Variant = payload.get("grid_step", null)
	if not _is_number(raw_step):
		return {"ok": false, "error": "terrain edit grid step must be numeric"}
	var parsed_step := float(raw_step)
	if not is_finite(parsed_step) or parsed_step < 0.01 or parsed_step > 100000.0:
		return {"ok": false, "error": "terrain edit grid step is out of bounds"}
	var parsed_source := str(payload.get("source", ""))
	if not _valid_source(parsed_source):
		return {"ok": false, "error": "unknown terrain edit source"}
	var raw_edits: Variant = payload.get("edits", null)
	if typeof(raw_edits) != TYPE_ARRAY:
		return {"ok": false, "error": "terrain edits must be an array"}
	var edits: Array = raw_edits
	if edits.size() > MAX_EDIT_SAMPLES:
		return {"ok": false, "error": "terrain edit sample limit exceeded"}

	# Load this script by path so the factory also works with a direct --script
	# invocation, where Godot has not generated the global class-name cache yet.
	var result: Variant = (load("res://scripts/world/terrain_edit_data.gd") as GDScript).new(
		int(payload["seed"]), parsed_step, parsed_source
	)
	for raw_edit in edits:
		if typeof(raw_edit) != TYPE_ARRAY:
			return {"ok": false, "error": "terrain edit sample must be an array"}
		var row: Array = raw_edit
		if row.size() != 3 or not _is_integer(row[0]) or not _is_integer(row[1]) or not _is_number(row[2]):
			return {"ok": false, "error": "terrain edit sample must contain integer coordinates and a number"}
		var gx := int(row[0])
		var gz := int(row[1])
		var delta := float(row[2])
		if absf(float(gx) * parsed_step) > MAX_WORLD_COORDINATE or absf(float(gz) * parsed_step) > MAX_WORLD_COORDINATE:
			return {"ok": false, "error": "terrain edit coordinate is out of bounds"}
		if not is_finite(delta) or absf(delta) > MAX_ABSOLUTE_EDIT:
			return {"ok": false, "error": "terrain edit height is out of bounds"}
		var key := _key(gx, gz)
		if result._deltas.has(key):
			return {"ok": false, "error": "duplicate terrain edit sample"}
		if absf(delta) > ZERO_EPSILON:
			result._deltas[key] = delta
	return {"ok": true, "data": result}


func _apply_height_offset(center: Vector2, radius: float, amount: float) -> Dictionary:
	var prepared := _brush_nodes(center, radius)
	if not bool(prepared.get("ok", false)):
		return prepared
	var changes: Array = []
	for node in prepared["nodes"]:
		var gx: int = node[0]
		var gz: int = node[1]
		var falloff: float = node[2]
		changes.append([gx, gz, clampf(_delta_at_grid(gx, gz) + amount * falloff, -MAX_ABSOLUTE_EDIT, MAX_ABSOLUTE_EDIT)])
	return _commit_changes(changes, prepared["nodes"].size())


func _brush_nodes(center: Vector2, radius: float) -> Dictionary:
	if not _valid_coordinate(center.x) or not _valid_coordinate(center.y):
		return _failure("brush center is out of bounds")
	if not is_finite(radius) or radius <= 0.0 or radius > grid_step * MAX_BRUSH_RADIUS_STEPS:
		return _failure("brush radius must be positive and bounded")
	var min_x := ceili((center.x - radius) / grid_step)
	var max_x := floori((center.x + radius) / grid_step)
	var min_z := ceili((center.y - radius) / grid_step)
	var max_z := floori((center.y + radius) / grid_step)
	var nodes: Array = []
	var radius_squared := radius * radius
	for gz in range(min_z, max_z + 1):
		for gx in range(min_x, max_x + 1):
			var sample_x := float(gx) * grid_step
			var sample_z := float(gz) * grid_step
			if not _valid_coordinate(sample_x) or not _valid_coordinate(sample_z):
				continue
			var dx := sample_x - center.x
			var dz := sample_z - center.y
			var distance_squared := dx * dx + dz * dz
			if distance_squared >= radius_squared:
				continue
			var distance_ratio := sqrt(distance_squared) / radius
			var smooth := distance_ratio * distance_ratio * (3.0 - 2.0 * distance_ratio)
			nodes.append([gx, gz, 1.0 - smooth])
	return {"ok": true, "nodes": nodes}


func _commit_changes(changes: Array, touched_count: int) -> Dictionary:
	var additions: Dictionary = {}
	for change in changes:
		var gx: int = change[0]
		var gz: int = change[1]
		var next_delta: float = change[2]
		if absf(next_delta) > ZERO_EPSILON and not _deltas.has(_key(gx, gz)):
			additions[_key(gx, gz)] = true
	if _deltas.size() + additions.size() > MAX_EDIT_SAMPLES:
		return _failure("terrain edit sample limit exceeded")

	var changed_count := 0
	for change in changes:
		var gx: int = change[0]
		var gz: int = change[1]
		var next_delta: float = clampf(change[2], -MAX_ABSOLUTE_EDIT, MAX_ABSOLUTE_EDIT)
		var key := _key(gx, gz)
		var old_delta := _delta_at_grid(gx, gz)
		if absf(old_delta - next_delta) <= ZERO_EPSILON:
			continue
		changed_count += 1
		if absf(next_delta) <= ZERO_EPSILON:
			_deltas.erase(key)
		else:
			_deltas[key] = next_delta
	return {"ok": true, "touched": touched_count, "changed": changed_count}


func _delta_at(x: float, z: float) -> float:
	var local_x := x / grid_step
	var local_z := z / grid_step
	var x0 := floori(local_x)
	var z0 := floori(local_z)
	var tx := local_x - float(x0)
	var tz := local_z - float(z0)
	var d00 := _delta_at_grid(x0, z0)
	var d10 := _delta_at_grid(x0 + 1, z0)
	var d01 := _delta_at_grid(x0, z0 + 1)
	var d11 := _delta_at_grid(x0 + 1, z0 + 1)
	return lerpf(lerpf(d00, d10, tx), lerpf(d01, d11, tx), tz)


func _delta_at_grid(gx: int, gz: int) -> float:
	return float(_deltas.get(_key(gx, gz), 0.0))


func _sample_base_height(x: float, z: float) -> float:
	if source == SOURCE_TERRAIN_MODEL:
		return TerrainModel.height(seed, x, z)
	return TerrainSurface.height(seed, x, z)


func _valid_coordinate(value: float) -> bool:
	return is_finite(value) and absf(value) <= MAX_WORLD_COORDINATE


func _valid_strength(value: float) -> bool:
	return is_finite(value) and value >= 0.0 and value <= 1.0


static func _valid_source(value: String) -> bool:
	return value == SOURCE_TERRAIN_MODEL or value == SOURCE_TERRAIN_SURFACE


static func _is_integer(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	var numeric_value := float(value)
	return is_finite(numeric_value) and absf(numeric_value) <= 9007199254740991.0 and floorf(numeric_value) == numeric_value


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


static func _key(gx: int, gz: int) -> String:
	return "%d:%d" % [gx, gz]


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
