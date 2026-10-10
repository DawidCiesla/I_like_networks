extends RefCounted
class_name TerrainSampler

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

var _random_cache_seed := 0
var _random_cache_seed_initialized := false
var _random_cache: Dictionary = {}
var _random_cache_order: Array[String] = []
var _random_cache_next_eviction := 0

# Biome queries reuse hydrology and slope at the same point many times.
# Bound this cache so traversing a large region cannot retain the whole world.
const REGIONAL_SAMPLE_CACHE_CAPACITY := 8192
var _regional_sample_seed := 0
var _regional_sample_seed_initialized := false
var _regional_sample_cache: Dictionary = {}


func _regional_samples(seed: int, x: float, z: float) -> Dictionary:
	if not _regional_sample_seed_initialized or seed != _regional_sample_seed:
		_regional_sample_seed = seed
		_regional_sample_seed_initialized = true
		_regional_sample_cache.clear()
	var key := Vector2(x, z)
	var samples: Dictionary = _regional_sample_cache.get(key, {})
	# Vector2 uses single precision; never reuse a nearby but different position.
	if samples.get("x") == x and samples.get("z") == z:
		return samples
	if _regional_sample_cache.size() >= REGIONAL_SAMPLE_CACHE_CAPACITY:
		_regional_sample_cache.clear()
	samples = {"x": x, "z": z}
	_regional_sample_cache[key] = samples
	return samples


func regional_surface_sample(seed: int, x: float, z: float) -> Dictionary:
	var elevation := regional_height(seed, x, z)
	var slope := regional_slope_degrees(seed, x, z)
	var wet := regional_moisture(seed, x, z)
	var forest := regional_forest_score(seed, x, z, wet, slope)
	var color := _regional_terrain_color_from_samples(seed, x, z, elevation, slope, wet, forest)
	var ground_cover := _regional_ground_cover_from_samples(seed, x, z, wet, slope, forest)
	return {
		"height": elevation,
		"slope": slope,
		"moisture": wet,
		"forest": forest,
		"color": color,
		"ground_cover": ground_cover,
	}


func _hash32(value: String) -> int:
	var hash_value: int = 2166136261
	for index in range(value.length()):
		hash_value = (hash_value ^ value.unicode_at(index)) & 0xffffffff
		hash_value = (hash_value * 16777619) & 0xffffffff
	return hash_value


func _random01(seed: int, key: String) -> float:
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


func _smoothstep(value: float) -> float:
	return value * value * (3.0 - 2.0 * value)


func _transition_weight(value: float, start: float, finish: float) -> float:
	return _smoothstep(clampf((value - start) / (finish - start), 0.0, 1.0))


func _lattice_value(
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


func _fbm(
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


func _seed_phase(seed: int, channel: String) -> float:
	return _random01(seed, "phase:%s" % channel) * TAU


# -----------------------------------------------------------------------------
# Legacy Bus Era terrain. These functions intentionally retain the exact
# historical algorithm because old saves and regression tests depend on it.
# -----------------------------------------------------------------------------
func height(seed: int, x: float, z: float) -> float:
	var broad := _fbm(seed, x, z, 1050.0, 4, "height-broad")
	var detail := _fbm(seed, x, z, 340.0, 3, "height-detail")
	var ridge := sin(x * 0.00125 + z * 0.00072 + _seed_phase(seed, "ridge"))
	return broad * 36.0 + detail * 9.0 + ridge * 5.0


func slope_degrees(seed: int, x: float, z: float, sample_distance: float = 12.0) -> float:
	var left := height(seed, x - sample_distance, z)
	var right := height(seed, x + sample_distance, z)
	var back := height(seed, x, z - sample_distance)
	var front := height(seed, x, z + sample_distance)
	var dx := (right - left) / (sample_distance * 2.0)
	var dz := (front - back) / (sample_distance * 2.0)
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))


func moisture(seed: int, x: float, z: float) -> float:
	return _fbm(seed, x + 791.0, z - 433.0, 720.0, 4, "moisture") * 0.5 + 0.5


func forest_potential(seed: int, x: float, z: float) -> float:
	var wet := moisture(seed, x, z)
	var slope := slope_degrees(seed, x, z)
	return _forest_score(seed, x, z, wet, slope)


func _forest_score(seed: int, x: float, z: float, wet: float, slope: float) -> float:
	var noise := _fbm(seed, x - 311.0, z + 907.0, 610.0, 4, "forest") * 0.5 + 0.5
	var slope_bonus: float = minf(0.18, slope / 90.0)
	return clamp(noise * 0.68 + wet * 0.32 + slope_bonus, 0.0, 1.0)


func biome(seed: int, x: float, z: float) -> String:
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


func terrain_color(seed: int, x: float, z: float) -> Color:
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


# -----------------------------------------------------------------------------
# Regional sandbox terrain. This profile is free to evolve independently from
# the old Bus Era world and is tuned for the 24 x 24 km procedural region.
# -----------------------------------------------------------------------------
func _ridged_fbm(
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
		var sample := _lattice_value(
			seed,
			x,
			z,
			base_scale / frequency,
			"%s:%d" % [channel, octave]
		)
		var ridge := 1.0 - absf(sample)
		ridge *= ridge
		value += ridge * amplitude
		amplitude_total += amplitude
		amplitude *= 0.52
		frequency *= 2.05
	return 0.0 if amplitude_total <= 0.0 else value / amplitude_total


func river_profile(seed: int, x: float, z: float) -> Dictionary:
	var samples := _regional_samples(seed, x, z)
	if samples.has("river"):
		return samples["river"].duplicate()
	var warp_scale := 3400.0
	var warp_strength := 520.0
	var warp_x := _fbm(seed, x + 371.0, z - 811.0, warp_scale, 3, "hydro-warp-x") * warp_strength
	var warp_z := _fbm(seed, x - 947.0, z + 557.0, warp_scale, 3, "hydro-warp-z") * warp_strength
	var wx := x + warp_x
	var wz := z + warp_z

	var major_field := _fbm(seed, wx, wz, 2700.0, 5, "river-major")
	var major_target := lerpf(-0.16, 0.18, _random01(seed, "river-major-target"))
	var major_size_noise := _fbm(seed, wx + 1700.0, wz - 900.0, 5200.0, 3, "river-major-size") * 0.5 + 0.5
	var major_width := lerpf(0.018, 0.052, major_size_noise)
	var major_distance := absf(major_field - major_target)
	var major := 1.0 - _transition_weight(major_distance, major_width * 0.58, major_width * 1.55)
	var major_floodplain := 1.0 - _transition_weight(major_distance, major_width * 1.25, major_width * 4.8)

	var minor_field := _fbm(seed, wx - 1300.0, wz + 2100.0, 1150.0, 4, "river-minor")
	var minor_target := lerpf(-0.22, 0.22, _random01(seed, "river-minor-target"))
	var minor_size_noise := _fbm(seed, wx - 2300.0, wz - 1400.0, 2500.0, 3, "river-minor-size") * 0.5 + 0.5
	var minor_width := lerpf(0.010, 0.027, minor_size_noise)
	var minor_distance := absf(minor_field - minor_target)
	var minor := 1.0 - _transition_weight(minor_distance, minor_width * 0.55, minor_width * 1.60)
	var minor_floodplain := 1.0 - _transition_weight(minor_distance, minor_width * 1.20, minor_width * 4.2)

	var tributary_gate := 0.58 + major_floodplain * 0.42
	minor *= tributary_gate
	minor_floodplain *= tributary_gate
	var result := {
		"major": clampf(major, 0.0, 1.0),
		"minor": clampf(minor, 0.0, 1.0),
		"major_floodplain": clampf(major_floodplain, 0.0, 1.0),
		"minor_floodplain": clampf(minor_floodplain, 0.0, 1.0),
		"major_size": major_size_noise,
		"minor_size": minor_size_noise,
	}
	samples["river"] = result
	return result.duplicate()


func regional_height(seed: int, x: float, z: float) -> float:
	var samples := _regional_samples(seed, x, z)
	if samples.has("height"):
		return samples["height"]
	var macro_warp_x := _fbm(seed, x + 711.0, z - 509.0, 7200.0, 3, "height-regional-warp-x") * 1050.0
	var macro_warp_z := _fbm(seed, x - 381.0, z + 923.0, 7200.0, 3, "height-regional-warp-z") * 1050.0
	var wx := x + macro_warp_x
	var wz := z + macro_warp_z
	var continental := _fbm(seed, wx, wz, 6800.0, 5, "height-regional-continental")
	var rolling := _fbm(seed, wx + 970.0, wz - 430.0, 2350.0, 5, "height-regional-rolling")
	var ridge_field := _ridged_fbm(seed, wx - 1200.0, wz + 620.0, 3200.0, 4, "height-regional-ridges")
	var highland_mask := _transition_weight(continental, -0.05, 0.48)
	var detail := _fbm(seed, x, z, 620.0, 4, "height-regional-detail")
	var micro := _fbm(seed, x + 97.0, z - 181.0, 185.0, 2, "height-regional-micro")
	var rivers := river_profile(seed, x, z)
	var floodplain := maxf(float(rivers["major_floodplain"]), float(rivers["minor_floodplain"]) * 0.58)
	var broad_relief := continental * 58.0 + rolling * 29.0 + (ridge_field - 0.47) * 33.0 * highland_mask
	var fine_relief := (detail * 6.5 + micro * 1.4) * lerpf(1.0, 0.62, floodplain)
	var relief := broad_relief + fine_relief
	relief -= float(rivers["major"]) * lerpf(4.0, 10.0, float(rivers["major_size"]))
	relief -= float(rivers["minor"]) * lerpf(1.2, 3.8, float(rivers["minor_size"]))
	samples["height"] = relief
	return relief


func regional_slope_degrees(seed: int, x: float, z: float, sample_distance: float = 12.0) -> float:
	var samples := _regional_samples(seed, x, z)
	if sample_distance == 12.0 and samples.has("slope"):
		return samples["slope"]
	var left := regional_height(seed, x - sample_distance, z)
	var right := regional_height(seed, x + sample_distance, z)
	var back := regional_height(seed, x, z - sample_distance)
	var front := regional_height(seed, x, z + sample_distance)
	var dx := (right - left) / (sample_distance * 2.0)
	var dz := (front - back) / (sample_distance * 2.0)
	var result := rad_to_deg(atan(sqrt(dx * dx + dz * dz)))
	if sample_distance == 12.0:
		samples["slope"] = result
	return result


func regional_moisture(seed: int, x: float, z: float) -> float:
	var samples := _regional_samples(seed, x, z)
	if samples.has("moisture"):
		return samples["moisture"]
	var broad := _fbm(seed, x + 791.0, z - 433.0, 1600.0, 4, "moisture-regional-broad") * 0.5 + 0.5
	var local := _fbm(seed, x - 233.0, z + 619.0, 540.0, 3, "moisture-regional-local") * 0.5 + 0.5
	var rivers := river_profile(seed, x, z)
	var riparian := maxf(float(rivers["major_floodplain"]), float(rivers["minor_floodplain"]) * 0.72)
	var result := clampf(broad * 0.66 + local * 0.22 + riparian * 0.20, 0.0, 1.0)
	samples["moisture"] = result
	return result


func regional_forest_potential(seed: int, x: float, z: float) -> float:
	var wet := regional_moisture(seed, x, z)
	var slope := regional_slope_degrees(seed, x, z)
	return regional_forest_score(seed, x, z, wet, slope)


func regional_forest_score(seed: int, x: float, z: float, wet: float, slope: float) -> float:
	var broad := _fbm(seed, x - 311.0, z + 907.0, 1250.0, 4, "forest-regional-broad") * 0.5 + 0.5
	var local := _fbm(seed, x + 121.0, z - 277.0, 380.0, 3, "forest-regional-local") * 0.5 + 0.5
	var rivers := river_profile(seed, x, z)
	var riparian := maxf(float(rivers["major_floodplain"]), float(rivers["minor_floodplain"]) * 0.8)
	var slope_bonus := minf(0.12, slope / 130.0)
	var steep_penalty := _transition_weight(slope, 27.0, 42.0) * 0.55
	return clampf(
		broad * 0.50 + local * 0.18 + wet * 0.25 + riparian * 0.17 + slope_bonus - steep_penalty,
		0.0,
		1.0
	)


func regional_ground_cover_potential(seed: int, x: float, z: float) -> float:
	var wet := regional_moisture(seed, x, z)
	var slope := regional_slope_degrees(seed, x, z)
	var forest := regional_forest_score(seed, x, z, wet, slope)
	return _regional_ground_cover_from_samples(seed, x, z, wet, slope, forest)


func _regional_ground_cover_from_samples(
	seed: int,
	x: float,
	z: float,
	wet: float,
	slope: float,
	forest: float
) -> float:
	var patch := _fbm(seed, x + 517.0, z - 733.0, 420.0, 3, "ground-cover-regional") * 0.5 + 0.5
	var moisture_preference := 1.0 - absf(wet - 0.57) * 1.25
	var slope_factor := 1.0 - _transition_weight(slope, 15.0, 30.0)
	var forest_opening := 1.0 - _transition_weight(forest, 0.62, 0.86) * 0.72
	return clampf((0.28 + patch * 0.42 + moisture_preference * 0.30) * slope_factor * forest_opening, 0.0, 1.0)

func regional_biome(seed: int, x: float, z: float) -> String:
	var slope := regional_slope_degrees(seed, x, z)
	var wet := regional_moisture(seed, x, z)
	var forest := regional_forest_score(seed, x, z, wet, slope)
	if slope >= 20.0:
		return "hillside"
	if forest >= 0.62:
		return "forest"
	if wet >= 0.61:
		return "meadow"
	return "grassland"


func regional_terrain_color(seed: int, x: float, z: float) -> Color:
	var elevation := regional_height(seed, x, z)
	var slope := regional_slope_degrees(seed, x, z)
	var wet := regional_moisture(seed, x, z)
	var forest := regional_forest_score(seed, x, z, wet, slope)
	return _regional_terrain_color_from_samples(seed, x, z, elevation, slope, wet, forest)


func _regional_terrain_color_from_samples(
	seed: int,
	x: float,
	z: float,
	elevation: float,
	slope: float,
	wet: float,
	forest: float
) -> Color:
	var rivers := river_profile(seed, x, z)
	var riparian := maxf(float(rivers["major_floodplain"]), float(rivers["minor_floodplain"]) * 0.72)
	var hillside_weight := _transition_weight(slope, 10.0, 25.0)
	var rock_weight := _transition_weight(slope, 24.0, 39.0) * _transition_weight(elevation, 18.0, 95.0)
	var forest_weight := _transition_weight(forest, 0.43, 0.78) * (1.0 - rock_weight * 0.85)
	var meadow_weight := _transition_weight(wet, 0.49, 0.74) * (1.0 - forest_weight)
	var dry_weight := _transition_weight(0.43 - wet, 0.02, 0.30) * (1.0 - forest_weight)
	var riparian_weight := riparian * (1.0 - rock_weight) * 0.58
	var color := REGIONAL_GRASSLAND_COLOR.lerp(REGIONAL_MEADOW_COLOR, meadow_weight)
	color = color.lerp(REGIONAL_DRY_GRASS_COLOR, dry_weight * 0.62)
	color = color.lerp(REGIONAL_FOREST_COLOR, forest_weight)
	color = color.lerp(REGIONAL_RIPARIAN_COLOR, riparian_weight)
	color = color.lerp(REGIONAL_HILLSIDE_COLOR, hillside_weight * 0.58)
	color = color.lerp(REGIONAL_ROCK_COLOR, rock_weight)
	var macro_tint := _lattice_value(seed, x, z, 720.0, "terrain-regional-macro-tint") * 0.028
	var local_tint := _lattice_value(seed, x, z, 170.0, "terrain-regional-local-tint") * 0.016
	var tint := macro_tint + local_tint
	color.r += tint * 0.88
	color.g += tint
	color.b += tint * 0.66
	return Color(clampf(color.r, 0.0, 1.0), clampf(color.g, 0.0, 1.0), clampf(color.b, 0.0, 1.0), 1.0)
