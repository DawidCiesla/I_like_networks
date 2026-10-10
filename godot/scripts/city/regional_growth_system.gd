extends RefCounted
class_name RegionalGrowthSystem

const CoreRuntime = preload("res://scripts/city/city_runtime_core.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const WorldLayers = preload("res://scripts/world/world_layers.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")
const RoadTopology = preload("res://scripts/city/road_topology.gd")
const RoadProfile = preload("res://scripts/city/road_profile.gd")
const RegionalAccessibility = preload("res://scripts/city/regional_accessibility.gd")

const TICK_SECONDS := 300.0
const MAX_ACTIONS_PER_SETTLEMENT_TICK := 3
const BASE_GROWTH_CREDIT := 0.07
const TRANSIT_GROWTH_WEIGHT := 0.72
const PLAYER_LINK_GROWTH_WEIGHT := 0.30
const HISTORIC_LINK_GROWTH_WEIGHT := 0.025
const REAL_ACCESSIBILITY_BLEND := 0.55
const REAL_ACCESSIBILITY_GROWTH_WEIGHT := 0.72
const REAL_PLAYER_LINK_WEIGHT := 0.12
const REAL_HISTORIC_LINK_WEIGHT := 0.015
const MAX_GROWTH_CREDIT_PER_TICK := 2.4
const EXPANSION_PRESSURE_THRESHOLD := 0.58
const RESERVE_RATIO_TRIGGER := 0.19
const MAX_EXPANSIONS_PER_SETTLEMENT := 64
const PARCELS_PER_EXPANSION := 14
const URBAN_CLUSTER_GAP_METERS := 320.0
const MAX_GROWTH_TICKS_PER_ADVANCE := 8
const TERRAIN_MAX_SLOPE_DEGREES := 19.0
const BOUNDS_MARGIN_METERS := 220.0


static func ensure(city: Dictionary) -> void:
	if not _is_regional_city(city):
		return
	if not city.has("organic_growth") or typeof(city.get("organic_growth")) != TYPE_DICTIONARY:
		city["organic_growth"] = {}
	var state: Dictionary = city["organic_growth"]
	if not state.has("accumulator_seconds"):
		state["accumulator_seconds"] = 0.0
	if not state.has("tick"):
		state["tick"] = 0
	if not state.has("settlements"):
		state["settlements"] = {}
	var settlements_state: Dictionary = state["settlements"]
	for settlement_value in city.get("regional_settlements", []):
		var settlement: Dictionary = settlement_value
		var settlement_id := str(settlement.get("id", ""))
		if settlement_id.is_empty():
			continue
		if not settlements_state.has(settlement_id):
			settlements_state[settlement_id] = {
				"growth_credit": 0.0,
				"development_serial": 0,
				"expansion_serial": 0,
				"densification_serial": 0,
				"last_pressure": 0.0,
			}
		_update_settlement_form(city, settlement)
	state["settlements"] = settlements_state
	city["organic_growth"] = state
	_update_urban_clusters(city)
	_update_corridor_pressure(city)


static func advance(store: Node, delta_seconds: float) -> bool:
	if delta_seconds <= 0.0 or not _is_regional_city(store.city):
		return false
	ensure(store.city)
	var organic: Dictionary = store.city["organic_growth"]
	var accumulator := float(organic.get("accumulator_seconds", 0.0)) + delta_seconds
	var tick := int(organic.get("tick", 0))
	var changed := false
	var guard := 0
	while accumulator >= TICK_SECONDS and guard < MAX_GROWTH_TICKS_PER_ADVANCE:
		guard += 1
		accumulator -= TICK_SECONDS
		tick += 1
		changed = _growth_tick(store, tick) or changed
	organic["accumulator_seconds"] = accumulator
	organic["tick"] = tick
	store.city["organic_growth"] = organic
	return changed


static func _growth_tick(store: Node, tick: int) -> bool:
	var city: Dictionary = store.city
	var organic: Dictionary = city["organic_growth"]
	var settlements_state: Dictionary = organic.get("settlements", {})
	var changed := false
	for settlement_value in city.get("regional_settlements", []):
		var settlement: Dictionary = settlement_value
		var settlement_id := str(settlement.get("id", ""))
		if settlement_id.is_empty():
			continue
		var local_state: Dictionary = settlements_state.get(settlement_id, {}).duplicate(true)
		var pressure_components := _growth_pressure_components(store, settlement)
		var pressure := float(pressure_components.get("pressure", 0.0))
		var credit := float(local_state.get("growth_credit", 0.0)) + pressure
		local_state["last_pressure"] = pressure
		settlement["growthPressure"] = pressure
		settlement["transitAccessibility"] = _settlement_transit_accessibility(store, settlement)
		settlement["growthMobilitySource"] = str(pressure_components.get("source", "legacy_proxy"))
		settlement["growthMobilityPressure"] = float(pressure_components.get("mobility_pressure", 0.0))
		settlement["growthLegacyMobilityPressure"] = float(pressure_components.get("legacy_mobility_pressure", 0.0))
		settlement["growthRealMobilityPressure"] = float(pressure_components.get("real_mobility_pressure", 0.0))
		settlement["growthAccessibilityScore"] = float(pressure_components.get("accessibility_score", 0.0))
		var actions := 0
		while credit >= 1.0 and actions < MAX_ACTIONS_PER_SETTLEMENT_TICK:
			if not _perform_growth_action(store, settlement, local_state, pressure, tick):
				break
			credit -= 1.0
			actions += 1
			changed = true
		local_state["growth_credit"] = minf(credit, 4.0)
		settlements_state[settlement_id] = local_state
		_update_settlement_form(city, settlement)
	organic["settlements"] = settlements_state
	city["organic_growth"] = organic
	if changed:
		CoreRuntime._refresh_regional_demographics(city)
		_recompile_road_graph(city)
	_update_urban_clusters(city)
	_update_corridor_pressure(city)
	return changed


static func _perform_growth_action(
	store: Node,
	settlement: Dictionary,
	local_state: Dictionary,
	pressure: float,
	tick: int
) -> bool:
	var city: Dictionary = store.city
	var settlement_id := str(settlement.get("id", ""))
	var parcel_stats := _parcel_stats(city, settlement_id)
	var total := int(parcel_stats.get("total", 0))
	var vacant := int(parcel_stats.get("vacant", 0))
	var reserve_ratio := float(vacant) / float(maxi(1, total))
	var expansion_serial := int(local_state.get("expansion_serial", 0))
	var stage := _stage_for_population(int(settlement.get("population", 0)))
	var development_serial := int(local_state.get("development_serial", 0))

	# Once the historical reserve starts filling, a well-connected settlement
	# extends its street network instead of squeezing unlimited population into
	# the original footprint.
	if (
		pressure >= EXPANSION_PRESSURE_THRESHOLD
		and reserve_ratio <= RESERVE_RATIO_TRIGGER
		and expansion_serial < MAX_EXPANSIONS_PER_SETTLEMENT
	):
		if _expand_settlement(store, settlement, local_state, tick):
			return true

	# Mature settlements sometimes replace low-density fabric near the centre.
	# This is intentionally secondary to outward growth for villages/towns.
	if (
		stage in ["town", "city", "metropolis"]
		and pressure >= 0.92
		and development_serial > 0
		and development_serial % 5 == 0
	):
		if _densify_settlement(store, settlement, local_state, tick):
			return true

	var parcel := _best_vacant_parcel(store, settlement)
	if not parcel.is_empty():
		return _develop_parcel(store, settlement, parcel, local_state, pressure, tick)

	if pressure >= EXPANSION_PRESSURE_THRESHOLD and expansion_serial < MAX_EXPANSIONS_PER_SETTLEMENT:
		if _expand_settlement(store, settlement, local_state, tick):
			return true
	return false


static func _growth_pressure(store: Node, settlement: Dictionary) -> float:
	return float(_growth_pressure_components(store, settlement).get("pressure", 0.0))


static func _growth_pressure_components(store: Node, settlement: Dictionary) -> Dictionary:
	var transit := _settlement_transit_accessibility(store, settlement)
	var player_links := _count_player_links(store.city, settlement)
	var historic_links := _count_historic_strategic_links(store.city, settlement)
	var legacy_mobility := (
		transit * TRANSIT_GROWTH_WEIGHT
		+ float(mini(player_links, 4)) * PLAYER_LINK_GROWTH_WEIGHT
		+ float(mini(historic_links, 4)) * HISTORIC_LINK_GROWTH_WEIGHT
	)
	var mobility_pressure := legacy_mobility
	var real_mobility := legacy_mobility
	var accessibility_score := 0.0
	var source := "legacy_proxy"
	var settlement_id := str(settlement.get("id", ""))
	var accessibility := RegionalAccessibility.snapshot_row(store.city, settlement_id)
	if bool(accessibility.get("available", false)):
		accessibility_score = clampf(float(accessibility.get("score", 0.0)), 0.0, 1.0)
		real_mobility = (
			accessibility_score * REAL_ACCESSIBILITY_GROWTH_WEIGHT
			+ float(mini(player_links, 4)) * REAL_PLAYER_LINK_WEIGHT
			+ float(mini(historic_links, 4)) * REAL_HISTORIC_LINK_WEIGHT
		)
		mobility_pressure = lerpf(legacy_mobility, real_mobility, REAL_ACCESSIBILITY_BLEND)
		source = "blended_real_accessibility"
	var population := float(settlement.get("population", 0.0))
	var hub_bonus := clampf(population / 50000.0, 0.0, 0.10)
	var pressure := clampf(
		BASE_GROWTH_CREDIT + mobility_pressure + hub_bonus,
		0.0,
		MAX_GROWTH_CREDIT_PER_TICK
	)
	return {
		"pressure": pressure,
		"source": source,
		"accessibility_score": accessibility_score,
		"mobility_pressure": mobility_pressure,
		"legacy_mobility_pressure": legacy_mobility,
		"real_mobility_pressure": real_mobility,
		"transit_proximity_score": transit,
		"player_links": player_links,
		"historic_links": historic_links,
		"hub_bonus": hub_bonus,
	}


static func _settlement_transit_accessibility(store: Node, settlement: Dictionary) -> float:
	if typeof(store.transit_network) != TYPE_DICTIONARY:
		return 0.0
	var network: Dictionary = store.transit_network
	if network.is_empty():
		return 0.0
	var center: Vector2 = settlement.get("position", Vector2.ZERO)
	var radius := maxf(620.0, float(settlement.get("built_up_radius_m", 500.0)) + 420.0)
	return TransitNetwork.stop_accessibility_score(network, center, radius)


static func _count_player_links(city: Dictionary, settlement: Dictionary) -> int:
	var count := 0
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("status", "")) != "built":
			continue
		if str(road.get("source", "")) not in ["player", "city"]:
			continue
		if str(road.get("class", "")) not in ["collector", "arterial"]:
			continue
		if _road_touches_settlement(road, settlement):
			count += 1
	return count


static func _count_historic_strategic_links(city: Dictionary, settlement: Dictionary) -> int:
	var count := 0
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("status", "")) != "built":
			continue
		if str(road.get("source", "")) != "regional-existing":
			continue
		if str(road.get("regionalRole", "")) not in ["spine", "loop", "external_branch", "city_connector"]:
			continue
		if _road_touches_settlement(road, settlement):
			count += 1
	return count


static func _road_touches_settlement(road: Dictionary, settlement: Dictionary) -> bool:
	var settlement_id := str(settlement.get("id", ""))
	if settlement_id in [
		str(road.get("a", "")),
		str(road.get("b", "")),
		str(road.get("settlementId", "")),
		str(road.get("districtId", "")),
	]:
		return true
	var center: Vector2 = settlement.get("position", Vector2.ZERO)
	var radius := float(settlement.get("built_up_radius_m", 500.0)) + 180.0
	var nearest := RoadTopology.closest_point_on_road(center, road)
	return not nearest.is_empty() and float(nearest.get("distance", INF)) <= radius


static func _parcel_stats(city: Dictionary, settlement_id: String) -> Dictionary:
	var total := 0
	var vacant := 0
	var built := 0
	for parcel_value in city.get("parcels", []):
		var parcel: Dictionary = parcel_value
		if str(parcel.get("districtId", "")) != settlement_id:
			continue
		total += 1
		if str(parcel.get("status", "")) == "vacant":
			vacant += 1
		elif str(parcel.get("status", "")) == "built":
			built += 1
	return {"total": total, "vacant": vacant, "built": built}


static func _best_vacant_parcel(store: Node, settlement: Dictionary) -> Dictionary:
	var candidates: Array[Dictionary] = []
	var settlement_id := str(settlement.get("id", ""))
	var center: Vector2 = settlement.get("position", Vector2.ZERO)
	var radius := maxf(1.0, float(settlement.get("built_up_radius_m", 500.0)))
	for parcel_value in store.city.get("parcels", []):
		var parcel: Dictionary = parcel_value
		if str(parcel.get("districtId", "")) != settlement_id:
			continue
		if str(parcel.get("status", "")) != "vacant":
			continue
		var frontage := _find_by_id(store.city.get("roads", []), str(parcel.get("frontageRoadId", "")))
		if frontage.is_empty() or str(frontage.get("status", "")) != "built":
			continue
		var position := Vector2(float(parcel.get("x", 0.0)), float(parcel.get("y", 0.0)))
		var transit := 0.0
		if typeof(store.transit_network) == TYPE_DICTIONARY:
			transit = TransitNetwork.stop_accessibility_score(store.transit_network, position, 620.0)
		var centrality := 1.0 - clampf(position.distance_to(center) / maxf(radius * 1.35, 1.0), 0.0, 1.0)
		var score := transit * 4.0 + centrality * 0.35 - float(parcel.get("developmentOrder", 0.0)) * 0.0005
		candidates.append({"parcel": parcel, "score": score})
	candidates.sort_custom(func(a, b):
		var score_a := float(a.get("score", 0.0))
		var score_b := float(b.get("score", 0.0))
		if not is_equal_approx(score_a, score_b):
			return score_a > score_b
		return str(a.get("parcel", {}).get("id", "")) < str(b.get("parcel", {}).get("id", ""))
	)
	return candidates[0].get("parcel", {}) if not candidates.is_empty() else {}


static func _develop_parcel(
	store: Node,
	settlement: Dictionary,
	parcel: Dictionary,
	local_state: Dictionary,
	pressure: float,
	tick: int
) -> bool:
	var serial := int(local_state.get("development_serial", 0)) + 1
	local_state["development_serial"] = serial
	var stage := _stage_for_population(int(settlement.get("population", 0)))
	var profile := _profile_for(stage, str(parcel.get("zone", "residential")), serial, pressure)
	var contribution := _profile_contribution(str(parcel.get("zone", "residential")), profile)
	var residents_added := int(contribution.get("residents", 0))
	var jobs_added := int(contribution.get("jobs", 0))
	var building_id := "organic-building-%s-%06d" % [str(settlement.get("id", "settlement")), serial]
	parcel["status"] = "built"
	parcel["source"] = "organic-growth"
	parcel["buildingId"] = building_id
	parcel["reservedAt"] = null
	parcel["density"] = int(profile.get("density", 1))
	parcel["growthTick"] = tick
	parcel["residentsAdded"] = residents_added
	parcel["jobsAdded"] = jobs_added
	store.city["buildings"].append({
		"id": building_id,
		"districtId": str(parcel.get("districtId", "")),
		"parcelId": str(parcel.get("id", "")),
		"x": float(parcel.get("x", 0.0)),
		"y": float(parcel.get("y", 0.0)),
		"zone": str(parcel.get("zone", "residential")),
		"profile": profile,
		"rotationRadians": CoreRuntime._parcel_frontage_angle(store.city, parcel),
		"source": "organic-growth",
		"status": "built",
		"constructionProgress": 1.0,
		"growthTick": tick,
		"residentsAdded": residents_added,
		"jobsAdded": jobs_added,
	})
	_apply_demographic_delta(store.city, settlement, residents_added, jobs_added)
	return true


static func _densify_settlement(
	store: Node,
	settlement: Dictionary,
	local_state: Dictionary,
	tick: int
) -> bool:
	var settlement_id := str(settlement.get("id", ""))
	var center: Vector2 = settlement.get("position", Vector2.ZERO)
	var radius := maxf(1.0, float(settlement.get("built_up_radius_m", 500.0)))
	var best: Dictionary = {}
	var best_score := -INF
	for building_value in store.city.get("buildings", []):
		var building: Dictionary = building_value
		if str(building.get("districtId", "")) != settlement_id:
			continue
		if str(building.get("status", "")) != "built":
			continue
		var profile: Dictionary = building.get("profile", {})
		var floors := int(profile.get("floors", 1))
		if floors >= _max_floors_for_stage(_stage_for_population(int(settlement.get("population", 0)))):
			continue
		var position := Vector2(float(building.get("x", 0.0)), float(building.get("y", 0.0)))
		var centrality := 1.0 - clampf(position.distance_to(center) / radius, 0.0, 1.0)
		var transit := 0.0
		if typeof(store.transit_network) == TYPE_DICTIONARY:
			transit = TransitNetwork.stop_accessibility_score(store.transit_network, position, 520.0)
		var score := centrality + transit * 2.4 - float(floors) * 0.08
		if score > best_score:
			best_score = score
			best = building
	if best.is_empty():
		return false

	var old_profile: Dictionary = best.get("profile", {}).duplicate(true)
	var zone := str(best.get("zone", "residential"))
	var new_profile := _upgraded_profile(old_profile, zone, _stage_for_population(int(settlement.get("population", 0))))
	if new_profile == old_profile:
		return false
	var old_contribution := _profile_contribution(zone, old_profile)
	var new_contribution := _profile_contribution(zone, new_profile)
	var residents_added := maxi(0, int(new_contribution.get("residents", 0)) - int(old_contribution.get("residents", 0)))
	var jobs_added := maxi(0, int(new_contribution.get("jobs", 0)) - int(old_contribution.get("jobs", 0)))
	best["profile"] = new_profile
	best["source"] = "organic-growth"
	best["organicDensityLevel"] = int(best.get("organicDensityLevel", 0)) + 1
	best["lastGrowthTick"] = tick
	var parcel := _find_by_id(store.city.get("parcels", []), str(best.get("parcelId", "")))
	if not parcel.is_empty():
		parcel["density"] = int(new_profile.get("density", parcel.get("density", 1)))
		parcel["residentsAdded"] = int(parcel.get("residentsAdded", 0)) + residents_added
		parcel["jobsAdded"] = int(parcel.get("jobsAdded", 0)) + jobs_added
	_apply_demographic_delta(store.city, settlement, residents_added, jobs_added)
	local_state["densification_serial"] = int(local_state.get("densification_serial", 0)) + 1
	return true


static func _expand_settlement(
	store: Node,
	settlement: Dictionary,
	local_state: Dictionary,
	tick: int
) -> bool:
	var serial := int(local_state.get("expansion_serial", 0)) + 1
	var candidate := _best_expansion_candidate(store, settlement, serial, tick)
	if candidate.is_empty():
		return false
	var settlement_id := str(settlement.get("id", ""))
	var stage := _stage_for_population(int(settlement.get("population", 0)))
	var road_class := "collector" if stage in ["city", "metropolis"] else "local"
	var road_id := "organic-road-%s-%03d" % [settlement_id, serial]
	var road := {
		"id": road_id,
		"districtId": settlement_id,
		"class": road_class,
		"points": _serialize_points(candidate.get("points", [])),
		"unlock": null,
		"buildOrder": 1000 + serial,
		"source": "organic-growth",
		"parentRoadIds": [str(candidate.get("anchor_road_id", ""))],
		"status": "built",
		"constructionProgress": 1.0,
		"level": 0.0,
		"profile": RoadProfile.base_profile(road_class),
		"regionalRole": "organic_expansion",
		"a": str(candidate.get("anchor_node_id", settlement_id)),
		"b": "organic-node-%s-%03d" % [settlement_id, serial],
		"settlementId": settlement_id,
		"bridgeCrossings": [],
		"growthTick": tick,
	}
	store.city["roads"].append(road)
	_append_road_to_morphology(store.city, settlement_id, road_id)
	var created := _create_expansion_parcels(store.city, settlement, road, serial)
	if created <= 0:
		store.city["roads"].erase(road)
		return false
	local_state["expansion_serial"] = serial
	settlement["expansionCount"] = serial
	return true


static func _best_expansion_candidate(
	store: Node,
	settlement: Dictionary,
	serial: int,
	tick: int
) -> Dictionary:
	var anchors := _frontier_anchors(store.city, settlement)
	if anchors.is_empty():
		return {}
	var bounds := MapDefinition.bounds_for(str(store.city.get("world_map_id", MapDefinition.DEFAULT_MAP_ID))).abs()
	var safe_bounds := Rect2(
		bounds.position + Vector2.ONE * BOUNDS_MARGIN_METERS,
		bounds.size - Vector2.ONE * BOUNDS_MARGIN_METERS * 2.0
	)
	var center: Vector2 = settlement.get("position", Vector2.ZERO)
	var population := float(settlement.get("population", 0.0))
	var segment_length := clampf(250.0 + sqrt(maxf(population, 1.0)) * 2.2, 280.0, 620.0)
	var best: Dictionary = {}
	var best_score := -INF
	var rotation := _unit_random(int(store.city.get("seed", 0)), "%s:%d:%d" % [str(settlement.get("id", "")), serial, tick]) * TAU
	for anchor_value in anchors:
		var anchor: Dictionary = anchor_value
		var start: Vector2 = anchor.get("position", center)
		var outward := (start - center).normalized()
		if outward.length_squared() < 0.001:
			outward = Vector2(cos(rotation), sin(rotation))
		for offset in [-0.62, -0.34, -0.16, 0.0, 0.16, 0.34, 0.62]:
			var direction := outward.rotated(float(offset) + (rotation - PI) * 0.025).normalized()
			var end := start + direction * segment_length
			if not safe_bounds.has_point(end):
				continue
			var side := Vector2(-direction.y, direction.x)
			var curve := lerpf(-0.10, 0.10, _unit_random(int(store.city.get("seed", 0)), "%s:%d:curve:%.2f" % [str(settlement.get("id", "")), serial, float(offset)]))
			var mid := start.lerp(end, 0.52) + side * segment_length * curve
			if not _point_is_buildable(int(store.city.get("seed", 0)), mid):
				continue
			if not _point_is_buildable(int(store.city.get("seed", 0)), end):
				continue
			if _too_close_to_other_settlement(store.city, settlement, end):
				continue
			var points: Array[Vector2] = [start, mid, end]
			var probe := {
				"id": "organic-probe",
				"class": "local",
				"points": points,
				"parentRoadIds": [str(anchor.get("road_id", ""))],
			}
			if RoadTopology.has_parallel_overlap(probe, store.city.get("roads", []), 6.0):
				continue
			var end_sample := WorldLayers.sample_route_terrain(int(store.city.get("seed", 0)), end)
			var mid_sample := WorldLayers.sample_route_terrain(int(store.city.get("seed", 0)), mid)
			var terrain_penalty := (
				float(end_sample.get("slope_degrees", 0.0)) * 0.10
				+ float(mid_sample.get("slope_degrees", 0.0)) * 0.07
				+ float(end_sample.get("forest_potential", 0.0)) * 0.55
			)
			var transit_bonus := 0.0
			if typeof(store.transit_network) == TYPE_DICTIONARY:
				transit_bonus = TransitNetwork.stop_accessibility_score(store.transit_network, end, 900.0) * 2.8
			var score := transit_bonus - terrain_penalty + _direction_novelty(store.city, settlement, end)
			if score > best_score:
				best_score = score
				best = {
					"points": points,
					"anchor_road_id": str(anchor.get("road_id", "")),
					"anchor_node_id": str(anchor.get("node_id", str(settlement.get("id", "")))),
				}
	return best


static func _frontier_anchors(city: Dictionary, settlement: Dictionary) -> Array[Dictionary]:
	var settlement_id := str(settlement.get("id", ""))
	var center: Vector2 = settlement.get("position", Vector2.ZERO)
	var anchors: Array[Dictionary] = []
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("status", "")) != "built":
			continue
		if str(road.get("settlementId", road.get("districtId", ""))) != settlement_id:
			continue
		if str(road.get("class", "")) not in ["local", "collector"]:
			continue
		var points: Array = road.get("points", [])
		if points.size() < 2:
			continue
		var first := _to_vec(points[0])
		var last := _to_vec(points.back())
		if last.distance_to(center) >= first.distance_to(center):
			anchors.append({"road_id": str(road.get("id", "")), "node_id": str(road.get("b", settlement_id)), "position": last})
		else:
			anchors.append({"road_id": str(road.get("id", "")), "node_id": str(road.get("a", settlement_id)), "position": first})
	anchors.sort_custom(func(a, b):
		return (a.get("position", center) as Vector2).distance_to(center) > (b.get("position", center) as Vector2).distance_to(center)
	)
	return anchors.slice(0, mini(12, anchors.size()))


static func _create_expansion_parcels(
	city: Dictionary,
	settlement: Dictionary,
	road: Dictionary,
	expansion_serial: int
) -> int:
	var settlement_id := str(settlement.get("id", ""))
	var points: Array = road.get("points", [])
	var stage := _stage_for_population(int(settlement.get("population", 0)))
	var base_order := _next_development_order(city)
	var created := 0
	var pair_count := ceili(float(PARCELS_PER_EXPANSION) / 2.0)
	for slot in range(PARCELS_PER_EXPANSION):
		var pair_index := slot / 2
		var fraction := clampf(0.14 + 0.76 * float(pair_index + 1) / float(pair_count + 1), 0.12, 0.92)
		var sample := _point_and_tangent(points, RoadTopology.polyline_length(points) * fraction)
		var access: Vector2 = sample.get("point", Vector2.ZERO)
		var tangent: Vector2 = sample.get("tangent", Vector2.RIGHT)
		var normal := Vector2(-tangent.y, tangent.x)
		var side := -1.0 if slot % 2 == 0 else 1.0
		var lateral := 31.0 if stage in ["village", "small_town"] else 35.0
		var position := access + normal * side * lateral
		if not _point_is_buildable(int(city.get("seed", 0)), position):
			continue
		if _parcel_overlap(city, position, 24.0):
			continue
		var zone := _zone_for_expansion(stage, slot, expansion_serial)
		var kind := _candidate_kind_for(stage, zone, slot)
		var parcel_id := "organic-parcel-%s-%03d-%02d" % [settlement_id, expansion_serial, slot + 1]
		var footprint := _parcel_footprint(kind)
		var parcel := {
			"id": parcel_id,
			"districtId": settlement_id,
			"blockId": "regional-block-%s" % settlement_id,
			"x": position.x,
			"y": position.y,
			"w": footprint.x,
			"h": footprint.y,
			"zone": zone,
			"density": _base_density_for_stage(stage),
			"setback": 4.0,
			"frontageRoadId": str(road.get("id", "")),
			"developmentOrder": float(base_order + created),
			"growthOrder": base_order + created,
			"terrainSlope": float(WorldLayers.sample_route_terrain(int(city.get("seed", 0)), position).get("slope_degrees", 0.0)),
			"forestPressure": float(WorldLayers.sample_route_terrain(int(city.get("seed", 0)), position).get("forest_potential", 0.0)),
			"source": "organic-capacity",
			"status": "vacant",
			"reservedAt": null,
			"buildingId": "",
			"candidateBuildingType": kind,
		}
		city["parcels"].append(parcel)
		_append_parcel_to_morphology(city, settlement_id, parcel_id)
		created += 1
	return created


static func _profile_for(stage: String, zone: String, serial: int, pressure: float) -> Dictionary:
	var kind := "house"
	var floors := 1
	var density := _base_density_for_stage(stage)
	if zone == "commercial":
		kind = "shop"
		floors = 1 if stage in ["village", "small_town"] else 2
	elif zone == "mixed":
		kind = "townhouse" if stage in ["village", "small_town"] else "apartment"
		floors = 2 if kind == "townhouse" else 3
	elif stage == "small_town":
		if serial % 4 == 0 or pressure > 1.25:
			kind = "townhouse"
			floors = 2
	elif stage == "town":
		kind = "apartment" if serial % 3 == 0 or pressure > 1.25 else "townhouse"
		floors = 3 if kind == "apartment" else 2
	elif stage == "city":
		kind = "apartment"
		floors = 4 + serial % 2
	elif stage == "metropolis":
		kind = "apartment"
		floors = 5 + serial % 3
	return {
		"kind": kind,
		"floors": floors,
		"density": density,
		"heightMeters": 4.2 + float(floors) * 3.05,
	}


static func _upgraded_profile(profile: Dictionary, zone: String, stage: String) -> Dictionary:
	var result := profile.duplicate(true)
	var kind := str(result.get("kind", "house"))
	var floors := int(result.get("floors", 1))
	var max_floors := _max_floors_for_stage(stage)
	if zone in ["commercial", "industrial", "civic"]:
		result["kind"] = "shop"
		result["floors"] = mini(max_floors, floors + 1)
	else:
		if kind == "house":
			result["kind"] = "townhouse"
			result["floors"] = 2
		elif kind == "townhouse":
			result["kind"] = "apartment"
			result["floors"] = mini(max_floors, 3)
		else:
			result["kind"] = "apartment"
			result["floors"] = mini(max_floors, floors + 1)
	result["density"] = mini(4, maxi(int(result.get("density", 1)), _base_density_for_stage(stage)) + 1)
	result["heightMeters"] = 4.2 + float(result.get("floors", 1)) * 3.05
	return result


static func _profile_contribution(zone: String, profile: Dictionary) -> Dictionary:
	var kind := str(profile.get("kind", "house"))
	var floors := maxi(1, int(profile.get("floors", 1)))
	var density := clampi(int(profile.get("density", 1)), 1, 4)
	if zone in ["commercial", "industrial", "civic"] or kind == "shop":
		return {"residents": 0, "jobs": maxi(8, floors * density * 11)}
	if zone == "mixed":
		return {"residents": floors * density * 9, "jobs": floors * density * 4}
	if kind == "house":
		return {"residents": 12, "jobs": 0}
	if kind == "townhouse":
		return {"residents": floors * density * 10, "jobs": 0}
	return {"residents": floors * density * 14, "jobs": 0}


static func _apply_demographic_delta(city: Dictionary, settlement: Dictionary, residents: int, jobs: int) -> void:
	settlement["population"] = maxi(0, int(settlement.get("population", 0))) + residents
	settlement["jobs"] = maxi(0, int(settlement.get("jobs", 0))) + jobs
	var district := _find_by_id(city.get("districts", []), str(settlement.get("id", "")))
	if not district.is_empty():
		district["population"] = maxi(0, int(district.get("population", 0))) + residents
		district["jobs"] = maxi(0, int(district.get("jobs", 0))) + jobs
	CoreRuntime._refresh_regional_demographics(city)


static func _update_settlement_form(city: Dictionary, settlement: Dictionary) -> void:
	var center: Vector2 = settlement.get("position", Vector2.ZERO)
	var settlement_id := str(settlement.get("id", ""))
	var radius := 0.0
	for parcel_value in city.get("parcels", []):
		var parcel: Dictionary = parcel_value
		if str(parcel.get("districtId", "")) != settlement_id:
			continue
		var position := Vector2(float(parcel.get("x", 0.0)), float(parcel.get("y", 0.0)))
		radius = maxf(radius, position.distance_to(center) + 45.0)
	settlement["built_up_radius_m"] = maxf(float(settlement.get("built_up_radius_m", 0.0)), radius)
	settlement["urbanStage"] = _stage_for_population(int(settlement.get("population", 0)))


static func _update_urban_clusters(city: Dictionary) -> void:
	var settlements: Array = city.get("regional_settlements", [])
	var parent: Array[int] = []
	for index in range(settlements.size()):
		parent.append(index)
	for a_index in range(settlements.size()):
		var a: Dictionary = settlements[a_index]
		var a_pos: Vector2 = a.get("position", Vector2.ZERO)
		var a_radius := float(a.get("built_up_radius_m", 0.0))
		for b_index in range(a_index + 1, settlements.size()):
			var b: Dictionary = settlements[b_index]
			var b_pos: Vector2 = b.get("position", Vector2.ZERO)
			var b_radius := float(b.get("built_up_radius_m", 0.0))
			if a_pos.distance_to(b_pos) <= a_radius + b_radius + URBAN_CLUSTER_GAP_METERS:
				_union(parent, a_index, b_index)
	var groups: Dictionary = {}
	for index in range(settlements.size()):
		var root := _find_root(parent, index)
		if not groups.has(root):
			groups[root] = []
		groups[root].append(index)
	var clusters: Array[Dictionary] = []
	var serial := 1
	for member_indices_value in groups.values():
		var member_indices: Array = member_indices_value
		var member_ids: Array[String] = []
		var population := 0
		var jobs := 0
		var weighted_center := Vector2.ZERO
		for index_value in member_indices:
			var settlement: Dictionary = settlements[int(index_value)]
			var pop := maxi(1, int(settlement.get("population", 0)))
			member_ids.append(str(settlement.get("id", "")))
			population += int(settlement.get("population", 0))
			jobs += int(settlement.get("jobs", 0))
			weighted_center += (settlement.get("position", Vector2.ZERO) as Vector2) * float(pop)
		clusters.append({
			"id": "urban-cluster-%02d" % serial,
			"settlementIds": member_ids,
			"population": population,
			"jobs": jobs,
			"center": weighted_center / float(maxi(1, population)),
			"stage": _stage_for_population(population),
			"merged": member_ids.size() > 1,
		})
		serial += 1
	city["urban_clusters"] = clusters


static func _update_corridor_pressure(city: Dictionary) -> void:
	var population_by_id: Dictionary = {}
	for settlement_value in city.get("regional_settlements", []):
		var settlement: Dictionary = settlement_value
		population_by_id[str(settlement.get("id", ""))] = int(settlement.get("population", 0))
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("regionalRole", "")) not in ["spine", "loop", "external_branch", "city_connector"]:
			continue
		var a_pop := int(population_by_id.get(str(road.get("a", "")), 0))
		var b_pop := int(population_by_id.get(str(road.get("b", "")), 0))
		var combined := a_pop + b_pop
		var length_km := maxf(1.0, RoadTopology.polyline_length(road.get("points", [])) / 1000.0)
		var pressure := float(combined) / (12000.0 * sqrt(length_km))
		road["upgradePressure"] = pressure
		var recommendation := "none"
		if pressure >= 4.0:
			recommendation = "motorway"
		elif pressure >= 2.2:
			recommendation = "expressway"
		elif pressure >= 1.2:
			recommendation = "arterial"
		road["upgradeRecommendation"] = recommendation


static func _recompile_road_graph(city: Dictionary) -> void:
	var compiled := RoadTopology.compile_graph(city.get("roads", []))
	city["nodes"] = compiled.get("nodes", [])
	city["graph_edges"] = compiled.get("graphEdges", [])
	city["junctions"] = compiled.get("junctions", [])


static func _append_road_to_morphology(city: Dictionary, settlement_id: String, road_id: String) -> void:
	var district := _find_by_id(city.get("districts", []), settlement_id)
	if not district.is_empty():
		var road_ids: Array = district.get("roadIds", [])
		if not road_ids.has(road_id):
			road_ids.append(road_id)
		district["roadIds"] = road_ids
	var block := _find_by_id(city.get("blocks", []), "regional-block-%s" % settlement_id)
	if not block.is_empty():
		var block_roads: Array = block.get("roadIds", [])
		if not block_roads.has(road_id):
			block_roads.append(road_id)
		block["roadIds"] = block_roads


static func _append_parcel_to_morphology(city: Dictionary, settlement_id: String, parcel_id: String) -> void:
	var district := _find_by_id(city.get("districts", []), settlement_id)
	if not district.is_empty():
		var parcel_ids: Array = district.get("parcelIds", [])
		parcel_ids.append(parcel_id)
		district["parcelIds"] = parcel_ids
	var block := _find_by_id(city.get("blocks", []), "regional-block-%s" % settlement_id)
	if not block.is_empty():
		var block_parcels: Array = block.get("parcelIds", [])
		block_parcels.append(parcel_id)
		block["parcelIds"] = block_parcels


static func _too_close_to_other_settlement(city: Dictionary, settlement: Dictionary, point: Vector2) -> bool:
	var own_id := str(settlement.get("id", ""))
	for other_value in city.get("regional_settlements", []):
		var other: Dictionary = other_value
		if str(other.get("id", "")) == own_id:
			continue
		var center: Vector2 = other.get("position", Vector2.ZERO)
		var keepout := maxf(260.0, float(other.get("built_up_radius_m", 0.0)) * 0.72)
		if point.distance_to(center) < keepout:
			return true
	return false


static func _direction_novelty(city: Dictionary, settlement: Dictionary, point: Vector2) -> float:
	var settlement_id := str(settlement.get("id", ""))
	var nearest := INF
	for parcel_value in city.get("parcels", []):
		var parcel: Dictionary = parcel_value
		if str(parcel.get("districtId", "")) != settlement_id:
			continue
		var parcel_pos := Vector2(float(parcel.get("x", 0.0)), float(parcel.get("y", 0.0)))
		nearest = minf(nearest, point.distance_to(parcel_pos))
	return clampf(nearest / 500.0, 0.0, 1.4)


static func _point_is_buildable(seed: int, point: Vector2) -> bool:
	var sample := WorldLayers.sample_route_terrain(seed, point)
	if float(sample.get("water_depth", 0.0)) > 0.05:
		return false
	if str(sample.get("water_kind", "none")) not in ["", "none"]:
		return false
	return float(sample.get("slope_degrees", 0.0)) <= TERRAIN_MAX_SLOPE_DEGREES


static func _parcel_overlap(city: Dictionary, point: Vector2, minimum_distance: float) -> bool:
	for parcel_value in city.get("parcels", []):
		var parcel: Dictionary = parcel_value
		var other := Vector2(float(parcel.get("x", 0.0)), float(parcel.get("y", 0.0)))
		if point.distance_to(other) < minimum_distance:
			return true
	return false


static func _next_development_order(city: Dictionary) -> int:
	var maximum := 0
	for parcel_value in city.get("parcels", []):
		maximum = maxi(maximum, int((parcel_value as Dictionary).get("growthOrder", 0)))
	return maximum + 1


static func _zone_for_expansion(stage: String, slot: int, expansion_serial: int) -> String:
	if (slot + expansion_serial) % 11 == 0:
		return "commercial"
	if stage in ["town", "city", "metropolis"] and (slot + expansion_serial) % 6 == 0:
		return "mixed"
	return "residential"


static func _candidate_kind_for(stage: String, zone: String, slot: int) -> String:
	if zone == "commercial":
		return "shop"
	if stage in ["city", "metropolis"]:
		return "apartment"
	if stage == "town" and slot % 3 == 0:
		return "apartment"
	if stage in ["small_town", "town"] and slot % 2 == 0:
		return "townhouse"
	return "house"


static func _parcel_footprint(kind: String) -> Vector2:
	match kind:
		"shop":
			return Vector2(24.0, 16.0)
		"townhouse":
			return Vector2(18.0, 13.0)
		"apartment":
			return Vector2(28.0, 22.0)
	return Vector2(15.0, 11.0)


static func _base_density_for_stage(stage: String) -> int:
	match stage:
		"metropolis":
			return 4
		"city":
			return 3
		"town":
			return 2
	return 1


static func _max_floors_for_stage(stage: String) -> int:
	match stage:
		"metropolis":
			return 10
		"city":
			return 7
		"town":
			return 4
	return 2


static func _stage_for_population(population: int) -> String:
	if population >= 60000:
		return "metropolis"
	if population >= 20000:
		return "city"
	if population >= 6000:
		return "town"
	if population >= 1500:
		return "small_town"
	return "village"


static func _point_and_tangent(points: Array, distance_along: float) -> Dictionary:
	var remaining := distance_along
	for index in range(1, points.size()):
		var start := _to_vec(points[index - 1])
		var finish := _to_vec(points[index])
		var length := start.distance_to(finish)
		if length <= 0.001:
			continue
		if remaining <= length or index == points.size() - 1:
			return {
				"point": start.lerp(finish, clampf(remaining / length, 0.0, 1.0)),
				"tangent": (finish - start).normalized(),
			}
		remaining -= length
	return {"point": _to_vec(points.back()), "tangent": Vector2.RIGHT}


static func _serialize_points(points: Array) -> Array:
	var result: Array = []
	for point_value in points:
		var point := _to_vec(point_value)
		result.append({"x": point.x, "y": point.y})
	return result


static func _to_vec(value) -> Vector2:
	if value is Vector2:
		return value
	return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))


static func _find_by_id(items: Array, item_id: String) -> Dictionary:
	for item_value in items:
		if typeof(item_value) != TYPE_DICTIONARY:
			continue
		var item: Dictionary = item_value
		if str(item.get("id", "")) == item_id:
			return item
	return {}


static func _find_root(parent: Array[int], index: int) -> int:
	var cursor := index
	while parent[cursor] != cursor:
		parent[cursor] = parent[parent[cursor]]
		cursor = parent[cursor]
	return cursor


static func _union(parent: Array[int], first: int, second: int) -> void:
	var first_root := _find_root(parent, first)
	var second_root := _find_root(parent, second)
	if first_root != second_root:
		parent[second_root] = first_root


static func _unit_random(seed: int, key: String) -> float:
	var hash_value := 2166136261
	for index in range(key.length()):
		hash_value = (hash_value ^ key.unicode_at(index)) & 0xffffffff
		hash_value = (hash_value * 16777619) & 0xffffffff
	var value := (seed ^ hash_value) & 0xffffffff
	value = (value * 1664525 + 1013904223) & 0xffffffff
	return float(value & 0xffff) / 65535.0


static func _is_regional_city(city: Dictionary) -> bool:
	return str(city.get("world_map_id", MapDefinition.LEGACY_CITY_MAP_ID)) != MapDefinition.LEGACY_CITY_MAP_ID
