extends RefCounted
class_name RegionalHighwayPlanner

const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const RoadTopology = preload("res://scripts/city/road_topology.gd")
const WorldLayers = preload("res://scripts/world/world_layers.gd")

const TICK_SECONDS := 600.0
const RELIEF_PRESSURE_THRESHOLD := 1.25
const EXPRESSWAY_PRESSURE_THRESHOLD := 2.20
const MOTORWAY_PRESSURE_THRESHOLD := 3.80
const RING_MIN_POPULATION := 18000
const RING_MIN_INCIDENT_CORRIDORS := 2
const MIN_BYPASS_CLEARANCE_METERS := 520.0
const INTERCHANGE_STANDOFF_METERS := 360.0
const RING_EXTRA_CLEARANCE_METERS := 720.0
const WATER_PENALTY := 10000.0


static func ensure(city: Dictionary) -> void:
	if not _is_regional_city(city):
		return
	if not city.has("highway_planning") or typeof(city.get("highway_planning")) != TYPE_DICTIONARY:
		city["highway_planning"] = {
			"accumulator_seconds": 0.0,
			"revision": 0,
		}
	if not city.has("infrastructure_proposals") or typeof(city.get("infrastructure_proposals")) != TYPE_ARRAY:
		city["infrastructure_proposals"] = []
	refresh(city)


static func advance(store: Node, delta_seconds: float) -> bool:
	if delta_seconds <= 0.0 or not _is_regional_city(store.city):
		return false
	if not store.city.has("highway_planning"):
		ensure(store.city)
	var state: Dictionary = store.city.get("highway_planning", {})
	var accumulator := float(state.get("accumulator_seconds", 0.0)) + delta_seconds
	if accumulator < TICK_SECONDS:
		state["accumulator_seconds"] = accumulator
		store.city["highway_planning"] = state
		return false

	var previous_ids := _active_proposal_ids(store.city)
	while accumulator >= TICK_SECONDS:
		accumulator -= TICK_SECONDS
	state["accumulator_seconds"] = accumulator
	store.city["highway_planning"] = state
	var changed := refresh(store.city)
	if changed:
		_notify_new_proposals(store, previous_ids)
	return changed


## Re-evaluates strategic road demand without ever changing an existing road's
## class, geometry or status. Capacity pressure creates a separate planning
## proposal for a new bypass / expressway / motorway alignment.
static func refresh(city: Dictionary) -> bool:
	if not _is_regional_city(city):
		return false
	if not city.has("highway_planning"):
		city["highway_planning"] = {"accumulator_seconds": 0.0, "revision": 0}
	if not city.has("infrastructure_proposals"):
		city["infrastructure_proposals"] = []

	var before_signature := _proposal_signature(city.get("infrastructure_proposals", []))
	var settlements_by_id := _settlement_lookup(city)
	var existing_by_id := _proposal_lookup(city.get("infrastructure_proposals", []))
	var desired: Array[Dictionary] = []
	var incident_need: Dictionary = {}

	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("regionalRole", "")) not in ["spine", "loop", "city_connector"]:
			continue
		var a_id := str(road.get("a", ""))
		var b_id := str(road.get("b", ""))
		if not settlements_by_id.has(a_id) or not settlements_by_id.has(b_id) or a_id == b_id:
			continue
		var a: Dictionary = settlements_by_id[a_id]
		var b: Dictionary = settlements_by_id[b_id]
		var pressure := _corridor_pressure(road, a, b)

		# Compatibility cleanup: a regional road itself is never promoted into a
		# motorway. It only reports that a separate relief corridor may be needed.
		road.erase("upgradeRecommendation")
		road["capacityPressure"] = pressure
		road["reliefNeed"] = _need_class(pressure)
		road["preserveExistingRoad"] = true

		if pressure < RELIEF_PRESSURE_THRESHOLD:
			continue
		incident_need[a_id] = int(incident_need.get(a_id, 0)) + 1
		incident_need[b_id] = int(incident_need.get(b_id, 0)) + 1
		var proposal := _corridor_proposal(city, road, a, b, pressure)
		proposal = _preserve_proposal_state(proposal, existing_by_id.get(str(proposal.get("id", "")), {}))
		desired.append(proposal)

	for settlement_id_value in incident_need.keys():
		var settlement_id := str(settlement_id_value)
		if int(incident_need[settlement_id]) < RING_MIN_INCIDENT_CORRIDORS:
			continue
		var settlement: Dictionary = settlements_by_id.get(settlement_id, {})
		if int(settlement.get("population", 0)) < RING_MIN_POPULATION:
			continue
		var ring := _ring_proposal(city, settlement, int(incident_need[settlement_id]))
		ring = _preserve_proposal_state(ring, existing_by_id.get(str(ring.get("id", "")), {}))
		desired.append(ring)

	# Keep accepted/municipal/completed proposals even if demand later falls, so
	# planning history is stable. Pure suggestions can return to monitoring.
	var desired_ids: Dictionary = {}
	for proposal in desired:
		desired_ids[str(proposal.get("id", ""))] = true
	for old_value in city.get("infrastructure_proposals", []):
		if typeof(old_value) != TYPE_DICTIONARY:
			continue
		var old: Dictionary = old_value
		var old_id := str(old.get("id", ""))
		if desired_ids.has(old_id):
			continue
		var old_status := str(old.get("status", "suggested"))
		if old_status in ["accepted", "municipal-study", "under-construction", "completed"]:
			desired.append(old.duplicate(true))
		elif old_status == "suggested":
			var monitoring := old.duplicate(true)
			monitoring["status"] = "monitoring"
			monitoring["activeNeed"] = false
			desired.append(monitoring)

	desired.sort_custom(func(a, b): return str(a.get("id", "")) < str(b.get("id", "")))
	city["infrastructure_proposals"] = desired
	var after_signature := _proposal_signature(desired)
	if before_signature != after_signature:
		var state: Dictionary = city.get("highway_planning", {})
		state["revision"] = int(state.get("revision", 0)) + 1
		city["highway_planning"] = state
		return true
	return false


static func _corridor_proposal(
	city: Dictionary,
	road: Dictionary,
	a: Dictionary,
	b: Dictionary,
	pressure: float
) -> Dictionary:
	var kind := _need_class(pressure)
	var proposal_id := "regional-relief-%s" % str(road.get("id", "corridor"))
	var alignment := _best_bypass_alignment(city, a, b, proposal_id)
	var municipal_capacity := maxf(_municipal_capacity(a), _municipal_capacity(b))
	var municipal_eligible := pressure >= EXPRESSWAY_PRESSURE_THRESHOLD and municipal_capacity >= 1.0
	var status := "municipal-study" if municipal_eligible else "suggested"
	var a_name := str(a.get("name", a.get("id", "A")))
	var b_name := str(b.get("name", b.get("id", "B")))
	return {
		"id": proposal_id,
		"type": "regional_relief_corridor",
		"projectClass": kind,
		"status": status,
		"activeNeed": true,
		"label": "%s – %s %s" % [a_name, b_name, _project_label(kind)],
		"betweenSettlementIds": [str(a.get("id", "")), str(b.get("id", ""))],
		"sourceCorridorRoadId": str(road.get("id", "")),
		"pressure": pressure,
		"points": _serialize_points(alignment.get("points", [])),
		"alignmentSide": int(alignment.get("side", 1)),
		"terrainScore": float(alignment.get("score", 0.0)),
		"designPrinciple": "new_outer_alignment",
		"preserveExistingRoad": true,
		"allowsRoadsideDevelopmentOnExistingRoad": true,
		"playerActionRequired": not municipal_eligible,
		"municipalPlanningEligible": municipal_eligible,
		"municipalCapacity": municipal_capacity,
		"constructionAuthorized": false,
		"autoBuild": false,
		"interchangeAnchors": _proposal_interchange_anchors(alignment.get("points", [])),
		"futureRingCandidate": true,
	}


static func _ring_proposal(city: Dictionary, settlement: Dictionary, incident_corridors: int) -> Dictionary:
	var settlement_id := str(settlement.get("id", "settlement"))
	var proposal_id := "regional-orbital-%s" % settlement_id
	var alignment := _best_ring_alignment(city, settlement, proposal_id)
	var capacity := _municipal_capacity(settlement)
	var municipal_eligible := capacity >= 1.0
	return {
		"id": proposal_id,
		"type": "urban_orbital",
		"projectClass": "ring_road",
		"status": "municipal-study" if municipal_eligible else "suggested",
		"activeNeed": true,
		"label": "%s outer ring" % str(settlement.get("name", settlement_id)),
		"settlementId": settlement_id,
		"incidentCorridorCount": incident_corridors,
		"points": _serialize_points(alignment.get("points", [])),
		"terrainScore": float(alignment.get("score", 0.0)),
		"designPrinciple": "orbital_outside_built_up_area",
		"preserveExistingRoad": true,
		"playerActionRequired": not municipal_eligible,
		"municipalPlanningEligible": municipal_eligible,
		"municipalCapacity": capacity,
		"constructionAuthorized": false,
		"autoBuild": false,
	}


static func _corridor_pressure(road: Dictionary, a: Dictionary, b: Dictionary) -> float:
	var population := float(a.get("population", 0)) + float(b.get("population", 0))
	var jobs := float(a.get("jobs", 0)) + float(b.get("jobs", 0))
	var activity := population + jobs * 0.65
	var length_km := maxf(1.0, RoadTopology.polyline_length(road.get("points", [])) / 1000.0)
	return activity / (15000.0 * sqrt(length_km))


static func _need_class(pressure: float) -> String:
	if pressure >= MOTORWAY_PRESSURE_THRESHOLD:
		return "motorway"
	if pressure >= EXPRESSWAY_PRESSURE_THRESHOLD:
		return "expressway"
	if pressure >= RELIEF_PRESSURE_THRESHOLD:
		return "bypass"
	return "none"


static func _project_label(kind: String) -> String:
	match kind:
		"motorway": return "motorway corridor"
		"expressway": return "expressway corridor"
		_: return "bypass corridor"


static func _best_bypass_alignment(city: Dictionary, a: Dictionary, b: Dictionary, key: String) -> Dictionary:
	var a_pos: Vector2 = a.get("position", Vector2.ZERO)
	var b_pos: Vector2 = b.get("position", Vector2.ZERO)
	var direction := (b_pos - a_pos).normalized()
	if direction.length_squared() < 0.001:
		direction = Vector2.RIGHT
	var normal := Vector2(-direction.y, direction.x)
	var a_radius := maxf(420.0, float(a.get("built_up_radius_m", 420.0)))
	var b_radius := maxf(420.0, float(b.get("built_up_radius_m", 420.0)))
	var best: Dictionary = {}
	var best_score := INF
	var preferred_side := -1 if _unit_random(int(city.get("seed", 0)), key) < 0.5 else 1
	for side_value in [preferred_side, -preferred_side]:
		var side := float(side_value)
		for multiplier in [0.90, 1.12, 1.38]:
			var a_offset := maxf(MIN_BYPASS_CLEARANCE_METERS, a_radius * 0.72 + 360.0) * float(multiplier)
			var b_offset := maxf(MIN_BYPASS_CLEARANCE_METERS, b_radius * 0.72 + 360.0) * float(multiplier)
			var p0 := a_pos + direction * (a_radius + INTERCHANGE_STANDOFF_METERS) + normal * side * a_offset
			var p1 := a_pos + direction * (a_radius + 1050.0) + normal * side * a_offset
			var p4 := b_pos - direction * (b_radius + INTERCHANGE_STANDOFF_METERS) + normal * side * b_offset
			var p3 := b_pos - direction * (b_radius + 1050.0) + normal * side * b_offset
			var mid_offset := (a_offset + b_offset) * 0.52
			var p2 := a_pos.lerp(b_pos, 0.5) + normal * side * mid_offset
			var points: Array[Vector2] = [p0, p1, p2, p3, p4]
			var score := _alignment_score(city, points)
			if score < best_score:
				best_score = score
				best = {"points": points, "side": side_value, "score": score}
	return best


static func _best_ring_alignment(city: Dictionary, settlement: Dictionary, key: String) -> Dictionary:
	var center: Vector2 = settlement.get("position", Vector2.ZERO)
	var built_radius := maxf(500.0, float(settlement.get("built_up_radius_m", 500.0)))
	var base_radius := built_radius + maxf(RING_EXTRA_CLEARANCE_METERS, built_radius * 0.38)
	var seed := int(city.get("seed", 0))
	var phase := _unit_random(seed, key) * TAU
	var best: Dictionary = {}
	var best_score := INF
	for multiplier in [1.0, 1.18, 1.42]:
		var points: Array[Vector2] = []
		for index in range(12):
			var angle := phase + TAU * float(index) / 12.0
			var direction := Vector2(cos(angle), sin(angle))
			var preferred_radius := base_radius * float(multiplier)
			var best_point := center + direction * preferred_radius
			var point_score := INF
			for extra in [0.0, 240.0, 480.0]:
				var candidate := center + direction * (preferred_radius + float(extra))
				var score := _terrain_point_score(seed, candidate)
				if score < point_score:
					point_score = score
					best_point = candidate
			points.append(best_point)
		points.append(points[0])
		var total_score := _alignment_score(city, points)
		if total_score < best_score:
			best_score = total_score
			best = {"points": points, "score": total_score}
	return best


static func _alignment_score(city: Dictionary, points: Array[Vector2]) -> float:
	var seed := int(city.get("seed", 0))
	var score := 0.0
	for point in points:
		score += _terrain_point_score(seed, point)
		for settlement_value in city.get("regional_settlements", []):
			var settlement: Dictionary = settlement_value
			var center: Vector2 = settlement.get("position", Vector2.ZERO)
			var keepout := float(settlement.get("built_up_radius_m", 0.0)) + 260.0
			var distance := point.distance_to(center)
			if distance < keepout:
				score += (keepout - distance) * 0.08 + 60.0
	return score


static func _terrain_point_score(seed: int, point: Vector2) -> float:
	var sample := WorldLayers.sample_route_terrain(seed, point)
	var score := float(sample.get("slope_degrees", 0.0)) * 0.18
	score += float(sample.get("forest_potential", 0.0)) * 1.4
	if float(sample.get("water_depth", 0.0)) > 0.05 or str(sample.get("water_kind", "none")) != "none":
		score += WATER_PENALTY
	return score


static func _municipal_capacity(settlement: Dictionary) -> float:
	# Temporary economic-capacity proxy until settlements have independent
	# municipal treasuries. It allows a mature city to start a planning study,
	# never to build a motorway automatically.
	var population := float(settlement.get("population", 0))
	var jobs := float(settlement.get("jobs", 0))
	return (population * 0.30 + jobs * 0.95) / 22000.0


static func _preserve_proposal_state(proposal: Dictionary, old: Dictionary) -> Dictionary:
	if old.is_empty():
		return proposal
	var old_status := str(old.get("status", ""))
	if old_status in ["accepted", "under-construction", "completed", "dismissed"]:
		proposal["status"] = old_status
	if old.has("playerDecision"):
		proposal["playerDecision"] = old["playerDecision"]
	return proposal


static func _proposal_interchange_anchors(points_value: Variant) -> Array:
	if typeof(points_value) != TYPE_ARRAY:
		return []
	var points: Array = points_value
	if points.size() < 2:
		return []
	return [_serialize_point(points[0]), _serialize_point(points[points.size() - 1])]


static func _notify_new_proposals(store: Node, previous_ids: Dictionary) -> void:
	if not store.has_signal("toast_requested"):
		return
	for proposal_value in store.city.get("infrastructure_proposals", []):
		if typeof(proposal_value) != TYPE_DICTIONARY:
			continue
		var proposal: Dictionary = proposal_value
		var proposal_id := str(proposal.get("id", ""))
		if previous_ids.has(proposal_id) or not bool(proposal.get("activeNeed", false)):
			continue
		var prefix := "MUNICIPAL STUDY" if str(proposal.get("status", "")) == "municipal-study" else "REGIONAL PLANNING NEED"
		store.emit_signal("toast_requested", "%s · %s" % [prefix, str(proposal.get("label", "New road corridor"))])


static func _active_proposal_ids(city: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for proposal_value in city.get("infrastructure_proposals", []):
		if typeof(proposal_value) != TYPE_DICTIONARY:
			continue
		var proposal: Dictionary = proposal_value
		if bool(proposal.get("activeNeed", false)):
			result[str(proposal.get("id", ""))] = true
	return result


static func _settlement_lookup(city: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		result[str(settlement.get("id", ""))] = settlement
	return result


static func _proposal_lookup(proposals_value: Variant) -> Dictionary:
	var result: Dictionary = {}
	if typeof(proposals_value) != TYPE_ARRAY:
		return result
	for proposal_value in proposals_value:
		if typeof(proposal_value) != TYPE_DICTIONARY:
			continue
		var proposal: Dictionary = proposal_value
		result[str(proposal.get("id", ""))] = proposal
	return result


static func _proposal_signature(proposals_value: Variant) -> String:
	if typeof(proposals_value) != TYPE_ARRAY:
		return ""
	var parts: Array[String] = []
	for proposal_value in proposals_value:
		if typeof(proposal_value) != TYPE_DICTIONARY:
			continue
		var proposal: Dictionary = proposal_value
		parts.append("%s|%s|%s|%.3f" % [
			str(proposal.get("id", "")),
			str(proposal.get("status", "")),
			str(proposal.get("projectClass", "")),
			float(proposal.get("pressure", 0.0)),
		])
	parts.sort()
	return ";".join(parts)


static func _serialize_points(points_value: Variant) -> Array:
	var result: Array = []
	if typeof(points_value) != TYPE_ARRAY:
		return result
	for point_value in points_value:
		if point_value is Vector2:
			result.append(_serialize_point(point_value))
		elif typeof(point_value) == TYPE_DICTIONARY:
			result.append((point_value as Dictionary).duplicate(true))
	return result


static func _serialize_point(point: Vector2) -> Dictionary:
	return {"x": point.x, "y": point.y}


static func _unit_random(seed: int, key: String) -> float:
	var value := (seed ^ _stable_text_hash(key)) & 0xffffffff
	value = (value * 1664525 + 1013904223) & 0xffffffff
	return float(value & 0xffff) / 65535.0


static func _stable_text_hash(text_value: String) -> int:
	var hash_value := 2166136261
	for index in range(text_value.length()):
		hash_value = (hash_value ^ text_value.unicode_at(index)) & 0xffffffff
		hash_value = (hash_value * 16777619) & 0xffffffff
	return hash_value


static func _is_regional_city(city: Dictionary) -> bool:
	return str(city.get("world_map_id", MapDefinition.LEGACY_CITY_MAP_ID)) != MapDefinition.LEGACY_CITY_MAP_ID
