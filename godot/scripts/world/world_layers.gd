extends RefCounted
class_name WorldLayers

const TerrainModel = preload("res://scripts/world/terrain_model.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")

const HASH_MASK := 0xffffffff
const HASH_NORMALIZER := 4294967295.0
const LEGACY_RIVER_CHANNEL_SCALE := 1100.0
const LEGACY_LAKE_FIELD_SCALE := 1900.0
const REGIONAL_LAKE_FIELD_SCALE := 2350.0
const LEGACY_MAX_RIVER_DEPTH := 4.2
const MAX_RIVER_DEPTH := 7.5
const MAX_LAKE_DEPTH := 9.0


static func sample(seed: int, point: Vector2) -> Dictionary:
	return _sample_profile(seed, point, _uses_regional_profile())


static func sample_regional(seed: int, point: Vector2) -> Dictionary:
	return _sample_profile(seed, point, true)


static func _sample_profile(seed: int, point: Vector2, regional: bool) -> Dictionary:
	var x := point.x
	var z := point.y
	var sampled_height := TerrainModel.regional_height(seed, x, z) if regional else TerrainModel.height(seed, x, z)
	var sampled_slope := TerrainModel.regional_slope_degrees(seed, x, z) if regional else TerrainModel.slope_degrees(seed, x, z)
	var sampled_moisture := TerrainModel.regional_moisture(seed, x, z) if regional else TerrainModel.moisture(seed, x, z)
	var sampled_biome := TerrainModel.regional_biome(seed, x, z) if regional else TerrainModel.biome(seed, x, z)
	var sampled_forest_potential := TerrainModel.regional_forest_potential(seed, x, z) if regional else TerrainModel.forest_potential(seed, x, z)
	var water := _regional_water_masks(seed, x, z, sampled_slope) if regional else _legacy_water_masks(seed, x, z, sampled_slope)
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
	var forest_river_penalty := 0.18 if regional else 0.30
	var forest := clampf(
		sampled_forest_potential
		* (0.65 + sampled_moisture * 0.35)
		* (1.0 - minf(sampled_slope / 50.0, 1.0) * 0.45)
		* (1.0 - river_mask * forest_river_penalty),
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


static func sample_route_terrain(seed: int, point: Vector2) -> Dictionary:
	return _sample_route_profile(seed, point, _uses_regional_profile())


static func sample_route_terrain_regional(seed: int, point: Vector2) -> Dictionary:
	return _sample_route_profile(seed, point, true)


static func _sample_route_profile(seed: int, point: Vector2, regional: bool) -> Dictionary:
	var x := point.x
	var z := point.y
	var sampled_slope := TerrainModel.regional_slope_degrees(seed, x, z) if regional else TerrainModel.slope_degrees(seed, x, z)
	var sampled_moisture := TerrainModel.regional_moisture(seed, x, z) if regional else TerrainModel.moisture(seed, x, z)
	var forest := (
		TerrainModel.regional_forest_score(seed, x, z, sampled_moisture, sampled_slope)
		if regional
		else TerrainModel._forest_score(seed, x, z, sampled_moisture, sampled_slope)
	)
	var water := _regional_water_masks(seed, x, z, sampled_slope) if regional else _legacy_water_masks(seed, x, z, sampled_slope)
	return {
		"slope_degrees": sampled_slope,
		"forest_potential": forest,
		"water_depth": water["depth"],
		"water_kind": water["kind"],
	}


static func sample_water(seed: int, point: Vector2) -> Dictionary:
	return _sample_water_profile(seed, point, _uses_regional_profile())


static func sample_water_regional(seed: int, point: Vector2) -> Dictionary:
	return _sample_water_profile(seed, point, true)


static func _sample_water_profile(seed: int, point: Vector2, regional: bool) -> Dictionary:
	var slope := TerrainModel.regional_slope_degrees(seed, point.x, point.y) if regional else TerrainModel.slope_degrees(seed, point.x, point.y)
	var water := _regional_water_masks(seed, point.x, point.y, slope) if regional else _legacy_water_masks(seed, point.x, point.y, slope)
	return {
		"water_depth": water["depth"],
		"water_kind": water["kind"],
		"river_scale": water.get("river_scale", 0.0),
	}


static func _legacy_water_masks(seed: int, x: float, z: float, slope: float) -> Dictionary:
	var warp_x := _fbm(seed, x + 341.0, z - 707.0, 1500.0, 3, "river-warp-x") * 300.0
	var warp_z := _fbm(seed, x - 919.0, z + 503.0, 1500.0, 3, "river-warp-z") * 300.0
	var channel_value := _fbm(seed, x + warp_x, z + warp_z, LEGACY_RIVER_CHANNEL_SCALE, 4, "river-channel")
	var contour_distance := absf(channel_value - 0.06)
	var slope_factor := 1.0 - _smoothstep(24.0, 42.0, slope)
	var river_mask := (1.0 - _smoothstep(0.014, 0.046, contour_distance)) * slope_factor
	var river_depth := maxf(0.0, (river_mask - 0.06) / 0.94) * LEGACY_MAX_RIVER_DEPTH
	var lake_field := _fbm(seed, x + 1783.0, z - 239.0, LEGACY_LAKE_FIELD_SCALE, 3, "lake-basins") * 0.5 + 0.5
	var lake_mask := _smoothstep(0.74, 0.84, lake_field) * (1.0 - _smoothstep(17.0, 34.0, slope))
	var lake_depth := maxf(0.0, (lake_mask - 0.04) / 0.96) * MAX_LAKE_DEPTH
	if lake_depth > 0.0:
		return {"river": river_mask, "lake": lake_mask, "depth": lake_depth, "kind": "lake", "river_scale": river_mask}
	if river_depth > 0.0:
		return {"river": river_mask, "lake": lake_mask, "depth": river_depth, "kind": "river", "river_scale": river_mask}
	return {"river": river_mask, "lake": lake_mask, "depth": 0.0, "kind": "none", "river_scale": river_mask}


static func _regional_water_masks(seed: int, x: float, z: float, slope: float) -> Dictionary:
	var channels := TerrainModel.river_profile(seed, x, z)
	var major := float(channels.get("major", 0.0))
	var minor := float(channels.get("minor", 0.0))
	var major_size := float(channels.get("major_size", 0.5))
	var minor_size := float(channels.get("minor_size", 0.5))
	var slope_factor := 1.0 - _smoothstep(23.0, 39.0, slope)
	major *= slope_factor
	minor *= slope_factor
	var river_mask := maxf(major, minor)
	var major_depth := major * lerpf(3.7, MAX_RIVER_DEPTH, major_size)
	var minor_depth := minor * lerpf(0.75, 2.5, minor_size)
	var river_depth := maxf(major_depth, minor_depth)
	var river_scale := major if major >= minor else minor * 0.45
	var lake_broad := _fbm(seed, x + 1783.0, z - 239.0, REGIONAL_LAKE_FIELD_SCALE, 4, "lake-basins") * 0.5 + 0.5
	var lake_detail := _fbm(seed, x - 491.0, z + 1311.0, 760.0, 3, "lake-detail") * 0.5 + 0.5
	var lake_field := lake_broad * 0.82 + lake_detail * 0.18
	var threshold_shift := (_random01(seed, "lake-threshold", 0, 0) - 0.5) * 0.035
	var lake_mask := _smoothstep(0.735 + threshold_shift, 0.845 + threshold_shift, lake_field)
	lake_mask *= 1.0 - _smoothstep(15.0, 30.0, slope)
	lake_mask = maxf(lake_mask, major * 0.16)
	var lake_depth := clampf(maxf(0.0, (lake_mask - 0.035) / 0.965) * MAX_LAKE_DEPTH, 0.0, MAX_LAKE_DEPTH)
	if lake_depth > river_depth and lake_depth > 0.0:
		return {"river": river_mask, "lake": lake_mask, "depth": lake_depth, "kind": "lake", "river_scale": river_scale}
	if river_depth > 0.0:
		return {"river": river_mask, "lake": lake_mask, "depth": clampf(river_depth, 0.0, MAX_RIVER_DEPTH), "kind": "river", "river_scale": river_scale}
	return {"river": river_mask, "lake": lake_mask, "depth": 0.0, "kind": "none", "river_scale": river_scale}


static func _uses_regional_profile() -> bool:
	return MapDefinition.active_map_id() != MapDefinition.LEGACY_CITY_MAP_ID


static func _deposit_mask(seed: int, x: float, z: float, channel: String, scale: float, threshold: float, full_abundance: float) -> float:
	var broad := _fbm(seed, x + 271.0, z - 419.0, scale, 4, "%s-broad" % channel) * 0.5 + 0.5
	var structure := _fbm(seed, x - 1103.0, z + 683.0, scale * 0.38, 3, "%s-structure" % channel) * 0.5 + 0.5
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


static func _fbm(seed: int, x: float, z: float, base_scale: float, octaves: int, channel: String) -> float:
	var value := 0.0
	var amplitude := 1.0
	var frequency := 1.0
	var amplitude_total := 0.0
	for octave in range(octaves):
		value += _lattice_value(seed, x, z, base_scale / frequency, "%s:%d" % [channel, octave]) * amplitude
		amplitude_total += amplitude
		amplitude *= 0.5
		frequency *= 2.0
	return 0.0 if amplitude_total <= 0.0 else value / amplitude_total


static func _smoothstep(edge_low: float, edge_high: float, value: float) -> float:
	var t := clampf((value - edge_low) / (edge_high - edge_low), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
