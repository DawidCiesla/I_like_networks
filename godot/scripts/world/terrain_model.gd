extends RefCounted
class_name TerrainModel

const TAU := PI * 2.0
const GRASSLAND_COLOR := Color(0.235, 0.355, 0.155)
const MEADOW_COLOR := Color(0.31, 0.455, 0.20)
const FOREST_COLOR := Color(0.105, 0.225, 0.095)
const HILLSIDE_COLOR := Color(0.31, 0.305, 0.245)
const ROCK_COLOR := Color(0.39, 0.385, 0.35)
const RIPARIAN_COLOR := Color(0.17, 0.35, 0.145)
const DRY_GRASS_COLOR := Color(0.355, 0.365, 0.19)
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


static func _ridged_fbm(
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


static func _seed_phase(seed: int, channel: String) -> float:
	return _random01(seed, "phase:%s" % channel) * TAU


## Deterministic drainage skeleton shared by terrain carving, moisture and water.
## It deliberately exposes broad floodplain masks in addition to narrow channel
## masks, so rivers influence the landscape before any water mesh is rendered.
static func river_profile(seed: int, x: float, z: float) -> Dictionary:
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

	# Tributaries become less dominant far from broader wet corridors. This keeps
	# the region readable while still yielding different river sizes.
	var tributary_gate := 0.58 + major_floodplain * 0.42
	minor *= tributary_gate
	minor_floodplain *= tributary_gate

	return {
		"major": clampf(major, 0.0, 1.0),
		"minor": clampf(minor, 0.0, 1.0),
		"major_floodplain": clampf(major_floodplain, 0.0, 1.0),
		"minor_floodplain": clampf(minor_floodplain, 0.0, 1.0),
		"major_size": major_size_noise,
		"minor_size": minor_size_noise,
	}


static func height(seed: int, x: float, z: float) -> float:
	# Domain warp breaks up the obvious grid/fBm look and creates broad landscape
	# regions before smaller hills are layered on top.
	var macro_warp_x := _fbm(seed, x + 711.0, z - 509.0, 7200.0, 3, "height-warp-x") * 1050.0
	var macro_warp_z := _fbm(seed, x - 381.0, z + 923.0, 7200.0, 3, "height-warp-z") * 1050.0
	var wx := x + macro_warp_x
	var wz := z + macro_warp_z

	var continental := _fbm(seed, wx, wz, 6800.0, 5, "height-continental")
	var rolling := _fbm(seed, wx + 970.0, wz - 430.0, 2350.0, 5, "height-rolling")
	var ridge_field := _ridged_fbm(seed, wx - 1200.0, wz + 620.0, 3200.0, 4, "height-ridges")
	var highland_mask := _transition_weight(continental, -0.05, 0.48)
	var detail := _fbm(seed, x, z, 620.0, 4, "height-detail")
	var micro := _fbm(seed, x + 97.0, z - 181.0, 185.0, 2, "height-micro")

	var relief := continental * 58.0
	relief += rolling * 29.0
	relief += (ridge_field - 0.47) * 33.0 * highland_mask
	relief += detail * 6.5
	relief += micro * 1.4

	var rivers := river_profile(seed, x, z)
	var major := float(rivers["major"])
	var minor := float(rivers["minor"])
	var floodplain := maxf(float(rivers["major_floodplain"]), float(rivers["minor_floodplain"]) * 0.58)
	# Broad valleys are gently flattened and the actual channel is carved below
	# them. This gives roads/settlements realistic lowland corridors to follow.
	var valley_detail_damping := lerpf(1.0, 0.62, floodplain)
	var broad_relief := continental * 58.0 + rolling * 29.0 + (ridge_field - 0.47) * 33.0 * highland_mask
	var fine_relief := detail * 6.5 + micro * 1.4
	relief = broad_relief + fine_relief * valley_detail_damping
	relief -= major * lerpf(4.0, 10.0, float(rivers["major_size"]))
	relief -= minor * lerpf(1.2, 3.8, float(rivers["minor_size"]))
	return relief


static func slope_degrees(seed: int, x: float, z: float, sample_distance: float = 12.0) -> float:
	var left := height(seed, x - sample_distance, z)
	var right := height(seed, x + sample_distance, z)
	var back := height(seed, x, z - sample_distance)
	var front := height(seed, x, z + sample_distance)
	var dx := (right - left) / (sample_distance * 2.0)
	var dz := (front - back) / (sample_distance * 2.0)
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))


static func moisture(seed: int, x: float, z: float) -> float:
	var broad := _fbm(seed, x + 791.0, z - 433.0, 1600.0, 4, "moisture-broad") * 0.5 + 0.5
	var local := _fbm(seed, x - 233.0, z + 619.0, 540.0, 3, "moisture-local") * 0.5 + 0.5
	var rivers := river_profile(seed, x, z)
	var riparian := maxf(float(rivers["major_floodplain"]), float(rivers["minor_floodplain"]) * 0.72)
	return clampf(broad * 0.66 + local * 0.22 + riparian * 0.20, 0.0, 1.0)


static func forest_potential(seed: int, x: float, z: float) -> float:
	var wet := moisture(seed, x, z)
	var slope := slope_degrees(seed, x, z)
	return _forest_score(seed, x, z, wet, slope)


static func _forest_score(seed: int, x: float, z: float, wet: float, slope: float) -> float:
	var broad := _fbm(seed, x - 311.0, z + 907.0, 1250.0, 4, "forest-broad") * 0.5 + 0.5
	var local := _fbm(seed, x + 121.0, z - 277.0, 380.0, 3, "forest-local") * 0.5 + 0.5
	var rivers := river_profile(seed, x, z)
	var riparian := maxf(float(rivers["major_floodplain"]), float(rivers["minor_floodplain"]) * 0.8)
	var slope_bonus := minf(0.12, slope / 130.0)
	var steep_penalty := _transition_weight(slope, 27.0, 42.0) * 0.55
	return clampf(
		broad * 0.50
		+ local * 0.18
		+ wet * 0.25
		+ riparian * 0.17
		+ slope_bonus
		- steep_penalty,
		0.0,
		1.0
	)


static func ground_cover_potential(seed: int, x: float, z: float) -> float:
	var wet := moisture(seed, x, z)
	var slope := slope_degrees(seed, x, z)
	var forest := _forest_score(seed, x, z, wet, slope)
	var patch := _fbm(seed, x + 517.0, z - 733.0, 420.0, 3, "ground-cover") * 0.5 + 0.5
	var moisture_preference := 1.0 - absf(wet - 0.57) * 1.25
	var slope_factor := 1.0 - _transition_weight(slope, 15.0, 30.0)
	var forest_opening := 1.0 - _transition_weight(forest, 0.62, 0.86) * 0.72
	return clampf((0.28 + patch * 0.42 + moisture_preference * 0.30) * slope_factor * forest_opening, 0.0, 1.0)


static func biome(seed: int, x: float, z: float) -> String:
	var slope := slope_degrees(seed, x, z)
	var wet := moisture(seed, x, z)
	var forest := _forest_score(seed, x, z, wet, slope)

	if slope >= 20.0:
		return "hillside"
	if forest >= 0.62:
		return "forest"
	if wet >= 0.61:
		return "meadow"
	return "grassland"


static func terrain_color(seed: int, x: float, z: float) -> Color:
	var elevation := height(seed, x, z)
	var slope := slope_degrees(seed, x, z)
	var wet := moisture(seed, x, z)
	var forest := _forest_score(seed, x, z, wet, slope)
	var rivers := river_profile(seed, x, z)
	var riparian := maxf(float(rivers["major_floodplain"]), float(rivers["minor_floodplain"]) * 0.72)

	var hillside_weight := _transition_weight(slope, 10.0, 25.0)
	var rock_weight := _transition_weight(slope, 24.0, 39.0) * _transition_weight(elevation, 18.0, 95.0)
	var forest_weight := _transition_weight(forest, 0.43, 0.78) * (1.0 - rock_weight * 0.85)
	var meadow_weight := _transition_weight(wet, 0.49, 0.74) * (1.0 - forest_weight)
	var dry_weight := _transition_weight(0.43 - wet, 0.02, 0.30) * (1.0 - forest_weight)
	var riparian_weight := riparian * (1.0 - rock_weight) * 0.58

	var color := GRASSLAND_COLOR.lerp(MEADOW_COLOR, meadow_weight)
	color = color.lerp(DRY_GRASS_COLOR, dry_weight * 0.62)
	color = color.lerp(FOREST_COLOR, forest_weight)
	color = color.lerp(RIPARIAN_COLOR, riparian_weight)
	color = color.lerp(HILLSIDE_COLOR, hillside_weight * 0.58)
	color = color.lerp(ROCK_COLOR, rock_weight)

	var macro_tint := _lattice_value(seed, x, z, 720.0, "terrain-macro-tint") * 0.028
	var local_tint := _lattice_value(seed, x, z, 170.0, "terrain-local-tint") * 0.016
	var tint := macro_tint + local_tint
	color.r += tint * 0.88
	color.g += tint
	color.b += tint * 0.66
	return Color(clampf(color.r, 0.0, 1.0), clampf(color.g, 0.0, 1.0), clampf(color.b, 0.0, 1.0), 1.0)
