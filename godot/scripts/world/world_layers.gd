extends RefCounted
class_name WorldLayers

const TerrainModel = preload("res://scripts/world/terrain_model.gd")

const HASH_MASK := 0xffffffff
const HASH_NORMALIZER := 4294967295.0
const RIVER_CHANNEL_SCALE := 1100.0
const LAKE_FIELD_SCALE := 1900.0


## Samples the existing terrain and the natural world layers at a world-space point.
## The point's x/y coordinates map to the terrain model's x/z coordinates.
static func sample(seed: int, point: Vector2) -> Dictionary:
	var x := point.x
	var z := point.y
	var sampled_height: float = TerrainModel.height(seed, x, z)
	var sampled_slope: float = TerrainModel.slope_degrees(seed, x, z)
	var sampled_moisture: float = TerrainModel.moisture(seed, x, z)
	var sampled_biome: String = TerrainModel.biome(seed, x, z)
	var sampled_forest_potential: float = TerrainModel.forest_potential(seed, x, z)

	var water := _water_masks(seed, x, z, sampled_slope)
	var river_mask: float = water["river"]
	var lake_mask: float = water["lake"]
	var water_depth: float = water["depth"]
	var water_kind: String = water["kind"]
	var soil_noise := _fbm(seed, x + 1243.0, z - 882.0, 480.0, 3, "soil-fertility") * 0.5 + 0.5
	var fertility := clampf(
		0.12
		+ sampled_moisture * 0.48
		+ soil_noise * 0.28
		+ river_mask * 0.18
		- minf(sampled_slope / 45.0, 1.0) * 0.55
		- maxf(sampled_height, 0.0) * 0.001,
		0.0,
		1.0
	)
	var forest := clampf(
		sampled_forest_potential
		* (0.65 + sampled_moisture * 0.35)
		* (1.0 - minf(sampled_slope / 50.0, 1.0) * 0.45)
		* (1.0 - river_mask * 0.3),
		0.0,
		1.0
	)
	var ore := _deposit_mask(seed, x, z, "ore", 2900.0, 0.61, 0.81)
	var oil := _deposit_mask(seed, x, z, "oil", 3600.0, 0.64, 0.83)
	var groundwater_noise := _fbm(seed, x - 560.0, z + 1320.0, 840.0, 3, "groundwater") * 0.5 + 0.5
	var lowland := 1.0 - _smoothstep(-15.0, 75.0, sampled_height)
	var groundwater := clampf(
		sampled_moisture * 0.38
		+ maxf(river_mask, lake_mask) * 0.35
		+ groundwater_noise * 0.17
		+ lowland * 0.10,
		0.0,
		1.0
	)

	return {
		"height": sampled_height,
		"slope_degrees": sampled_slope,
		"moisture": sampled_moisture,
		"biome": sampled_biome,
		"forest_potential": sampled_forest_potential,
		"water_depth": water_depth,
		"water_kind": water_kind,
		"fertility": fertility,
		"forest": forest,
		"ore": ore,
		"oil": oil,
		"groundwater": groundwater,
	}


## Lightweight samples for route costs and the water renderer. Avoids calculating
## resource, soil, and biome data when a caller only needs terrain friction.
static func sample_route_terrain(seed: int, point: Vector2) -> Dictionary:
	var x := point.x
	var z := point.y
	var sampled_slope := TerrainModel.slope_degrees(seed, x, z)
	var sampled_moisture := TerrainModel.moisture(seed, x, z)
	var forest := TerrainModel._forest_score(seed, x, z, sampled_moisture, sampled_slope)
	var water := _water_masks(seed, x, z, sampled_slope)
	return {
		"slope_degrees": sampled_slope,
		"forest_potential": forest,
		"water_depth": water["depth"],
		"water_kind": water["kind"],
	}


static func sample_water(seed: int, point: Vector2) -> Dictionary:
	var slope := TerrainModel.slope_degrees(seed, point.x, point.y)
	var water := _water_masks(seed, point.x, point.y, slope)
	return {"water_depth": water["depth"], "water_kind": water["kind"]}


static func _water_masks(seed: int, x: float, z: float, slope: float) -> Dictionary:
	# A warped, smooth contour makes connected river reaches instead of independent
	# per-cell patches. The fixed octave count keeps each point query bounded.
	var warp_x := _fbm(seed, x + 341.0, z - 707.0, 1500.0, 3, "river-warp-x") * 300.0
	var warp_z := _fbm(seed, x - 919.0, z + 503.0, 1500.0, 3, "river-warp-z") * 300.0
	var channel_value := _fbm(
		seed,
		x + warp_x,
		z + warp_z,
		RIVER_CHANNEL_SCALE,
		4,
		"river-channel"
	)
	var contour_distance := absf(channel_value - 0.06)
	var slope_factor := 1.0 - _smoothstep(24.0, 42.0, slope)
	var river_mask := (1.0 - _smoothstep(0.014, 0.046, contour_distance)) * slope_factor
	var river_depth := maxf(0.0, (river_mask - 0.06) / 0.94) * 4.2

	# Broad basins form contiguous lakes; slope suppresses water on steep ground.
	var lake_field := _fbm(
		seed,
		x + 1783.0,
		z - 239.0,
		LAKE_FIELD_SCALE,
		3,
		"lake-basins"
	) * 0.5 + 0.5
	var lake_mask := _smoothstep(0.74, 0.84, lake_field) * (1.0 - _smoothstep(17.0, 34.0, slope))
	var lake_depth := maxf(0.0, (lake_mask - 0.04) / 0.96) * 9.0

	if lake_depth > 0.0:
		return {"river": river_mask, "lake": lake_mask, "depth": lake_depth, "kind": "lake"}
	if river_depth > 0.0:
		return {"river": river_mask, "lake": lake_mask, "depth": river_depth, "kind": "river"}
	return {"river": river_mask, "lake": lake_mask, "depth": 0.0, "kind": "none"}


static func _deposit_mask(
	seed: int,
	x: float,
	z: float,
	channel: String,
	scale: float,
	threshold: float,
	full_abundance: float
) -> float:
	var broad := _fbm(seed, x + 271.0, z - 419.0, scale, 4, "%s-broad" % channel) * 0.5 + 0.5
	var structure := _fbm(
		seed,
		x - 1103.0,
		z + 683.0,
		scale * 0.38,
		3,
		"%s-structure" % channel
	) * 0.5 + 0.5
	return _smoothstep(threshold, full_abundance, broad * 0.72 + structure * 0.28)


static func _hash32(text: String) -> int:
	var hash_value: int = 2166136261
	for index in range(text.length()):
		hash_value = (hash_value ^ text.unicode_at(index)) & HASH_MASK
		hash_value = (hash_value * 16777619) & HASH_MASK
	return hash_value


static func _lattice_value(seed: int, x: float, z: float, scale: float, channel: String) -> float:
	var grid_x := floori(x / scale)
	var grid_z := floori(z / scale)
	var fraction_x := _smoothstep(0.0, 1.0, x / scale - float(grid_x))
	var fraction_z := _smoothstep(0.0, 1.0, z / scale - float(grid_z))
	var value_00 := _random01(seed, channel, grid_x, grid_z) * 2.0 - 1.0
	var value_10 := _random01(seed, channel, grid_x + 1, grid_z) * 2.0 - 1.0
	var value_01 := _random01(seed, channel, grid_x, grid_z + 1) * 2.0 - 1.0
	var value_11 := _random01(seed, channel, grid_x + 1, grid_z + 1) * 2.0 - 1.0
	var upper := lerpf(value_00, value_10, fraction_x)
	var lower := lerpf(value_01, value_11, fraction_x)
	return lerpf(upper, lower, fraction_z)


static func _random01(seed: int, channel: String, grid_x: int, grid_z: int) -> float:
	var key := "%d:%s:%d:%d" % [seed, channel, grid_x, grid_z]
	return float(_hash32(key)) / HASH_NORMALIZER


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


static func _smoothstep(edge_low: float, edge_high: float, value: float) -> float:
	var t := clampf((value - edge_low) / (edge_high - edge_low), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
