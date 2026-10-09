extends RefCounted

# Keep the mature simulation/runtime implementation intact and apply the new
# starter-world materialization contract at the boundary. This avoids coupling
# regional world-generation tuning to the legacy Bus Era lifecycle code.
const CoreRuntime = preload("res://scripts/city/city_runtime_core.gd")
const RegionalGrowth = preload("res://scripts/city/regional_growth_system.gd")
const RegionalHighwayPlanner = preload("res://scripts/city/regional_highway_planner.gd")
const Data = preload("res://scripts/core/game_data.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")

const CITY_VERSION := 1
const MAX_ACTIVE_PROJECTS := 2
const STEP_SECONDS := 0.2
# Legacy constants remain public for compatibility with old tools/tests, but
# the realistic regional profile is advanced by RegionalGrowthSystem only.
const REGIONAL_GROWTH_INTERVAL_SECONDS := 180.0
const REGIONAL_ORGANIC_GROWTH_INTERVAL_SECONDS := 300.0
const MAX_REGIONAL_AUTONOMOUS_BUILDINGS := 36
const REGIONAL_STARTER_SERVICE_CAPACITY_SHARE := 0.72
const REGIONAL_TRANSIT_ACCESS_PRIORITY_WEIGHT := 20.0
const REGIONAL_HEALTH_ATTRACTIVENESS_WEIGHT := 0.08
# Retained for compatibility with older tests/tools. The realistic starter
# profile no longer limits the world to a two-road / three-building core.
const REGIONAL_CORE_LOCAL_ROAD_COUNT := 2
const REGIONAL_CORE_BUILDING_COUNT := 3
const REGIONAL_RESIDENTS_PER_DENSITY := 8
const REGIONAL_JOBS_PER_DENSITY := 5
const REGIONAL_MIXED_RESIDENTS_PER_DENSITY := 4
const REGIONAL_MIXED_JOBS_PER_DENSITY := 3

const PEOPLE_PER_STARTER_VISUAL_BUILDING := 12.0
const MAX_STARTER_VISUAL_BUILDINGS_PER_SETTLEMENT := 420
const STARTER_PROFILE := "realistic-existing-settlements-v2"


static func create_initial_city(
	seed: int = Data.DEFAULT_CITY_SEED,
	map_id: String = MapDefinition.LEGACY_CITY_MAP_ID
) -> Dictionary:
	var city: Dictionary = CoreRuntime.create_initial_city(seed, map_id)
	if map_id != MapDefinition.LEGACY_CITY_MAP_ID:
		_materialize_existing_region(city)
		RegionalGrowth.ensure(city)
		_clear_legacy_corridor_upgrade_hints(city)
		RegionalHighwayPlanner.ensure(city)
	return city


static func ensure_city(store: Node) -> void:
	CoreRuntime.ensure_city(store)
	if _is_regional_city(store.city) and str(store.city.get("starter_profile", "")) != STARTER_PROFILE:
		_materialize_existing_region(store.city)
	# Organic initialization scans settlement morphology and is intentionally
	# not repeated from the per-frame simulation hot path.
	if _is_regional_city(store.city) and not store.city.has("organic_growth"):
		RegionalGrowth.ensure(store.city)
	if _is_regional_city(store.city):
		_clear_legacy_corridor_upgrade_hints(store.city)
	if _is_regional_city(store.city) and not store.city.has("highway_planning"):
		RegionalHighwayPlanner.ensure(store.city)


static func sync_with_transport(store: Node) -> bool:
	ensure_city(store)
	return CoreRuntime.sync_with_transport(store)


static func advance(store: Node, delta_seconds: float) -> bool:
	ensure_city(store)
	var regional := _is_regional_city(store.city)
	# CityRuntimeCore still contains the first-generation regional auto-growth
	# implementation for save/tool compatibility. Freeze only that accumulator
	# while Core advances projects/services, then restore it unchanged. This
	# prevents two independent systems from developing the same parcels.
	var legacy_growth_state: Dictionary = {}
	if regional and store.city.has("organic_growth"):
		legacy_growth_state = _suspend_legacy_regional_growth(store.city)
	var changed := CoreRuntime.advance(store, delta_seconds)
	if not legacy_growth_state.is_empty():
		_restore_legacy_regional_growth(store.city, legacy_growth_state)
	if regional:
		changed = _advance_regional_growth(store, delta_seconds) or changed
		# RegionalGrowth still carries an old compatibility pressure calculator.
		# Never expose its in-place road-upgrade hints to gameplay: all motorway,
		# expressway and bypass demand belongs to RegionalHighwayPlanner, which
		# creates a separate outer alignment and preserves the historic road.
		_clear_legacy_corridor_upgrade_hints(store.city)
		changed = RegionalHighwayPlanner.advance(store, delta_seconds) or changed
	return changed


static func _suspend_legacy_regional_growth(city: Dictionary) -> Dictionary:
	var state := {
		"had_accumulator": city.has("regional_growth_accumulator_seconds"),
		"accumulator": city.get("regional_growth_accumulator_seconds", 0.0),
		"had_count": city.has("regional_auto_growth_count"),
		"count": city.get("regional_auto_growth_count", 0),
	}
	city["regional_growth_accumulator_seconds"] = 0.0
	city["regional_auto_growth_count"] = MAX_REGIONAL_AUTONOMOUS_BUILDINGS
	return state


static func _restore_legacy_regional_growth(city: Dictionary, state: Dictionary) -> void:
	if bool(state.get("had_accumulator", false)):
		city["regional_growth_accumulator_seconds"] = float(state.get("accumulator", 0.0))
	else:
		city.erase("regional_growth_accumulator_seconds")
	if bool(state.get("had_count", false)):
		city["regional_auto_growth_count"] = int(state.get("count", 0))
	else:
		city.erase("regional_auto_growth_count")


static func _advance_regional_growth(store: Node, delta_seconds: float) -> bool:
	# Strategic intercity roads use settlement IDs as semantic graph endpoints.
	# They must still contribute accessibility, but must not be mistaken for a
	# local urban frontier from which a residential side street should sprout.
	var restored_settlement_ids: Array = []
	for road_value in store.city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("source", "")) != "regional-existing":
			continue
		if str(road.get("regionalRole", "")) not in ["spine", "loop", "external_branch", "city_connector"]:
			continue
		restored_settlement_ids.append([road, road.get("settlementId", null)])
		road["settlementId"] = ""
	var changed := RegionalGrowth.advance(store, delta_seconds)
	for restored_value in restored_settlement_ids:
		var restored: Array = restored_value
		var road: Dictionary = restored[0]
		var previous: Variant = restored[1]
		if previous == null:
			road.erase("settlementId")
		else:
			road["settlementId"] = previous
	return changed


static func _clear_legacy_corridor_upgrade_hints(city: Dictionary) -> void:
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("regionalRole", "")) not in ["spine", "loop", "external_branch", "city_connector"]:
			continue
		road.erase("upgradePressure")
		road.erase("upgradeRecommendation")
		road["preserveExistingRoad"] = true


static func _materialize_existing_region(city: Dictionary) -> void:
	if not _is_regional_city(city):
		return

	# Every generated settlement represents a place that existed before the
	# player arrived. Its historic local streets and the sparse regional road
	# network are therefore physical roads at t=0, not construction previews.
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("source", "")) != "regional-existing":
			continue
		road["status"] = "built"
		road["constructionProgress"] = 1.0

	var population_by_district: Dictionary = {}
	for settlement_value in city.get("regional_settlements", []):
		var settlement: Dictionary = settlement_value
		population_by_district[str(settlement.get("id", ""))] = maxi(0, int(settlement.get("population", 0)))

	var parcel_groups: Dictionary = {}
	for parcel_value in city.get("parcels", []):
		var parcel: Dictionary = parcel_value
		var district_id := str(parcel.get("districtId", ""))
		if not parcel_groups.has(district_id):
			parcel_groups[district_id] = []
		parcel_groups[district_id].append(parcel)

	var initial_buildings: Array[Dictionary] = []
	var built_by_district: Dictionary = {}
	for district_id_value in parcel_groups.keys():
		var district_id := str(district_id_value)
		var district_parcels: Array = parcel_groups[district_id]
		district_parcels.sort_custom(func(a, b):
			var a_order := float(a.get("developmentOrder", 0.0))
			var b_order := float(b.get("developmentOrder", 0.0))
			if not is_equal_approx(a_order, b_order):
				return a_order < b_order
			return str(a.get("id", "")) < str(b.get("id", ""))
		)
		var population := int(population_by_district.get(district_id, 0))
		var target_existing := clampi(
			roundi(float(population) / PEOPLE_PER_STARTER_VISUAL_BUILDING),
			mini(20, district_parcels.size()),
			mini(MAX_STARTER_VISUAL_BUILDINGS_PER_SETTLEMENT, district_parcels.size())
		)
		var built_count := 0
		for parcel_index in range(district_parcels.size()):
			var parcel: Dictionary = district_parcels[parcel_index]
			# Roughly every sixth lot remains undeveloped. Because the generator
			# creates about 20% reserve capacity this yields the requested initial
			# building count while scattering future growth through the town.
			var reserve_slot := (parcel_index + 1) % 6 == 0
			var should_exist := not reserve_slot and built_count < target_existing
			if should_exist:
				var building := _existing_building_for_parcel(city, parcel)
				parcel["source"] = "regional-existing"
				parcel["status"] = "built"
				parcel["reservedAt"] = null
				parcel["buildingId"] = building["id"]
				initial_buildings.append(building)
				built_count += 1
			else:
				parcel["source"] = "regional-capacity"
				parcel["status"] = "vacant"
				parcel["reservedAt"] = null
				parcel["buildingId"] = ""
		built_by_district[district_id] = built_count

	city["buildings"] = initial_buildings
	for district_value in city.get("districts", []):
		var district: Dictionary = district_value
		var district_id := str(district.get("id", ""))
		if not parcel_groups.has(district_id):
			continue
		var parcel_count := (parcel_groups[district_id] as Array).size()
		var built_count := int(built_by_district.get(district_id, 0))
		district["developmentLevel"] = float(built_count) / float(maxi(1, parcel_count))

	var stats: Dictionary = city.get("regional_plan_stats", {}).duplicate(true)
	stats["starter_built_building_count"] = initial_buildings.size()
	stats["starter_built_road_count"] = _count_built_regional_roads(city)
	city["regional_plan_stats"] = stats
	city["starter_profile"] = STARTER_PROFILE


static func _existing_building_for_parcel(city: Dictionary, parcel: Dictionary) -> Dictionary:
	var parcel_id := str(parcel.get("id", ""))
	var building_id := "building-%s" % parcel_id
	var kind := str(parcel.get("candidateBuildingType", "house"))
	if kind.is_empty():
		kind = "house"
	var floors := 1
	var height := 7.2
	if kind == "shop":
		floors = 2
		height = 7.8
	elif kind == "townhouse":
		floors = 2
		height = 9.0
	elif kind == "apartment":
		floors = 3
		height = 11.3
	return {
		"id": building_id,
		"districtId": str(parcel.get("districtId", "")),
		"parcelId": parcel_id,
		"x": float(parcel.get("x", 0.0)),
		"y": float(parcel.get("y", 0.0)),
		"zone": str(parcel.get("zone", "residential")),
		"profile": {
			"kind": kind,
			"floors": floors,
			"density": 1,
			"heightMeters": height,
		},
		"rotationRadians": CoreRuntime._parcel_frontage_angle(city, parcel),
		"source": "regional-existing",
		"status": "built",
		"constructionProgress": 1.0,
	}


static func _count_built_regional_roads(city: Dictionary) -> int:
	var count := 0
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("source", "")) == "regional-existing" and str(road.get("status", "")) == "built":
			count += 1
	return count


static func _is_regional_city(city: Dictionary) -> bool:
	return str(city.get("world_map_id", MapDefinition.LEGACY_CITY_MAP_ID)) != MapDefinition.LEGACY_CITY_MAP_ID


# Public helpers used by GameStore and regression tests remain available from
# the facade while the simulation implementation stays in CityRuntimeCore.
static func _service_demand_ratio(service_type: String) -> float:
	return CoreRuntime._service_demand_ratio(service_type)


static func _refresh_regional_demographics(city: Dictionary) -> void:
	CoreRuntime._refresh_regional_demographics(city)


static func _regional_parcel_has_strategic_access(city: Dictionary, parcel: Dictionary) -> bool:
	return CoreRuntime._regional_parcel_has_strategic_access(city, parcel)


static func _next_regional_growth_candidate(store: Node) -> Dictionary:
	return CoreRuntime._next_regional_growth_candidate(store)


static func _regional_growth_contribution(parcel: Dictionary, profile: Dictionary) -> Dictionary:
	return CoreRuntime._regional_growth_contribution(parcel, profile)
