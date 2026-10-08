extends RefCounted
class_name CityRuntime

const Data = preload("res://scripts/core/game_data.gd")
const LEGACY_PLAN_GENERATOR_PATH := "res://scripts/city/city_plan_generator.gd"
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const RegionPlanGenerator = preload("res://scripts/world/region_plan_generator.gd")
const RoadTopology = preload("res://scripts/city/road_topology.gd")
const RoadProfile = preload("res://scripts/city/road_profile.gd")
const CityServices = preload("res://scripts/city/city_services.gd")

const CITY_VERSION := 1
const MAX_ACTIVE_PROJECTS := 2
const STEP_SECONDS := 0.2
const REGIONAL_GROWTH_INTERVAL_SECONDS := 180.0
const MAX_REGIONAL_AUTONOMOUS_BUILDINGS := 36
const REGIONAL_STARTER_SERVICE_CAPACITY_SHARE := 0.72
const REGIONAL_TRANSIT_ACCESS_PRIORITY_WEIGHT := 20.0
const REGIONAL_HEALTH_ATTRACTIVENESS_WEIGHT := 0.08
const REGIONAL_CORE_LOCAL_ROAD_COUNT := 2
const REGIONAL_CORE_BUILDING_COUNT := 3
# Per-density prototype increments: homes +8 residents, commercial +5 jobs, mixed +4/+3.
# These are aggregate cohorts, not individual citizens.
const REGIONAL_RESIDENTS_PER_DENSITY := 8
const REGIONAL_JOBS_PER_DENSITY := 5
const REGIONAL_MIXED_RESIDENTS_PER_DENSITY := 4
const REGIONAL_MIXED_JOBS_PER_DENSITY := 3

static func create_initial_city(
	seed: int = Data.DEFAULT_CITY_SEED,
	map_id: String = MapDefinition.LEGACY_CITY_MAP_ID
) -> Dictionary:
	var plan: Dictionary = {}
	var roads: Array = []
	var regional_plan: Dictionary = {}
	var settlements: Array = []
	var outside_connections: Array = []
	var regional_morphology: Dictionary = {
		"districts": [],
		"blocks": [],
		"parcels": [],
		"buildings": [],
	}
	var nodes: Array = []
	var graph_edges: Array = []
	var junctions: Array = []
	if map_id == MapDefinition.LEGACY_CITY_MAP_ID:
		var legacy_generator: Script = load(LEGACY_PLAN_GENERATOR_PATH)
		plan = legacy_generator.call("generate", seed)
		roads = plan.get("roads", []).duplicate(true)
		nodes = plan.get("nodes", [])
		graph_edges = plan.get("graphEdges", [])
		junctions = plan.get("junctions", [])
	else:
		var map_bounds := MapDefinition.bounds_for(map_id)
		regional_plan = RegionPlanGenerator.generate(seed, map_bounds)
		if bool(regional_plan.get("valid", false)):
			settlements = regional_plan.get("settlements", []).duplicate(true)
			outside_connections = regional_plan.get("external_connections", []).duplicate(true)
			for settlement in settlements:
				settlement["source"] = "regional-existing"
				settlement["status"] = "active"
				settlement["jobs"] = int(round(float(settlement.get("population", 0)) * 0.43))
			for connection in outside_connections:
				connection["source"] = "regional-existing"
				connection["status"] = "active"
			var core_settlement_id := str(settlements[0].get("id", "")) if not settlements.is_empty() else ""
			var built_local_road_ids := _initial_core_local_road_ids(regional_plan, core_settlement_id)
			var built_strategic_road_ids := _initial_core_strategic_road_ids(regional_plan, core_settlement_id)
			regional_morphology = _city_morphology_from_region(
				regional_plan,
				core_settlement_id,
				built_local_road_ids
			)
			for regional_road in regional_plan.get("graph_edges", []):
				var road_id := str(regional_road.get("id", ""))
				var is_local := str(regional_road.get("role", "")) == "local_street"
				var is_built := built_local_road_ids.has(road_id) if is_local else built_strategic_road_ids.has(road_id)
				roads.append(_city_road_from_region(regional_road, is_local, is_built, settlements))
			_append_regional_city_link(roads, settlements)
			var compiled_graph := RoadTopology.compile_graph(roads)
			nodes = compiled_graph.get("nodes", [])
			graph_edges = compiled_graph.get("graphEdges", [])
			junctions = compiled_graph.get("junctions", [])

	var total_population := 0
	var total_jobs := 0
	for settlement in settlements:
		var population := maxi(0, int(settlement.get("population", 0)))
		total_population += population
		total_jobs += maxi(0, int(settlement.get("jobs", round(float(population) * 0.43))))
	var regional_services := _build_regional_services(
		settlements,
		regional_plan.get("graph_edges", []),
		outside_connections
	)

	return {
		"version": CITY_VERSION,
		"seed": seed,
		"world_map_id": map_id,
		"world_seed": seed,
		"generator_version": MapDefinition.GENERATOR_VERSION,
		"regional_settlements": settlements,
		"outside_connections": outside_connections,
		"regional_plan_stats": regional_plan.get("stats", {}),
		"demographics": {
			"residents": total_population,
			"jobs": total_jobs,
			"students": int(round(float(total_population) * 0.16)),
		},
		"service_networks": regional_services.get("networks", _empty_service_networks()),
		"service_buildings": regional_services.get("buildings", []),
		"service_demand_points": regional_services.get("demand_points", []),
		"service_results": regional_services.get("results", {}),
		"time_seconds": 0.0,
		"runtime_accumulator_seconds": 0.0,
		"regional_growth_accumulator_seconds": 0.0,
		"regional_growth_ticks": 0,
		"regional_auto_growth_count": 0,
		"next_project_id": 1,
		"nodes": nodes,
		"graph_edges": graph_edges,
		"junctions": junctions,
		"roads": roads,
		"districts": plan.get("districts", []) + regional_morphology["districts"],
		"blocks": plan.get("blocks", []) + regional_morphology["blocks"],
		"parcels": plan.get("parcels", []) + regional_morphology["parcels"],
		"reservations": plan.get("reservations", []),
		"buildings": regional_morphology["buildings"],
		"projects": [],
	}

static func _city_road_from_region(
		raw_road: Dictionary,
		is_local: bool = false,
		built_on_start: bool = true,
		settlements: Array = []
) -> Dictionary:
	var road_class := str(raw_road.get("class", "secondary"))
	if road_class == "primary":
		road_class = "arterial"
	elif road_class == "secondary":
		road_class = "collector"
	if is_local or road_class not in RoadProfile.ROAD_CLASSES:
		road_class = "local"
	var serialized_points: Array = []
	for point_value in raw_road.get("points", []):
		if point_value is Vector2:
			var point: Vector2 = point_value
			serialized_points.append({"x": point.x, "y": point.y})
		elif typeof(point_value) == TYPE_DICTIONARY:
			serialized_points.append(point_value.duplicate(true))
	var settlement_id := str(raw_road.get("settlement_id", raw_road.get("a", ""))) if is_local else ""
	if settlement_id.is_empty():
		for settlement in settlements:
			var candidate_id := str(settlement.get("id", ""))
			if candidate_id in [str(raw_road.get("a", "")), str(raw_road.get("b", ""))]:
				settlement_id = candidate_id
				break
	var result := {
		"id": str(raw_road.get("id", "regional-road")),
		"districtId": settlement_id if not settlement_id.is_empty() else "regional-settlements",
		"class": road_class,
		"points": serialized_points,
		"unlock": null,
		"buildOrder": -100,
		"source": "regional-existing",
		"parentRoadIds": [],
		"status": "built" if built_on_start else "planned",
		"constructionProgress": 1.0 if built_on_start else 0.0,
		"level": float(raw_road.get("level", 0.0)),
		"profile": RoadProfile.base_profile(road_class),
		"regionalRole": str(raw_road.get("role", "local" if is_local else "spine")),
		"a": str(raw_road.get("a", "")),
		"b": str(raw_road.get("b", "")),
		"settlementId": settlement_id,
		"bridgeCrossings": raw_road.get("bridge_crossings", []).duplicate(true),
	}
	return result


static func _initial_core_local_road_ids(regional_plan: Dictionary, core_settlement_id: String) -> Array[String]:
	var roads: Array = []
	for street in regional_plan.get("local_streets", []):
		if str(street.get("settlement_id", "")) == core_settlement_id:
			roads.append(street)
	roads.sort_custom(func(a, b): return str(a.get("id", "")) < str(b.get("id", "")))
	var result: Array[String] = []
	for index in range(mini(REGIONAL_CORE_LOCAL_ROAD_COUNT, roads.size())):
		result.append(str(roads[index].get("id", "")))
	return result


static func _initial_core_strategic_road_ids(regional_plan: Dictionary, core_settlement_id: String) -> Array[String]:
	var roads: Array = []
	for road in regional_plan.get("graph_edges", []):
		if str(road.get("role", "")) == "local_street":
			continue
		if str(road.get("role", "")) != "spine":
			continue
		if str(road.get("a", "")) == core_settlement_id or str(road.get("b", "")) == core_settlement_id:
			roads.append(road)
	roads.sort_custom(func(a, b): return str(a.get("id", "")) < str(b.get("id", "")))
	var result: Array[String] = []
	if not roads.is_empty():
		result.append(str(roads[0].get("id", "")))
	return result


static func _city_morphology_from_region(
	regional_plan: Dictionary,
	core_settlement_id: String,
	built_local_road_ids: Array[String]
) -> Dictionary:
	var districts: Array[Dictionary] = []
	var blocks: Array[Dictionary] = []
	var parcels: Array[Dictionary] = []
	var buildings: Array[Dictionary] = []
	var initial_core_buildings := 0
	var development_order := 0
	for settlement in regional_plan.get("settlements", []):
		var settlement_id := str(settlement.get("id", ""))
		var settlement_parcel_ids: Array[String] = []
		var settlement_road_ids: Array[String] = []
		for street in regional_plan.get("local_streets", []):
			if str(street.get("settlement_id", "")) == settlement_id:
				settlement_road_ids.append(str(street.get("id", "")))
		for parcel_anchor in regional_plan.get("parcels", []):
			if str(parcel_anchor.get("settlement_id", "")) != settlement_id:
				continue
			var building_id := str(parcel_anchor.get("building_id", ""))
			var parcel_id := str(parcel_anchor.get("id", ""))
			var parcel_position: Vector2 = parcel_anchor.get("position", Vector2.ZERO)
			var access_point: Vector2 = parcel_anchor.get("access_point", parcel_position)
			var footprint: Vector2 = parcel_anchor.get("footprint", Vector2(42.0, 34.0))
			var facing := (access_point - parcel_position).normalized()
			var building_type := str(_find_region_building(regional_plan, building_id).get("type", "house"))
			var zone := "commercial" if building_type == "shop" else "residential"
			var frontage_id := str(parcel_anchor.get("street_id", ""))
			var has_initial_road := built_local_road_ids.has(frontage_id)
			var initially_occupied := (
				settlement_id == core_settlement_id
				and has_initial_road
				and initial_core_buildings < REGIONAL_CORE_BUILDING_COUNT
			)
			settlement_parcel_ids.append(parcel_id)
			parcels.append({
				"id": parcel_id,
				"districtId": settlement_id,
				"blockId": "regional-block-%s" % settlement_id,
				"x": parcel_position.x,
				"y": parcel_position.y,
				"w": footprint.x,
				"h": footprint.y,
				"zone": zone,
				"density": 1,
				"setback": 4.0,
				"frontageRoadId": frontage_id,
				"developmentOrder": float(development_order),
				"growthOrder": development_order,
				"terrainSlope": 0.0,
				"forestPressure": 0.0,
				"source": "regional-existing" if initially_occupied else "regional-capacity",
				"status": "built" if initially_occupied else "vacant",
				"reservedAt": null,
				"buildingId": building_id if initially_occupied else "",
				"candidateBuildingType": building_type,
			})
			if initially_occupied:
				initial_core_buildings += 1
				buildings.append({
					"id": building_id,
					"districtId": settlement_id,
					"parcelId": parcel_id,
					"x": parcel_position.x,
					"y": parcel_position.y,
					"zone": zone,
					"profile": {
						"kind": building_type,
						"floors": 2 if building_type == "shop" else 1,
						"density": 1,
						"heightMeters": 7.8 if building_type == "shop" else 5.2,
					},
					"rotationRadians": facing.angle(),
					"source": "regional-existing",
					"status": "built",
					"constructionProgress": 1.0,
				})
			development_order += 1
		var block_id := "regional-block-%s" % settlement_id
		blocks.append({
			"id": block_id,
			"districtId": settlement_id,
			"source": "regional-existing",
			"status": "active",
			"parcelIds": settlement_parcel_ids.duplicate(),
			"roadIds": settlement_road_ids.duplicate(),
		})
		districts.append({
			"id": settlement_id,
			"name": str(settlement.get("name", settlement_id)),
			"theme": "central" if str(settlement.get("tier", "")) == "capital" else "residential",
			"source": "regional-existing",
			"status": "active",
			"activatedAt": 0.0,
			"developmentLevel": 0.0,
			"roadIds": settlement_road_ids,
			"blockIds": [block_id],
			"parcelIds": settlement_parcel_ids,
			"population": int(settlement.get("population", 0)),
			"jobs": int(settlement.get("jobs", 0)),
		})
	return {
		"districts": districts,
		"blocks": blocks,
		"parcels": parcels,
		"buildings": buildings,
	}


static func _find_region_building(regional_plan: Dictionary, building_id: String) -> Dictionary:
	for building in regional_plan.get("building_anchors", []):
		if str(building.get("id", "")) == building_id:
			return building
	return {}

static func _append_regional_city_link(roads: Array, settlements: Array) -> void:
	if settlements.is_empty():
		return
	var hub_position: Vector2 = settlements[0].get("position", Vector2.ZERO)
	var best_position := Vector2.ZERO
	var best_distance := INF
	for road_value in roads:
		var road: Dictionary = road_value
		if str(road.get("source", "")) not in ["existing-arterial", "transport-corridor"]:
			continue
		var nearest := RoadTopology.closest_point_on_road(hub_position, road)
		if nearest.is_empty():
			continue
		var candidate: Vector2 = nearest["point"]
		var distance := float(nearest["distance"])
		if distance < best_distance:
			best_distance = distance
			best_position = candidate
	if best_distance <= 8.0 or best_distance == INF:
		return
	roads.append({
		"id": "regional-city-link",
		"districtId": "regional-settlements",
		"class": "collector",
		"points": [
			{"x": hub_position.x, "y": hub_position.y},
			{"x": best_position.x, "y": best_position.y},
		],
		"unlock": null,
		"buildOrder": -99,
		"source": "regional-existing",
		"parentRoadIds": [],
		"status": "built",
		"constructionProgress": 1.0,
		"level": 0.0,
		"profile": RoadProfile.base_profile("collector"),
		"regionalRole": "city_connector",
	})

static func _empty_service_networks() -> Dictionary:
	var networks: Dictionary = {}
	for utility_type in ["electricity", "water", "sewage"]:
		networks[utility_type] = {"sources": [], "edges": [], "consumers": []}
	return networks


static func _build_regional_services(
	settlements: Array,
	regional_edges: Array,
	external_connections: Array
) -> Dictionary:
	var networks := _empty_service_networks()
	var demand_points: Array[Dictionary] = []
	var facilities: Array[Dictionary] = []
	var total_population := 0.0
	var utility_feed_node := ""

	for connection in external_connections:
		if str(connection.get("kind", "")) == "utility":
			utility_feed_node = str(connection.get("id", ""))
			break

	for settlement in settlements:
		var settlement_id := str(settlement.get("id", ""))
		var population := maxf(0.0, float(settlement.get("population", 0)))
		var position: Vector2 = settlement.get("position", Vector2.ZERO)
		var tier := str(settlement.get("tier", "village"))
		total_population += population
		demand_points.append({
			"id": "demand-%s" % settlement_id,
			"districtId": settlement_id,
			"x": position.x,
			"y": position.y,
			"demands": {
				"healthcare": population * 0.10,
				"education": population * 0.16,
				"fire": population * 0.025,
				"police": population * 0.035,
				"waste": population * 0.85,
				"recreation": population * 0.35,
			},
		})
		var catchment := 620.0
		if tier == "capital":
			catchment = 2500.0
		elif tier == "market":
			catchment = 1450.0
		for service_type in CityServices.SERVICE_TYPES:
			var demand_ratio := _service_demand_ratio(service_type)
			facilities.append({
				"id": "%s-%s" % [service_type, settlement_id],
				"service": service_type,
				"x": position.x,
				"y": position.y,
				"catchmentRadius": catchment,
				"capacity": population * demand_ratio * REGIONAL_STARTER_SERVICE_CAPACITY_SHARE,
				"status": "operational",
				"source": "regional-existing",
				})

	var utility_edges: Array[Dictionary] = []
	for edge in regional_edges:
		var a := str(edge.get("a", ""))
		var b := str(edge.get("b", ""))
		if a.is_empty() or b.is_empty():
			continue
		var length := maxf(1.0, float(edge.get("length", 1.0)))
		var capacity := maxf(18000.0, 92000.0 - length * 2.0)
		if str(edge.get("class", "secondary")) == "primary":
			capacity *= 1.7
		utility_edges.append({
			"id": "utility-corridor-%s" % str(edge.get("id", utility_edges.size())),
			"a": a,
			"b": b,
			"capacity": capacity,
			"status": "operational",
		})

	if not utility_feed_node.is_empty():
		for utility_type in CityServices.UTILITY_TYPES:
			var consumers: Array[Dictionary] = []
			var demand_factor := 1.0
			if utility_type == "electricity":
				demand_factor = 2.0
			elif utility_type == "sewage":
				demand_factor = 0.9
			for settlement in settlements:
				consumers.append({
					"id": "%s-%s" % [utility_type, str(settlement.get("id", ""))],
					"nodeId": str(settlement.get("id", "")),
					"demand": maxf(0.0, float(settlement.get("population", 0))) * demand_factor,
					"status": "operational",
				})
			networks[utility_type] = {
				"sources": [{
					"id": "%s-regional-feed" % utility_type,
					"nodeId": utility_feed_node,
					"capacity": total_population * demand_factor * 1.12,
					"status": "operational",
				}],
				"edges": utility_edges.duplicate(true),
				"consumers": consumers,
			}

	var districts: Array[Dictionary] = []
	for settlement in settlements:
		districts.append({"id": str(settlement.get("id", ""))})
	var results := {
		"utilities": CityServices.evaluate_utility_networks(networks),
		"services": CityServices.evaluate_district_coverage(districts, demand_points, facilities),
	}
	return {
		"networks": networks,
		"buildings": facilities,
		"demand_points": demand_points,
		"results": results,
	}


static func _service_demand_ratio(service_type: String) -> float:
	match service_type:
		"healthcare":
			return 0.10
		"education":
			return 0.16
		"fire":
			return 0.025
		"police":
			return 0.035
		"waste":
			return 0.85
		"recreation":
			return 0.35
	return 0.0

static func ensure_city(store: Node) -> void:
	var raw_world_map: Variant = store.get("world_map")
	var world_map: Dictionary = raw_world_map if typeof(raw_world_map) == TYPE_DICTIONARY else {}
	var map_id := str(world_map.get("id", MapDefinition.LEGACY_CITY_MAP_ID))
	if typeof(store.city) != TYPE_DICTIONARY or int(store.city.get("version", 0)) != CITY_VERSION:
		store.city = create_initial_city(store.city_seed, map_id)

	if not store.city.has("buildings"):
		store.city["buildings"] = []
	if not store.city.has("projects"):
		store.city["projects"] = []
	if not store.city.has("runtime_accumulator_seconds"):
		store.city["runtime_accumulator_seconds"] = 0.0
	if not store.city.has("time_seconds"):
		store.city["time_seconds"] = 0.0
	if not store.city.has("next_project_id"):
		store.city["next_project_id"] = 1
	if not store.city.has("regional_growth_accumulator_seconds"):
		store.city["regional_growth_accumulator_seconds"] = 0.0
	if not store.city.has("regional_growth_ticks"):
		store.city["regional_growth_ticks"] = 0
	if not store.city.has("regional_auto_growth_count"):
		store.city["regional_auto_growth_count"] = 0
	if not store.city.has("world_map_id"):
		store.city["world_map_id"] = map_id
	if not store.city.has("world_seed"):
		store.city["world_seed"] = int(world_map.get("seed", store.city.get("seed", Data.DEFAULT_CITY_SEED)))
	if not store.city.has("generator_version"):
		store.city["generator_version"] = int(world_map.get("generator_version", MapDefinition.GENERATOR_VERSION))
	if _is_regional_sandbox(store.city):
		_refresh_regional_demographics(store.city)

static func sync_with_transport(store: Node) -> bool:
	ensure_city(store)
	var changed := false

	for district in store.city["districts"]:
		if str(district.get("status", "locked")) == "locked" and _district_should_be_active(store, district):
			district["status"] = "active"
			district["activatedAt"] = float(store.city["time_seconds"])
			_activate_blocks(store.city, district)
			_schedule_road_projects(store.city, district)
			changed = true

	for road in store.city["roads"]:
		var source := str(road.get("source", ""))
		# Primary streets are city infrastructure, not transit unlocks. Keeping
		# the arterial/corridor skeleton available lets player-designed routes
		# reach future districts without buying a scripted bus line first.
		if source in ["existing-arterial", "transport-corridor"]:
			if str(road.get("status", "")) != "built":
				road["status"] = "built"
				road["constructionProgress"] = 1.0
				changed = true
			continue

		if source != "depot-access":
			continue

		if _transport_unlock_satisfied(store, road.get("unlock", null)) and _road_dependencies_built(store.city, road):
			if str(road.get("status", "")) != "built":
				road["status"] = "built"
				road["constructionProgress"] = 1.0
				changed = true

	return changed

static func advance(store: Node, delta_seconds: float) -> bool:
	if delta_seconds <= 0.0:
		return false

	ensure_city(store)
	store.city["time_seconds"] = float(store.city["time_seconds"]) + delta_seconds
	store.city["runtime_accumulator_seconds"] = float(store.city["runtime_accumulator_seconds"]) + delta_seconds

	var changed := sync_with_transport(store)
	if _is_regional_sandbox(store.city):
		changed = _advance_regional_growth(store, delta_seconds) or changed
	var guard := 0

	while float(store.city["runtime_accumulator_seconds"]) >= STEP_SECONDS and guard < 8:
		guard += 1
		changed = _progress_active_projects(store.city, STEP_SECONDS) or changed
		changed = _queue_development_projects(store) or changed
		changed = _start_eligible_projects(store.city) or changed
		_update_development_levels(store)
		store.city["runtime_accumulator_seconds"] = float(store.city["runtime_accumulator_seconds"]) - STEP_SECONDS

	return changed


static func _is_regional_sandbox(city: Dictionary) -> bool:
	return str(city.get("world_map_id", MapDefinition.LEGACY_CITY_MAP_ID)) != MapDefinition.LEGACY_CITY_MAP_ID


static func _advance_regional_growth(store: Node, delta_seconds: float) -> bool:
	var city: Dictionary = store.city
	var accumulator := float(city.get("regional_growth_accumulator_seconds", 0.0)) + delta_seconds
	var tick_count := int(city.get("regional_growth_ticks", 0))
	var grown_count := int(city.get("regional_auto_growth_count", 0))
	var changed := false
	while accumulator >= REGIONAL_GROWTH_INTERVAL_SECONDS:
		if grown_count >= MAX_REGIONAL_AUTONOMOUS_BUILDINGS:
			accumulator = 0.0
			break
		var parcel := _next_regional_growth_candidate(store)
		if parcel.is_empty():
			# Avoid storing up unproductive time while every site is disconnected.
			accumulator = 0.0
			break
		accumulator -= REGIONAL_GROWTH_INTERVAL_SECONDS
		tick_count += 1
		grown_count += 1
		var growth_time := float(city["time_seconds"]) - accumulator
		_grow_regional_parcel(store, parcel, tick_count, growth_time)
		changed = true
	city["regional_growth_accumulator_seconds"] = accumulator
	city["regional_growth_ticks"] = tick_count
	city["regional_auto_growth_count"] = grown_count
	return changed


static func _next_regional_growth_candidate(store: Node) -> Dictionary:
	var city: Dictionary = store.city
	var candidates: Array[Dictionary] = []
	var transit_network: Dictionary = store.transit_network if typeof(store.transit_network) == TYPE_DICTIONARY else {}
	var health_by_district: Dictionary = {}
	if store.has_method("resident_health_metrics"):
		var health: Dictionary = store.call("resident_health_metrics")
		health_by_district = health.get("districts", {})
	for parcel_value in city.get("parcels", []):
		var parcel: Dictionary = parcel_value
		if str(parcel.get("status", "")) != "vacant":
			continue
		if not _regional_parcel_has_strategic_access(city, parcel):
			continue
		var position := Vector2(float(parcel.get("x", 0.0)), float(parcel.get("y", 0.0)))
		var transit_bonus := TransitNetwork.stop_accessibility_score(transit_network, position, 520.0)
		var district_health: Dictionary = health_by_district.get(str(parcel.get("districtId", "")), {})
		var health_bonus := clampf(float(district_health.get("health_index", 50.0)), 0.0, 100.0) * REGIONAL_HEALTH_ATTRACTIVENESS_WEIGHT
		candidates.append({
			"parcel": parcel,
			"score": transit_bonus * REGIONAL_TRANSIT_ACCESS_PRIORITY_WEIGHT + health_bonus - float(parcel.get("growthOrder", parcel.get("developmentOrder", 0.0))),
		})
	candidates.sort_custom(func(a, b):
		var a_score := float(a.get("score", 0.0))
		var b_score := float(b.get("score", 0.0))
		if not is_equal_approx(a_score, b_score):
			return a_score > b_score
		return str(a.get("parcel", {}).get("id", "")) < str(b.get("parcel", {}).get("id", ""))
	)
	return candidates[0].get("parcel", {}) if not candidates.is_empty() else {}


static func _regional_parcel_has_strategic_access(city: Dictionary, parcel: Dictionary) -> bool:
	var frontage_id := str(parcel.get("frontageRoadId", ""))
	var frontage: Variant = _find_by_id(city.get("roads", []), frontage_id)
	if frontage == null or str(frontage.get("status", "")) != "built":
		return false

	var start_nodes: Array[String] = []
	for node_value in [
		str(frontage.get("a", "")),
		str(frontage.get("b", "")),
		str(frontage.get("settlementId", frontage.get("districtId", ""))),
	]:
		if not node_value.is_empty() and not start_nodes.has(node_value):
			start_nodes.append(node_value)
	if start_nodes.is_empty():
		return false

	var adjacency: Dictionary = {}
	var strategic_nodes: Dictionary = {}
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("status", "")) != "built":
			continue
		var a := str(road.get("a", ""))
		var b := str(road.get("b", ""))
		if a.is_empty() or b.is_empty():
			continue
		if not adjacency.has(a):
			adjacency[a] = []
		if not adjacency.has(b):
			adjacency[b] = []
		adjacency[a].append(b)
		adjacency[b].append(a)
		if _is_completed_strategic_road(road):
			strategic_nodes[a] = true
			strategic_nodes[b] = true

	var visited: Dictionary = {}
	var queue: Array[String] = start_nodes.duplicate()
	while not queue.is_empty():
		var current: String = queue.pop_front()
		if visited.has(current):
			continue
		visited[current] = true
		if strategic_nodes.has(current):
			return true
		for neighbor_value in adjacency.get(current, []):
			var neighbor := str(neighbor_value)
			if not visited.has(neighbor):
				queue.append(neighbor)
	return false


static func _is_completed_strategic_road(road: Dictionary) -> bool:
	if str(road.get("status", "")) != "built":
		return false
	if str(road.get("regionalRole", "")) in ["spine", "loop", "external_branch", "city_connector"]:
		return true
	return str(road.get("class", "")) in ["collector", "arterial"] and str(road.get("source", "")) in [
		"city", "player", "regional-existing", "regional-capacity",
	]


static func _grow_regional_parcel(store: Node, parcel: Dictionary, growth_tick: int, growth_time: float) -> void:
	var city: Dictionary = store.city
	var district: Variant = _find_by_id(city.get("districts", []), str(parcel.get("districtId", "")))
	var profile := _building_profile(district if district != null else {}, parcel, _district_pressure(store, district) if district != null else 0.6)
	var parcel_id := str(parcel.get("id", ""))
	var building_id := "building-%s" % parcel_id
	var contribution := _regional_growth_contribution(parcel, profile)
	var residents_added := int(contribution.get("residents", 0))
	var jobs_added := int(contribution.get("jobs", 0))
	parcel["source"] = "city"
	parcel["status"] = "built"
	parcel["buildingId"] = building_id
	parcel["growthTick"] = growth_tick
	parcel["completedAt"] = growth_time
	parcel["residentsAdded"] = residents_added
	parcel["jobsAdded"] = jobs_added
	var settlement_id := str(parcel.get("districtId", ""))
	var settlement: Variant = _find_by_id(city.get("regional_settlements", []), settlement_id)
	if settlement != null:
		settlement["population"] = maxf(0.0, float(settlement.get("population", 0.0))) + residents_added
		settlement["jobs"] = maxi(0, int(settlement.get("jobs", 0))) + jobs_added
	if district != null:
		district["population"] = maxi(0, int(district.get("population", 0))) + residents_added
		district["jobs"] = maxi(0, int(district.get("jobs", 0))) + jobs_added
	_refresh_regional_demographics(city)
	var building := {
		"id": building_id,
		"districtId": str(parcel.get("districtId", "")),
		"parcelId": parcel_id,
		"x": float(parcel.get("x", 0.0)),
		"y": float(parcel.get("y", 0.0)),
		"zone": str(parcel.get("zone", "residential")),
		"profile": profile,
		"rotationRadians": _parcel_frontage_angle(city, parcel),
		"source": "city",
		"status": "built",
		"residentsAdded": residents_added,
		"jobsAdded": jobs_added,
		"constructionProgress": 1.0,
		"growthTick": growth_tick,
		"createdAt": growth_time,
		"completedAt": growth_time,
	}
	city["buildings"].append(building)
	city["projects"].append({
		"id": _next_project_id(city),
		"type": "building",
		"targetType": "parcel",
		"targetId": parcel_id,
		"districtId": str(parcel.get("districtId", "")),
		"source": "city",
		"status": "complete",
		"queuedAt": growth_time,
		"eligibleAt": growth_time,
		"startedAt": growth_time,
		"completedAt": growth_time,
		"duration": _building_duration(profile),
		"progress": 1.0,
		"profile": profile.duplicate(true),
		"residentsAdded": residents_added,
		"jobsAdded": jobs_added,
		"growthTick": growth_tick,
	})


static func _regional_growth_contribution(parcel: Dictionary, profile: Dictionary) -> Dictionary:
	var density := clampi(int(profile.get("density", parcel.get("density", 1))), 1, 4)
	match str(parcel.get("zone", "residential")):
		"residential":
			return {"residents": REGIONAL_RESIDENTS_PER_DENSITY * density, "jobs": 0}
		"commercial", "industrial", "civic":
			return {"residents": 0, "jobs": REGIONAL_JOBS_PER_DENSITY * density}
		"mixed":
			return {
				"residents": REGIONAL_MIXED_RESIDENTS_PER_DENSITY * density,
				"jobs": REGIONAL_MIXED_JOBS_PER_DENSITY * density,
			}
	return {"residents": 0, "jobs": 0}


static func _refresh_regional_demographics(city: Dictionary) -> void:
	var resident_stock := 0.0
	var jobs := 0
	var population_by_settlement: Dictionary = {}
	for settlement_value in city.get("regional_settlements", []):
		var settlement: Dictionary = settlement_value
		var population := maxf(0.0, float(settlement.get("population", 0.0)))
		if not settlement.has("jobs"):
			settlement["jobs"] = int(round(population * 0.43))
		resident_stock += population
		population_by_settlement[str(settlement.get("id", ""))] = population
		jobs += maxi(0, int(settlement.get("jobs", 0)))
	var residents := maxi(0, roundi(resident_stock))
	var students_stock := resident_stock * 0.16
	var health_state: Dictionary = city.get("resident_health_state", {})
	var health_districts: Dictionary = health_state.get("districts", {})
	if int(health_state.get("schema_version", 0)) >= 2:
		var children := 0.0
		for district_id in health_districts:
			var health_district: Dictionary = health_districts[district_id]
			for cohort_value in health_district.get("cohorts", {}).values():
				var cohort: Dictionary = cohort_value
				if str(cohort.get("age_group", "")) == "children":
					children += maxf(0.0, float(cohort.get("population", 0.0)))
		students_stock = children
	for district_value in city.get("districts", []):
		if typeof(district_value) != TYPE_DICTIONARY:
			continue
		var district: Dictionary = district_value
		var settlement_id := str(district.get("settlementId", district.get("settlement_id", "")))
		if population_by_settlement.has(settlement_id):
			district["population"] = roundi(float(population_by_settlement[settlement_id]))
	var demographics: Dictionary = city.get("demographics", {}).duplicate(true)
	demographics["residents"] = residents
	demographics["jobs"] = jobs
	demographics["students"] = maxi(0, roundi(students_stock))
	city["demographics"] = demographics

static func _transport_unlock_satisfied(store: Node, unlock) -> bool:
	if unlock == null:
		return true
	if typeof(unlock) != TYPE_DICTIONARY:
		return true

	if bool(unlock.get("requiresDepot", false)) and not bool(store.depot.get("built", false)):
		return false

	if unlock.has("districtId"):
		var district: Variant = _find_by_id(store.city["districts"], str(unlock["districtId"]))
		return district != null and str(district.get("status", "")) == "active"

	var line_key := str(unlock.get("lineKey", ""))
	if not store.lines.has(line_key):
		return false

	var line: Dictionary = store.lines[line_key]
	if line_key != "line1" and not bool(line.get("built", false)):
		return false

	return int(line.get("stop_count", 0)) >= int(unlock.get("stopCount", 0))

static func _district_should_be_active(store: Node, district: Dictionary) -> bool:
	var line_key := str(district.get("lineKey", "line1"))
	if store.lines.has(line_key):
		var line: Dictionary = store.lines[line_key]
		var legacy_active := (
			(line_key == "line1" or bool(line.get("built", false)))
			and int(line.get("stop_count", 0)) > int(district.get("stopIndex", 0))
		)
		if legacy_active:
			return true

	if typeof(store.transit_network) == TYPE_DICTIONARY:
		var center := _district_center(store.city, district)
		var accessibility := TransitNetwork.stop_accessibility_score(
			store.transit_network,
			center,
			440.0
		)
		if accessibility >= 0.28:
			return true

	return false

static func _activate_blocks(city: Dictionary, district: Dictionary) -> void:
	for block_id in district.get("blockIds", []):
		var block: Variant = _find_by_id(city["blocks"], str(block_id))
		if block != null:
			block["status"] = "active"

static func _district_pressure(store: Node, district: Dictionary) -> float:
	var line_key := str(district.get("lineKey", "line1"))
	var line: Dictionary = store.lines.get(line_key, store.lines["line1"])
	var age: float = maxf(0.0, float(store.city["time_seconds"]) - float(district.get("activatedAt", 0.0)))
	var age_score: float = minf(3.5, age / 40.0)
	var stop_score: float = float(maxi(0, int(line.get("stop_count", 0)) - 1)) * 0.35
	var ridership_score: float = minf(2.5, float(line.get("last_delivered_ppm", 0.0)) / 8.0)
	var fleet_score: float = minf(1.5, float(line.get("fleet_count", 0)) * 0.25)
	var interchange_bonus := 1.2 if str(district.get("id", "")) == "park" and bool(store.lines["line2"].get("built", false)) else 0.0
	var central_bonus := 0.8 if str(district.get("theme", "")) == "central" else 0.0
	var accessibility_bonus := 0.0
	if typeof(store.transit_network) == TYPE_DICTIONARY:
		var center := _district_center(store.city, district)
		accessibility_bonus = minf(
			2.6,
			TransitNetwork.stop_accessibility_score(
				store.transit_network,
				center,
				440.0
			) * 0.52
		)
	return (
		0.6
		+ age_score
		+ stop_score
		+ ridership_score
		+ fleet_score
		+ interchange_bonus
		+ central_bonus
		+ accessibility_bonus
	)

static func _district_center(city: Dictionary, district: Dictionary) -> Vector2:
	var parcel_ids: Array = district.get("parcelIds", [])
	var wanted: Dictionary = {}
	for parcel_id_value in parcel_ids:
		wanted[str(parcel_id_value)] = true
	var total := Vector2.ZERO
	var count := 0
	for parcel_value in city.get("parcels", []):
		var parcel: Dictionary = parcel_value
		if not wanted.has(str(parcel.get("id", ""))):
			continue
		total += Vector2(
			float(parcel.get("x", 0.0)),
			float(parcel.get("y", 0.0))
		)
		count += 1
	if count > 0:
		return total / float(count)

	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("districtId", "")) != str(district.get("id", "")):
			continue
		var points: Array = road.get("points", [])
		if not points.is_empty():
			var point: Dictionary = points[0]
			return Vector2(
				float(point.get("x", 0.0)),
				float(point.get("y", 0.0))
			)
	return Vector2.ZERO

static func _road_length(road: Dictionary) -> float:
	var points: Array = road.get("points", [])
	var total := 0.0
	for index in range(points.size() - 1):
		var a: Dictionary = points[index]
		var b: Dictionary = points[index + 1]
		total += Vector2(float(a["x"]), float(a["y"])).distance_to(Vector2(float(b["x"]), float(b["y"])))
	return total

static func _road_project_duration(road: Dictionary) -> float:
	var length := _road_length(road)
	match str(road.get("class", "local")):
		"service":
			return 6.0 + length / 38.0
		"arterial":
			return 8.0 + length / 32.0
		"collector":
			return 7.0 + length / 29.0
		_:
			return 6.0 + length / 26.0

static func _road_dependencies_built(city: Dictionary, road: Dictionary) -> bool:
	for parent_id in road.get("parentRoadIds", []):
		var parent: Variant = _find_by_id(city["roads"], str(parent_id))
		if parent == null or str(parent.get("status", "")) != "built":
			return false
	return true

static func _next_project_id(city: Dictionary) -> String:
	var value := int(city["next_project_id"])
	city["next_project_id"] = value + 1
	return "project-%d" % value

static func _schedule_road_projects(city: Dictionary, district: Dictionary) -> void:
	var roads: Array = []
	for road in city["roads"]:
		if (
			str(road.get("districtId", "")) == str(district.get("id", ""))
			and str(road.get("source", "")) == "city"
			and str(road.get("status", "")) == "planned"
		):
			roads.append(road)

	roads.sort_custom(func(a, b): return int(a.get("buildOrder", 0)) < int(b.get("buildOrder", 0)))

	for index in range(roads.size()):
		var road: Dictionary = roads[index]
		var exists := false
		for project in city["projects"]:
			if str(project.get("targetType", "")) == "road" and str(project.get("targetId", "")) == str(road["id"]):
				exists = true
				break
		if exists:
			continue

		city["projects"].append({
			"id": _next_project_id(city),
			"type": "road",
			"targetType": "road",
			"targetId": road["id"],
			"districtId": district["id"],
			"status": "queued",
			"queuedAt": float(city["time_seconds"]),
			"eligibleAt": float(city["time_seconds"]) + 5.0 + float(index) * 8.0,
			"startedAt": null,
			"duration": _road_project_duration(road),
			"progress": 0.0,
		})

static func _queue_development_projects(store: Node) -> bool:
	if _is_regional_sandbox(store.city):
		return false
	var changed := false
	for district in store.city["districts"]:
		if str(district.get("status", "")) != "active":
			continue
		changed = _maybe_queue_building(store, district) or changed
	return changed

static func _maybe_queue_building(store: Node, district: Dictionary) -> bool:
	for project in store.city["projects"]:
		if (
			str(project.get("districtId", "")) == str(district["id"])
			and str(project.get("type", "")) == "building"
			and str(project.get("status", "")) in ["queued", "active"]
		):
			return false

	var pressure := _district_pressure(store, district)
	var age: float = maxf(0.0, float(store.city["time_seconds"]) - float(district.get("activatedAt", 0.0)))
	var parcels: Array = []

	for parcel in store.city["parcels"]:
		if (
			str(parcel.get("districtId", "")) == str(district["id"])
			and str(parcel.get("status", "")) == "vacant"
			and _parcel_has_road_support(store.city, parcel)
		):
			parcels.append(parcel)

	parcels.sort_custom(func(a, b): return float(a.get("developmentOrder", 0.0)) < float(b.get("developmentOrder", 0.0)))

	for index in range(parcels.size()):
		var parcel: Dictionary = parcels[index]
		var minimum_age := 12.0 + float(index) * 9.0 + float(parcel.get("developmentOrder", 0.0)) * 8.0
		var required_pressure := 1.2 + float(index) * 0.38 + float(parcel.get("density", 1)) * 0.18
		if age < minimum_age or pressure < required_pressure:
			continue

		var profile := _building_profile(district, parcel, pressure)
		parcel["status"] = "reserved"
		parcel["reservedAt"] = float(store.city["time_seconds"])
		store.city["projects"].append({
			"id": _next_project_id(store.city),
			"type": "building",
			"targetType": "parcel",
			"targetId": parcel["id"],
			"districtId": district["id"],
			"status": "queued",
			"queuedAt": float(store.city["time_seconds"]),
			"eligibleAt": float(store.city["time_seconds"]) + 2.0,
			"startedAt": null,
			"duration": _building_duration(profile),
			"progress": 0.0,
			"profile": profile,
		})
		return true

	return false

static func _parcel_has_road_support(city: Dictionary, parcel: Dictionary) -> bool:
	var frontage := str(parcel.get("frontageRoadId", ""))
	if frontage.is_empty():
		return false
	var road: Variant = _find_by_id(city["roads"], frontage)
	return road != null and str(road.get("status", "")) == "built"

static func _building_profile(district: Dictionary, parcel: Dictionary, pressure: float) -> Dictionary:
	var density := clampi(
		int(parcel.get("density", 1))
		+ floori(max(0.0, pressure - 3.8) / 2.2),
		1,
		4
	)
	var zone := str(parcel.get("zone", "residential"))
	var theme := str(district.get("theme", ""))

	if zone == "industrial":
		var kind := "warehouse" if density >= 3 else "workshop"
		return _make_profile(kind, 2 if density >= 3 else 1, density)

	if zone == "civic":
		return _make_profile("campus" if theme == "campus" else "civic", 4 if density >= 3 else 3, density)

	if zone == "commercial":
		if theme == "central" and density >= 4:
			return _make_profile("tower", 8 + mini(4, density), density)
		return _make_profile("midrise" if density >= 3 else "shop", 4 + density if density >= 3 else 1, density)

	if zone == "mixed":
		if theme == "central" and density >= 4:
			return _make_profile("tower", 9, density)
		if density >= 3:
			return _make_profile("midrise", 4 + density, density)
		return _make_profile("shop", 2, density)

	if density >= 3:
		return _make_profile("apartment", 3 + density, density)
	if density >= 2:
		return _make_profile("townhouse", 2, density)
	return _make_profile("house", 1, density)

static func _make_profile(kind: String, floors: int, density: int) -> Dictionary:
	return {
		"kind": kind,
		"floors": floors,
		"density": density,
		"heightMeters": _profile_height(kind, floors),
	}

static func _profile_height(kind: String, floors: int) -> float:
	match kind:
		"house":
			return 7.5
		"townhouse":
			return 9.0
		"shop":
			return 6.5
		"workshop":
			return 8.0
		"warehouse":
			return 11.0
	var floor_height := 3.7 if kind == "tower" else (3.6 if kind in ["civic", "campus"] else 3.25)
	return float(floors) * floor_height + 1.5

static func _building_duration(profile: Dictionary) -> float:
	match str(profile.get("kind", "")):
		"tower":
			return 48.0
		"midrise", "campus", "civic":
			return 32.0
		"apartment", "warehouse":
			return 24.0
		_:
			return 15.0

static func _active_project_count(city: Dictionary) -> int:
	var count := 0
	for project in city["projects"]:
		if str(project.get("status", "")) == "active":
			count += 1
	return count

static func _project_can_start(city: Dictionary, project: Dictionary) -> bool:
	if str(project.get("type", "")) != "road":
		return true
	var road: Variant = _find_by_id(city["roads"], str(project.get("targetId", "")))
	return road != null and _road_dependencies_built(city, road)

static func _start_eligible_projects(city: Dictionary) -> bool:
	var free_slots := MAX_ACTIVE_PROJECTS - _active_project_count(city)
	if free_slots <= 0:
		return false

	var eligible: Array = []
	for project in city["projects"]:
		if (
			str(project.get("status", "")) == "queued"
			and float(project.get("eligibleAt", 0.0)) <= float(city["time_seconds"])
			and _project_can_start(city, project)
		):
			eligible.append(project)

	eligible.sort_custom(func(a, b):
		var a_type := str(a.get("type", ""))
		var b_type := str(b.get("type", ""))
		if a_type != b_type:
			return a_type == "road"
		return float(a.get("eligibleAt", 0.0)) < float(b.get("eligibleAt", 0.0))
	)

	var changed := false
	for project in eligible:
		if free_slots <= 0:
			break

		project["status"] = "active"
		project["startedAt"] = float(city["time_seconds"])
		free_slots -= 1
		changed = true

		if str(project["type"]) == "road":
			var road: Variant = _find_by_id(city["roads"], str(project["targetId"]))
			if road != null:
				road["status"] = "constructing"
		else:
			var parcel: Variant = _find_by_id(city["parcels"], str(project["targetId"]))
			if parcel != null:
				var building_id := "building-%s" % str(parcel["id"])
				parcel["buildingId"] = building_id
				parcel["status"] = "constructing"
				city["buildings"].append({
					"id": building_id,
					"districtId": project["districtId"],
					"parcelId": parcel["id"],
					"x": parcel["x"],
					"y": parcel["y"],
					"zone": parcel["zone"],
					"profile": project["profile"].duplicate(true),
					"rotationRadians": _parcel_frontage_angle(city, parcel),
					"status": "constructing",
					"constructionProgress": 0.0,
					"createdAt": float(city["time_seconds"]),
					"completedAt": null,
				})

	return changed

static func _progress_active_projects(city: Dictionary, delta_seconds: float) -> bool:
	var changed := false

	for project in city["projects"]:
		if str(project.get("status", "")) != "active":
			continue

		var progress: float = clampf(
			float(project.get("progress", 0.0))
			+ delta_seconds / max(0.01, float(project.get("duration", 1.0))),
			0.0,
			1.0
		)
		project["progress"] = progress
		changed = true

		if str(project["type"]) == "road":
			var road: Variant = _find_by_id(city["roads"], str(project["targetId"]))
			if road != null:
				road["constructionProgress"] = progress
		else:
			var building: Variant = _find_building_by_parcel(city, str(project["targetId"]))
			if building != null:
				building["constructionProgress"] = progress

		if progress >= 1.0:
			_finish_project(city, project)

	return changed

static func _finish_project(city: Dictionary, project: Dictionary) -> void:
	project["status"] = "complete"
	project["progress"] = 1.0
	project["completedAt"] = float(city["time_seconds"])

	if str(project["type"]) == "road":
		var road: Variant = _find_by_id(city["roads"], str(project["targetId"]))
		if road != null:
			road["status"] = "built"
			road["constructionProgress"] = 1.0
		return

	var parcel: Variant = _find_by_id(city["parcels"], str(project["targetId"]))
	if parcel != null:
		parcel["status"] = "built"

	var building: Variant = _find_building_by_parcel(city, str(project["targetId"]))
	if building != null:
		building["status"] = "built"
		building["constructionProgress"] = 1.0
		building["completedAt"] = float(city["time_seconds"])

static func _update_development_levels(store: Node) -> void:
	for district in store.city["districts"]:
		var parcel_ids: Array = district.get("parcelIds", [])
		if parcel_ids.is_empty():
			district["developmentLevel"] = 0.0
			continue

		var built := 0
		for parcel in store.city["parcels"]:
			if str(parcel.get("districtId", "")) == str(district["id"]) and str(parcel.get("status", "")) == "built":
				built += 1
		district["developmentLevel"] = float(built) / float(parcel_ids.size())

static func _parcel_frontage_angle(city: Dictionary, parcel: Dictionary) -> float:
	var road: Variant = _find_by_id(city["roads"], str(parcel.get("frontageRoadId", "")))
	if road == null:
		return 0.0

	var points: Array = road.get("points", [])
	if points.size() < 2:
		return 0.0

	var best_distance := INF
	var best_angle := 0.0
	var parcel_point := Vector2(float(parcel["x"]), float(parcel["y"]))

	for index in range(points.size() - 1):
		var a_dict: Dictionary = points[index]
		var b_dict: Dictionary = points[index + 1]
		var a := Vector2(float(a_dict["x"]), float(a_dict["y"]))
		var b := Vector2(float(b_dict["x"]), float(b_dict["y"]))
		var ab := b - a
		var length_sq := ab.length_squared()
		if length_sq <= 0.000000001:
			continue
		var t: float = clampf((parcel_point - a).dot(ab) / length_sq, 0.0, 1.0)
		var projected: Vector2 = a + ab * t
		var distance := parcel_point.distance_to(projected)
		if distance < best_distance:
			best_distance = distance
			best_angle = atan2(ab.y, ab.x)

	return best_angle

static func _find_by_id(items: Array, id: String):
	for item in items:
		if str(item.get("id", "")) == id:
			return item
	return null

static func _find_building_by_parcel(city: Dictionary, parcel_id: String):
	for building in city["buildings"]:
		if str(building.get("parcelId", "")) == parcel_id:
			return building
	return null
