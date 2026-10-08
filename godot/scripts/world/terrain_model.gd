extends RefCounted
class_name TerrainModel

const TAU := PI * 2.0
const GRASSLAND_COLOR := Color(0.26, 0.38, 0.22)
const MEADOW_COLOR := Color(0.34, 0.46, 0.24)
const FOREST_COLOR := Color(0.18, 0.31, 0.18)
const HILLSIDE_COLOR := Color(0.31, 0.34, 0.25)
const RANDOM_CACHE_CAPACITY := 32768

static var _random_cache_seed := 0
static var _random_cache_seed_initialized := false
static var _random_cache: Dictionary = {}
static var _random_cache_order: Array[String] = []
static var _random_cache_next_eviction := 0

static func _hash32(value: String) -> int:
	var hash_value: int = 2166136261
	for index in range(value.length()):
		hash_value = (hash_value ^ value.unicode_at(index)) & 0xffffffff
		hash_value = (hash_value * 16777619) & 0xffffffff
	return hash_value

static func _random01(seed: int, key: String) -> float:
	if not _random_cache_seed_initialized or seed != _random_cache_seed:
		_random_cache_seed = seed
		_random_cache_seed_initialized = true
		_random_cache.clear()
		_random_cache_order.clear()
		_random_cache_next_eviction = 0

	if _random_cache.has(key):
		return _random_cache[key]

	var value := float(_hash32("%s:%s" % [seed, key])) / 4294967295.0
	if _random_cache.size() < RANDOM_CACHE_CAPACITY:
		_random_cache[key] = value
		_random_cache_order.append(key)
	else:
		var evicted_key := _random_cache_order[_random_cache_next_eviction]
		_random_cache.erase(evicted_key)
		_random_cache_order[_random_cache_next_eviction] = key
		_random_cache[key] = value
		_random_cache_next_eviction = (_random_cache_next_eviction + 1) % RANDOM_CACHE_CAPACITY
	return value

static func _smoothstep(value: float) -> float:
	return value * value * (3.0 - 2.0 * value)

static func _transition_weight(value: float, start: float, finish: float) -> float:
	return _smoothstep(clampf((value - start) / (finish - start), 0.0, 1.0))

static func _lattice_value(
	seed: int,
	x: float,
	z: float,
	scale: float,
	channel: String
) -> float:
	var gx := floori(x / scale)
	var gz := floori(z / scale)
	var tx := _smoothstep(x / scale - float(gx))
	var tz := _smoothstep(z / scale - float(gz))

	var v00 := _random01(seed, "%s:%d:%d" % [channel, gx, gz]) * 2.0 - 1.0
	var v10 := _random01(seed, "%s:%d:%d" % [channel, gx + 1, gz]) * 2.0 - 1.0
	var v01 := _random01(seed, "%s:%d:%d" % [channel, gx, gz + 1]) * 2.0 - 1.0
	var v11 := _random01(seed, "%s:%d:%d" % [channel, gx + 1, gz + 1]) * 2.0 - 1.0

	var a := lerpf(v00, v10, tx)
	var b := lerpf(v01, v11, tx)
	return lerpf(a, b, tz)

static func _fbm(
	seed: int,
	x: float,
	z: float,
	base_scale: float,
	octaves: int,
	channel: String
) -> float:
	var value := 0.0
	var amplitude := 1.0
	var frequency := 1.0
	var amplitude_total := 0.0

	for octave in range(octaves):
		value += _lattice_value(
			seed,
			x,
			z,
			base_scale / frequency,
			"%s:%d" % [channel, octave]
		) * amplitude
		amplitude_total += amplitude
		amplitude *= 0.5
		frequency *= 2.0

	return 0.0 if amplitude_total <= 0.0 else value / amplitude_total

static func _seed_phase(seed: int, channel: String) -> float:
	return _random01(seed, "phase:%s" % channel) * TAU

static func height(seed: int, x: float, z: float) -> float:
	var broad := _fbm(seed, x, z, 1050.0, 4, "height-broad")
	var detail := _fbm(seed, x, z, 340.0, 3, "height-detail")
	var ridge := sin(x * 0.00125 + z * 0.00072 + _seed_phase(seed, "ridge"))
	return broad * 36.0 + detail * 9.0 + ridge * 5.0

static func slope_degrees(seed: int, x: float, z: float, sample_distance: float = 12.0) -> float:
	var left := height(seed, x - sample_distance, z)
	var right := height(seed, x + sample_distance, z)
	var back := height(seed, x, z - sample_distance)
	var front := height(seed, x, z + sample_distance)
	var dx := (right - left) / (sample_distance * 2.0)
	var dz := (front - back) / (sample_distance * 2.0)
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))

static func moisture(seed: int, x: float, z: float) -> float:
	return _fbm(seed, x + 791.0, z - 433.0, 720.0, 4, "moisture") * 0.5 + 0.5

static func forest_potential(seed: int, x: float, z: float) -> float:
	var wet := moisture(seed, x, z)
	var slope := slope_degrees(seed, x, z)
	return _forest_score(seed, x, z, wet, slope)

static func _forest_score(seed: int, x: float, z: float, wet: float, slope: float) -> float:
	var noise := _fbm(seed, x - 311.0, z + 907.0, 610.0, 4, "forest") * 0.5 + 0.5
	var slope_bonus: float = minf(0.18, slope / 90.0)
	return clamp(noise * 0.68 + wet * 0.32 + slope_bonus, 0.0, 1.0)

static func biome(seed: int, x: float, z: float) -> String:
	var slope := slope_degrees(seed, x, z)
	var wet := moisture(seed, x, z)
	var forest := _forest_score(seed, x, z, wet, slope)

	if slope >= 18.0:
		return "hillside"
	if forest >= 0.61:
		return "forest"
	if wet >= 0.64:
		return "meadow"
	return "grassland"

static func terrain_color(seed: int, x: float, z: float) -> Color:
	var slope := slope_degrees(seed, x, z)
	var wet := moisture(seed, x, z)
	var forest := _forest_score(seed, x, z, wet, slope)
	var hillside_weight := _transition_weight(slope, 10.0, 24.0)
	var forest_weight := _transition_weight(forest, 0.45, 0.76) * (1.0 - hillside_weight * 0.8)
	var meadow_weight := _transition_weight(wet, 0.52, 0.76) * (1.0 - forest_weight)

	var color := GRASSLAND_COLOR.lerp(MEADOW_COLOR, meadow_weight)
	color = color.lerp(FOREST_COLOR, forest_weight)
	color = color.lerp(HILLSIDE_COLOR, hillside_weight)
	var surface_tint := _lattice_value(seed, x, z, 260.0, "terrain-tint") * 0.018
	color.r += surface_tint
	color.g += surface_tint * 0.92
	color.b += surface_tint * 0.68
	return color
