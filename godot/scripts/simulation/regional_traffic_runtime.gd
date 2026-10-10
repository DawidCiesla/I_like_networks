extends RefCounted
class_name RegionalTrafficRuntime

const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const RoadTrafficModel = preload("res://scripts/simulation/road_traffic_model.gd")
const RoadTrafficSummary = preload("res://scripts/simulation/road_traffic_summary.gd")

const TICK_SECONDS := 30.0
const AVERAGE_CAR_OCCUPANCY := 1.25
const ASSIGNMENT_ITERATIONS := 4
const MIN_OPERATIONAL_SPEED_KPH := 5.0
const EPSILON := 0.000001
const SCHEMA_VERSION := 1


static func ensure(city: Dictionary) -> void:
	if not _is_regional_city(city):
		return
	if not city.has("road_traffic") or typeof(city.get("road_traffic")) != TYPE_DICTIONARY:
		city["road_traffic"] = _empty_state()


static func advance(store: Node, delta_seconds: float) -> bool:
	if delta_seconds <= 0.0 or not _is_regional_city(store.city):
		return false
	ensure(store.city)
	var state: Dictionary = store.city.get("road_traffic", {})
	var accumulator := float(state.get("accumulator_seconds", 0.0)) + delta_seconds
	if accumulator < TICK_SECONDS:
		state["accumulator_seconds"] = accumulator
		store.city["road_traffic"] = state
		return false
	while accumulator >= TICK_SECONDS:
		accumulator -= TICK_SECONDS
	state["accumulator_seconds"] = accumulator
	store.city["road_traffic"] = state
	return refresh(store)


static func refresh(store: Node) -> bool:
	if not _is_regional_city(store.city):
		return false
	ensure(store.city)
	var previous: Dictionary = store.city.get("road_traffic", {})

	# ResidentTravelChoice reads road.profile.speed_kph. At this point profiles
	# intentionally still carry the operational speeds from the previous traffic
	# snapshot, so the mode-choice pass feels the congestion it created.
	var resident_metrics: Dictionary = {}
	if store.has_method("resident_transport_metrics"):
		var metrics_value: Variant = store.call("resident_transport_metrics")
		if typeof(metrics_value) == TYPE_DICTIONARY:
			resident_metrics = metrics_value

	var demand_state := _demands_from_resident_metrics(store.city, resident_metrics)
	var demands: Array = demand_state.get("demands", [])

	# The assignment model must always start from physical/free-flow road speeds;
	# otherwise BPR delay would compound every traffic tick. Design speeds are
	# preserved separately before operational speeds are exposed to GameStore.
	_restore_free_flow_speeds(store.city)
	var assignment := RoadTrafficModel.evaluate(
		store.city,
		demands,
		{"iterations": ASSIGNMENT_ITERATIONS}
	)
	var summary := RoadTrafficSummary.summarize(assignment)
	var signature := _snapshot_signature(demand_state, assignment, summary)
	var previous_signature := str(previous.get("signature", ""))
	var revision := int(previous.get("revision", 0))
	var changed := signature != previous_signature
	if changed:
		revision += 1

	var snapshot := {
		"schema_version": SCHEMA_VERSION,
		"accumulator_seconds": float(previous.get("accumulator_seconds", 0.0)),
		"revision": revision,
		"signature": signature,
		"average_car_occupancy": AVERAGE_CAR_OCCUPANCY,
		"demand": demand_state.get("totals", {}).duplicate(true),
		"edge_metrics": assignment.get("edge_metrics", {}).duplicate(true),
		"road_metrics": assignment.get("road_metrics", {}).duplicate(true),
		"od_results": assignment.get("od_results", []).duplicate(true),
		"summary": summary.duplicate(true),
	}
	store.city["road_traffic"] = snapshot
	_apply_road_metrics(store.city, snapshot.get("road_metrics", {}))
	return changed


static func _demands_from_resident_metrics(city: Dictionary, metrics: Dictionary) -> Dictionary:
	var node_lookup := _node_lookup(city)
	var settlement_lookup := _settlement_lookup(city)
	var demands: Array[Dictionary] = []
	var passenger_car_trips_per_hour := 0.0
	var vehicle_trips_per_hour := 0.0
	var unresolved_od_pairs := 0
	var diagnostics_value: Variant = metrics.get("od_diagnostics", [])
	if typeof(diagnostics_value) != TYPE_ARRAY:
		diagnostics_value = []
	for diagnostic_value in diagnostics_value:
		if typeof(diagnostic_value) != TYPE_DICTIONARY:
			continue
		var diagnostic: Dictionary = diagnostic_value
		var passenger_flow := maxf(0.0, float(diagnostic.get("car_trips_per_hour", 0.0)))
		if passenger_flow <= EPSILON:
			continue
		passenger_car_trips_per_hour += passenger_flow
		var origin_id := str(diagnostic.get("origin_id", ""))
		var destination_id := str(diagnostic.get("destination_id", ""))
		var origin_node := _resolve_graph_node(origin_id, node_lookup, settlement_lookup)
		var destination_node := _resolve_graph_node(destination_id, node_lookup, settlement_lookup)
		if origin_node.is_empty() or destination_node.is_empty() or origin_node == destination_node:
			unresolved_od_pairs += 1
			continue
		var vehicle_flow := passenger_flow / AVERAGE_CAR_OCCUPANCY
		vehicle_trips_per_hour += vehicle_flow
		demands.append({
			"id": "resident-car:%s:%s" % [origin_id, destination_id],
			"origin_node": origin_node,
			"destination_node": destination_node,
			"vehicle_trips_per_hour": vehicle_flow,
			"passenger_car_trips_per_hour": passenger_flow,
			"origin_settlement_id": origin_id,
			"destination_settlement_id": destination_id,
		})
	return {
		"demands": demands,
		"totals": {
			"od_pairs": demands.size(),
			"unresolved_od_pairs": unresolved_od_pairs,
			"passenger_car_trips_per_hour": passenger_car_trips_per_hour,
			"vehicle_trips_per_hour": vehicle_trips_per_hour,
		},
	}


static func _resolve_graph_node(
	settlement_id: String,
	node_lookup: Dictionary,
	settlement_lookup: Dictionary
) -> String:
	if settlement_id.is_empty():
		return ""
	if node_lookup.has(settlement_id):
		return settlement_id
	if not settlement_lookup.has(settlement_id):
		return ""
	var settlement: Dictionary = settlement_lookup[settlement_id]
	var position: Vector2 = settlement.get("position", Vector2.ZERO)
	var best_id := ""
	var best_distance := INF
	for node_id_value in node_lookup.keys():
		var node_id := str(node_id_value)
		var distance := position.distance_squared_to(node_lookup[node_id])
		if distance < best_distance:
			best_distance = distance
			best_id = node_id
	return best_id


static func _restore_free_flow_speeds(city: Dictionary) -> void:
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		var profile_value: Variant = road.get("profile", {})
		if typeof(profile_value) != TYPE_DICTIONARY or (profile_value as Dictionary).is_empty():
			continue
		var profile: Dictionary = profile_value
		if not road.has("traffic_free_flow_speed_kph"):
			road["traffic_free_flow_speed_kph"] = maxf(
				MIN_OPERATIONAL_SPEED_KPH,
				float(profile.get("speed_kph", 30.0))
			)
		profile["speed_kph"] = maxf(
			MIN_OPERATIONAL_SPEED_KPH,
			float(road.get("traffic_free_flow_speed_kph", profile.get("speed_kph", 30.0)))
		)
		road["profile"] = profile


static func _apply_road_metrics(city: Dictionary, metrics_value: Variant) -> void:
	var metrics: Dictionary = metrics_value if typeof(metrics_value) == TYPE_DICTIONARY else {}
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		var road_id := str(road.get("id", ""))
		var profile_value: Variant = road.get("profile", {})
		var has_profile := typeof(profile_value) == TYPE_DICTIONARY and not (profile_value as Dictionary).is_empty()
		var free_speed := maxf(
			MIN_OPERATIONAL_SPEED_KPH,
			float(road.get(
				"traffic_free_flow_speed_kph",
				(profile_value as Dictionary).get("speed_kph", 30.0) if has_profile else 30.0
			))
		)
		if not road.has("traffic_free_flow_speed_kph") and has_profile:
			road["traffic_free_flow_speed_kph"] = free_speed

		if metrics.has(road_id):
			var traffic: Dictionary = (metrics[road_id] as Dictionary).duplicate(true)
			var free_flow_minutes := maxf(EPSILON, float(traffic.get("free_flow_minutes", 0.0)))
			var travel_minutes := maxf(free_flow_minutes, float(traffic.get("travel_time_minutes", free_flow_minutes)))
			var operational_speed := clampf(
				free_speed * free_flow_minutes / travel_minutes,
				MIN_OPERATIONAL_SPEED_KPH,
				free_speed
			)
			traffic["free_flow_speed_kph"] = free_speed
			traffic["operational_speed_kph"] = operational_speed
			road["traffic"] = traffic
			if has_profile:
				var profile: Dictionary = profile_value
				profile["speed_kph"] = operational_speed
				road["profile"] = profile
		else:
			road.erase("traffic")
			if has_profile:
				var profile: Dictionary = profile_value
				profile["speed_kph"] = free_speed
				road["profile"] = profile


static func _snapshot_signature(
	demand_state: Dictionary,
	assignment: Dictionary,
	summary: Dictionary
) -> String:
	var parts: Array[String] = []
	var totals: Dictionary = demand_state.get("totals", {})
	parts.append("demand:%.3f:%d" % [
		float(totals.get("vehicle_trips_per_hour", 0.0)),
		int(totals.get("unresolved_od_pairs", 0)),
	])
	parts.append("summary:%.3f:%.3f:%.3f:%d:%d" % [
		float(summary.get("vehicle_km_per_hour", 0.0)),
		float(summary.get("delay_vehicle_hours_per_hour", 0.0)),
		float(summary.get("max_vc_ratio", 0.0)),
		int(summary.get("congested_edge_count", 0)),
		int(summary.get("severe_edge_count", 0)),
	])
	var road_metrics: Dictionary = assignment.get("road_metrics", {})
	var road_ids: Array = road_metrics.keys()
	road_ids.sort()
	for road_id_value in road_ids:
		var road_id := str(road_id_value)
		var row: Dictionary = road_metrics[road_id]
		parts.append("%s:%.3f:%.3f:%.3f" % [
			road_id,
			float(row.get("flow_vph", 0.0)),
			float(row.get("vc_ratio", 0.0)),
			float(row.get("delay_minutes", 0.0)),
		])
	return ";".join(parts)


static func _node_lookup(city: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for node_value in city.get("nodes", []):
		if typeof(node_value) != TYPE_DICTIONARY:
			continue
		var node: Dictionary = node_value
		var node_id := str(node.get("id", ""))
		if node_id.is_empty():
			continue
		result[node_id] = Vector2(float(node.get("x", 0.0)), float(node.get("y", 0.0)))
	return result


static func _settlement_lookup(city: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		result[str(settlement.get("id", ""))] = settlement
	return result


static func _empty_state() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"accumulator_seconds": 0.0,
		"revision": 0,
		"signature": "",
		"average_car_occupancy": AVERAGE_CAR_OCCUPANCY,
		"demand": {},
		"edge_metrics": {},
		"road_metrics": {},
		"od_results": [],
		"summary": {},
	}


static func _is_regional_city(city: Dictionary) -> bool:
	return str(city.get("world_map_id", MapDefinition.LEGACY_CITY_MAP_ID)) != MapDefinition.LEGACY_CITY_MAP_ID
