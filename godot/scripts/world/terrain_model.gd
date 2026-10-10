extends RefCounted
class_name TerrainModel

const TerrainSampler = preload("res://scripts/world/terrain_sampler.gd")

const TAU := PI * 2.0
const GRASSLAND_COLOR := Color(0.26, 0.38, 0.22)
const MEADOW_COLOR := Color(0.34, 0.46, 0.24)
const FOREST_COLOR := Color(0.18, 0.31, 0.18)
const HILLSIDE_COLOR := Color(0.31, 0.34, 0.25)
const REGIONAL_GRASSLAND_COLOR := Color(0.235, 0.355, 0.155)
const REGIONAL_MEADOW_COLOR := Color(0.31, 0.455, 0.20)
const REGIONAL_FOREST_COLOR := Color(0.105, 0.225, 0.095)
const REGIONAL_HILLSIDE_COLOR := Color(0.31, 0.305, 0.245)
const REGIONAL_ROCK_COLOR := Color(0.39, 0.385, 0.35)
const REGIONAL_RIPARIAN_COLOR := Color(0.17, 0.35, 0.145)
const REGIONAL_DRY_GRASS_COLOR := Color(0.355, 0.365, 0.19)
const RANDOM_CACHE_CAPACITY := 32768
const REGIONAL_SAMPLE_CACHE_CAPACITY := 8192

static var _default_sampler: TerrainSampler
# Kept as an alias for legacy diagnostics that inspect the FIFO cache directly.
static var _random_cache: Dictionary = {}


static func create_sampler() -> TerrainSampler:
	return TerrainSampler.new()


static func _sampler() -> TerrainSampler:
	if _default_sampler == null:
		_default_sampler = TerrainSampler.new()
		_random_cache = _default_sampler._random_cache
	return _default_sampler


static func _regional_samples(seed: int, x: float, z: float) -> Dictionary:
	return _sampler()._regional_samples(seed, x, z)


static func regional_surface_sample(seed: int, x: float, z: float) -> Dictionary:
	return _sampler().regional_surface_sample(seed, x, z)


static func _hash32(value: String) -> int:
	return _sampler()._hash32(value)


static func _random01(seed: int, key: String) -> float:
	var value = _sampler()._random01(seed, key)
	_random_cache = _sampler()._random_cache
	return value


static func _smoothstep(value: float) -> float:
	return _sampler()._smoothstep(value)


static func _transition_weight(value: float, start: float, finish: float) -> float:
	return _sampler()._transition_weight(value, start, finish)


static func _lattice_value(
	seed: int,
	x: float,
	z: float,
	scale: float,
	channel: String
) -> float:
	return _sampler()._lattice_value(seed, x, z, scale, channel)


static func _fbm(
	seed: int,
	x: float,
	z: float,
	base_scale: float,
	octaves: int,
	channel: String
) -> float:
	return _sampler()._fbm(seed, x, z, base_scale, octaves, channel)


static func _seed_phase(seed: int, channel: String) -> float:
	return _sampler()._seed_phase(seed, channel)


static func height(seed: int, x: float, z: float) -> float:
	return _sampler().height(seed, x, z)


static func slope_degrees(seed: int, x: float, z: float, sample_distance: float = 12.0) -> float:
	return _sampler().slope_degrees(seed, x, z, sample_distance)


static func moisture(seed: int, x: float, z: float) -> float:
	return _sampler().moisture(seed, x, z)


static func forest_potential(seed: int, x: float, z: float) -> float:
	return _sampler().forest_potential(seed, x, z)


static func _forest_score(seed: int, x: float, z: float, wet: float, slope: float) -> float:
	return _sampler()._forest_score(seed, x, z, wet, slope)


static func biome(seed: int, x: float, z: float) -> String:
	return _sampler().biome(seed, x, z)


static func terrain_color(seed: int, x: float, z: float) -> Color:
	return _sampler().terrain_color(seed, x, z)


static func _ridged_fbm(
	seed: int,
	x: float,
	z: float,
	base_scale: float,
	octaves: int,
	channel: String
) -> float:
	return _sampler()._ridged_fbm(seed, x, z, base_scale, octaves, channel)


static func river_profile(seed: int, x: float, z: float) -> Dictionary:
	return _sampler().river_profile(seed, x, z)


static func regional_height(seed: int, x: float, z: float) -> float:
	return _sampler().regional_height(seed, x, z)


static func regional_slope_degrees(seed: int, x: float, z: float, sample_distance: float = 12.0) -> float:
	return _sampler().regional_slope_degrees(seed, x, z, sample_distance)


static func regional_moisture(seed: int, x: float, z: float) -> float:
	return _sampler().regional_moisture(seed, x, z)


static func regional_forest_potential(seed: int, x: float, z: float) -> float:
	return _sampler().regional_forest_potential(seed, x, z)


static func regional_forest_score(seed: int, x: float, z: float, wet: float, slope: float) -> float:
	return _sampler().regional_forest_score(seed, x, z, wet, slope)


static func regional_ground_cover_potential(seed: int, x: float, z: float) -> float:
	return _sampler().regional_ground_cover_potential(seed, x, z)


static func _regional_ground_cover_from_samples(
	seed: int,
	x: float,
	z: float,
	wet: float,
	slope: float,
	forest: float
) -> float:
	return _sampler()._regional_ground_cover_from_samples(seed, x, z, wet, slope, forest)


static func regional_biome(seed: int, x: float, z: float) -> String:
	return _sampler().regional_biome(seed, x, z)


static func regional_terrain_color(seed: int, x: float, z: float) -> Color:
	return _sampler().regional_terrain_color(seed, x, z)


static func _regional_terrain_color_from_samples(
	seed: int,
	x: float,
	z: float,
	elevation: float,
	slope: float,
	wet: float,
	forest: float
) -> Color:
	return _sampler()._regional_terrain_color_from_samples(seed, x, z, elevation, slope, wet, forest)
