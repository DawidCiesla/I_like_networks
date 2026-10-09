extends RefCounted

# The original terrain-aware regional graph generator is kept as a stable core.
# This layer applies the gameplay-facing realism contract: starter settlements
# stay small, their physical footprint follows population, and their local
# morphology is rebuilt at an actual town/village scale.
const CoreGenerator = preload("res://scripts/world/region_plan_generator_core.gd")
const Terrain = preload("res://scripts/world/terrain_model.gd")

const WORLD_LAYERS_PATH := "res://scripts/world/world_layers.gd"
const MAX_STARTER_POPULATION := 5000
const MAX_STARTER_VILLAGE_POPULATION := 1500
# A rendered footprint represents a small household cluster / multifamily
# building rather than dozens of homes. This keeps a 4-5k town visually dense.
const PEOPLE_PER_VISUAL_BUILDING := 12.0
const MAX_VISUAL_BUILDINGS_PER_SETTLEMENT := 420
const DEVELOPMENT_RESERVE_MULTIPLIER := 1.20
const MAX_LOCAL_STREETS_PER_SETTLEMENT := 16
const MAX_SLOTS_PER_STREET := 18
const ROAD_INTERSECTION_TOLERANCE_METERS := 0.75

# The region deliberately begins with one clear service centre and a rural
# constellation around it. The satellites are villages, not additional towns;
# their later promotion is an outcome of the transport/growth simulation.
const POPULATION_PROFILE := {
	"regional-center": 4600,
	"northwest-town": 1250,
	"northeast-town": 950,
	"southwest-town": 650,
	"southeast-town": 1150,
	"north-village": 750,
	"south-village": 500,
}

const SETTLEMENT_NAMES := {
	"regional-center": "Regional Town",
	"northwest-town": "Northwest Village",
	"northeast-town": "Northeast Village",
	"southwest-town": "Southwest Village",
	"southeast-town": "Southeast Village",
	"north-village": "North Village",
	"south-village": "South Village",
}

static var _world_layers_script: Script


static func generate(seed: int, bounds: Rect2) -> Dictionary:
	var plan: Dictionary = CoreGenerator.generate(seed, bounds)
	if not bool(plan.get("valid", false)):
		return plan

	_apply_population_profile(plan, seed)
	_rebuild_local_morphology(plan, seed, bounds.abs())
	_refresh_stats(plan)
	plan["generation_profile"] = "realistic-starter-region-v3"
	return plan


static func _apply_population_profile(plan: Dictionary, seed: int) -> void:
	for settlement_value in plan.get("settlements", []):
		var settlement: Dictionary = settlement_value
		var settlement_id := str(settlement.get("id", ""))
		var profile_key := _population_profile_key(settlement_id)
		var is_hub := profile_key == "regional-center"
		var base_population := int(POPULATION_PROFILE.get(profile_key, 800))
		settlement["tier"] = "market" if is_hub else "village"
		if SETTLEMENT_NAMES.has(profile_key):
			settlement["name"] = str(SETTLEMENT_NAMES[profile_key])
		var variation_span := 0.06 if is_hub else 0.12
		var variation := lerpf(
			1.0 - variation_span,
			1.0 + variation_span,
			_unit_random(seed, "%s:population" % settlement_id)
		)
		var upper_population := MAX_STARTER_POPULATION if is_hub else MAX_STARTER_VILLAGE_POPULATION
		var population := clampi(roundi(float(base_population) * variation), 350, upper_population)
		settlement["population"] = population
		settlement["built_up_radius_m"] = _built_up_radius(population, str(settlement.get("tier", "village")))
		settlement["population_profile"] = profile_key
		settlement["starter_role"] = "town" if is_hub else "village"


static func _population_profile_key(settlement_id: String) -> String:
	for key_value in POPULATION_PROFILE.keys():
		var key := str(key_value)
		if settlement_id.ends_with("-%s" % key):
			return key
	return ""


static func _built_up_radius(population: int, tier: String) -> float:
	# Gross density includes gardens, local streets and open plots. The largest
	# starter town therefore occupies roughly a 2 km diameter built-up area.
	var gross_density_per_km2 := 650.0
	if tier == "capital":
		gross_density_per_km2 = 1450.0
	elif tier == "market":
		gross_density_per_km2 = 1150.0
	var area_km2 := maxf(0.12, float(population) / gross_density_per_km2)
	return clampf(sqrt(area_km2 / PI) * 1000.0, 420.0, 1150.0)


static func _rebuild_local_morphology(plan: Dictionary, seed: int, bounds: Rect2) -> void:
	var regional_edges: Array[Dictionary] = []
	for edge_value in plan.get("graph_edges", []):
		var edge: Dictionary = edge_value
		if str(edge.get("role", "")) != "local_street":
			regional_edges.append(edge)

	var graph_nodes: Array[Dictionary] = []
	for node_value in plan.get("graph_nodes", []):
		var node: Dictionary = node_value
		if str(node.get("kind", "")) != "street_terminal":
			graph_nodes.append(node)

	var local_nodes: Array[Dictionary] = []
	var local_streets: Array[Dictionary] = []
	var parcels: Array[Dictionary] = []
	var buildings: Array[Dictionary] = []
	var occupied_edges: Array[Dictionary] = []
	occupied_edges.append_array(regional_edges)

	for settlement_value in plan.get("settlements", []):
		var settlement: Dictionary = settlement_value
		var morphology := _build_settlement_morphology(seed, bounds, settlement, occupied_edges)
		var settlement_streets: Array[Dictionary] = []
		settlement_streets.append_array(morphology.get("streets", []))
		local_nodes.append_array(morphology.get("nodes", []))
		local_streets.append_array(settlement_streets)
		parcels.append_array(morphology.get("parcels", []))
		buildings.append_array(morphology.get("buildings", []))
		occupied_edges.append_array(settlement_streets)

	graph_nodes.append_array(local_nodes)
	var all_edges: Array[Dictionary] = regional_edges.duplicate(true)
	all_edges.append_array(local_streets)

	plan["graph_nodes"] = graph_nodes
	plan["graph_edges"] = all_edges
	plan["local_streets"] = local_streets
	plan["parcels"] = parcels
	plan["building_anchors"] = buildings


static func _build_settlement_morphology(
	seed: int,
	bounds: Rect2,
	settlement: Dictionary,
	blocking_edges: Array[Dictionary]
) -> Dictionary:
	var settlement_id := str(settlement.get("id", "settlement"))
	var center: Vector2 = settlement.get("position", Vector2.ZERO)
	var population := maxi(350, int(settlement.get("population", 350)))
	var tier := str(settlement.get("tier", "village"))
	var radius := float(settlement.get("built_up_radius_m", _built_up_radius(population, tier)))
	var minimum_streets := 4 if tier == "village" else 6
	var street_count := clampi(
		ceili(float(population) / 320.0),
		minimum_streets,
		MAX_LOCAL_STREETS_PER_SETTLEMENT
	)

	var nodes: Array[Dictionary] = []
	var streets: Array[Dictionary] = []
	var terminals: Array[Dictionary] = []
	var parcels: Array[Dictionary] = []
	var buildings: Array[Dictionary] = []
	var base_angle := _unit_random(seed, "%s:orientation" % settlement_id) * TAU

	for street_index in range(street_count):
		var even_angle := base_angle + TAU * float(street_index) / float(street_count)
		var jitter := lerpf(-0.16, 0.16, _unit_random(seed, "%s:angle:%d" % [settlement_id, street_index]))
		var length_factor := lerpf(0.76, 1.02, _unit_random(seed, "%s:length:%d" % [settlement_id, street_index]))
		var candidate_blockers: Array[Dictionary] = []
		candidate_blockers.append_array(blocking_edges)
		candidate_blockers.append_array(streets)
		var road_points: Array[Vector2] = _best_radial_points(
			seed,
			bounds,
			center,
			even_angle + jitter,
			radius * length_factor,
			"%s:%d" % [settlement_id, street_index],
			candidate_blockers,
			settlement_id
		)
		if road_points.size() < 2:
			continue
		var endpoint: Vector2 = road_points.back()
		var node_id := "street-node-%s-%02d" % [settlement_id, street_index]
		var street_id := "local-road-%s-radial-%02d" % [settlement_id, street_index]
		nodes.append({
			"id": node_id,
			"kind": "street_terminal",
			"settlement_id": settlement_id,
			"position": endpoint,
		})
		var street := _make_local_street(
			street_id,
			settlement_id,
			settlement_id,
			node_id,
			road_points,
			"radial-%02d" % street_index,
			street_index
		)
		streets.append(street)
		terminals.append({
			"node_id": node_id,
			"position": endpoint,
			"angle": atan2(endpoint.y - center.y, endpoint.x - center.x),
		})

	# An irregular outer loop turns the radial access roads into actual blocks
	# instead of a pure star. Segments over unsuitable terrain or intersecting
	# existing roads away from graph nodes are omitted.
	if terminals.size() >= 4:
		terminals.sort_custom(func(a, b): return float(a.get("angle", 0.0)) < float(b.get("angle", 0.0)))
		for ring_index in range(terminals.size()):
			var first: Dictionary = terminals[ring_index]
			var second: Dictionary = terminals[(ring_index + 1) % terminals.size()]
			var a: Vector2 = first["position"]
			var b: Vector2 = second["position"]
			var midpoint := a.lerp(b, 0.5)
			var inward := (center - midpoint).normalized()
			var curve_strength := minf(a.distance_to(b) * 0.13, radius * 0.16)
			var ring_mid := midpoint + inward * curve_strength
			if not _point_is_buildable(seed, ring_mid, 19.0):
				continue
			var ring_points: Array[Vector2] = [a, ring_mid, b]
			var ring_blockers: Array[Dictionary] = []
			ring_blockers.append_array(blocking_edges)
			ring_blockers.append_array(streets)
			if _path_conflicts(
				ring_points,
				ring_blockers,
				str(first["node_id"]),
				str(second["node_id"]),
				a,
				b
			):
				continue
			var ring_id := "local-road-%s-ring-%02d" % [settlement_id, ring_index]
			streets.append(_make_local_street(
				ring_id,
				settlement_id,
				str(first["node_id"]),
				str(second["node_id"]),
				ring_points,
				"ring-%02d" % ring_index,
				100 + ring_index
			))

	var target_existing := clampi(
		roundi(float(population) / PEOPLE_PER_VISUAL_BUILDING),
		20,
		MAX_VISUAL_BUILDINGS_PER_SETTLEMENT
	)
	var target_capacity := maxi(target_existing, ceili(float(target_existing) * DEVELOPMENT_RESERVE_MULTIPLIER))
	var slots_per_street := clampi(
		ceili(float(target_capacity) / float(maxi(1, streets.size()))),
		3,
		MAX_SLOTS_PER_STREET
	)
	var created := 0
	var occupied := 0

	# Slot-major iteration spreads existing buildings across the whole town
	# before reserve parcels are added, avoiding a half-empty side of town.
	for slot_index in range(slots_per_street):
		for street_index in range(streets.size()):
			if created >= target_capacity:
				break
			var street: Dictionary = streets[street_index]
			var anchor := _building_anchor(
				seed,
				bounds,
				street,
				slot_index,
				slots_per_street,
				street_index
			)
			if anchor.is_empty():
				continue
			var is_existing := occupied < target_existing
			var ordinal := created + 1
			var building_type := _starter_building_type(tier, ordinal)
			var footprint := _building_footprint(building_type)
			if _overlaps_existing_parcel(parcels, anchor["position"], footprint):
				continue
			var parcel_id := "parcel-%s-%04d" % [settlement_id, ordinal]
			var building_id := "building-%s-%04d" % [settlement_id, ordinal]
			parcels.append({
				"id": parcel_id,
				"settlement_id": settlement_id,
				"street_id": str(street.get("id", "")),
				"position": anchor["position"],
				"access_point": anchor["access_point"],
				"footprint": footprint,
				"building_id": building_id,
				"existing": is_existing,
			})
			buildings.append({
				"id": building_id,
				"parcel_id": parcel_id,
				"settlement_id": settlement_id,
				"street_id": str(street.get("id", "")),
				"type": building_type,
				"existing": is_existing,
				"status": "occupied" if is_existing else "planned",
				"position": anchor["position"],
				"facing": (anchor["access_point"] - anchor["position"]).normalized(),
				"footprint": footprint,
			})
			created += 1
			if is_existing:
				occupied += 1

	return {
		"nodes": nodes,
		"streets": streets,
		"parcels": parcels,
		"buildings": buildings,
	}


static func _make_local_street(
	id: String,
	settlement_id: String,
	a: String,
	b: String,
	points: Array,
	direction: String,
	direction_index: int
) -> Dictionary:
	return {
		"valid": true,
		"id": id,
		"a": a,
		"b": b,
		"class": "local",
		"role": "local_street",
		"settlement_id": settlement_id,
		"direction": direction,
		"direction_index": direction_index,
		"points": points,
		"length": _polyline_length(points),
		"terrain_cost": 0.0,
		"bridge_crossings": [],
	}


static func _best_radial_points(
	seed: int,
	bounds: Rect2,
	center: Vector2,
	angle: float,
	length: float,
	key: String,
	blocking_edges: Array[Dictionary],
	start_node_id: String
) -> Array[Vector2]:
	var safe_padding := minf(220.0, minf(bounds.size.x, bounds.size.y) * 0.03)
	var safe_bounds := Rect2(bounds.position + Vector2.ONE * safe_padding, bounds.size - Vector2.ONE * safe_padding * 2.0)
	var best_points: Array[Vector2] = []
	var best_score := INF
	# Compact maps can contain dense regional corridors around a settlement.
	# Search both shorter neighbourhood streets and full-radius radials so the
	# settlement retains a useful local skeleton without creating fake crossings.
	var angle_offsets := [-0.52, -0.42, -0.34, -0.24, -0.14, -0.07, 0.0, 0.07, 0.14, 0.24, 0.34, 0.42, 0.52]
	var length_factors := [0.20, 0.28, 0.38, 0.50, 0.62, 0.72, 0.82, 0.92, 1.0, 1.08]
	for angle_offset_value in angle_offsets:
		var candidate_angle := angle + float(angle_offset_value)
		var direction := Vector2(cos(candidate_angle), sin(candidate_angle))
		var side := Vector2(-direction.y, direction.x)
		for factor_value in length_factors:
			var candidate_length := length * float(factor_value)
			var endpoint := _clamp_to_rect(center + direction * candidate_length, safe_bounds)
			if endpoint.distance_to(center) < 72.0:
				continue
			var curve := lerpf(-0.08, 0.08, _unit_random(seed, "%s:curve:%.2f:%.2f" % [key, candidate_angle, candidate_length]))
			var midpoint := center.lerp(endpoint, 0.52) + side * candidate_length * curve
			var candidate_points: Array[Vector2] = [center, midpoint, endpoint]
			if _path_conflicts(
				candidate_points,
				blocking_edges,
				start_node_id,
				"",
				center,
				endpoint
			):
				continue
			var endpoint_sample := _terrain_sample(seed, endpoint)
			var midpoint_sample := _terrain_sample(seed, midpoint)
			var score := _terrain_score(endpoint_sample) + _terrain_score(midpoint_sample) * 0.75
			score += absf(float(angle_offset_value)) * 9.0
			score += absf(float(factor_value) - 1.0) * 4.0
			# Prefer full neighbourhood streets when topology permits, but let
			# shorter stubs win when they are the only conflict-free option.
			score += maxf(0.0, 0.62 - float(factor_value)) * 3.5
			if score < best_score:
				best_score = score
				best_points = candidate_points
	return best_points


static func _path_conflicts(
	candidate: Array[Vector2],
	blocking_edges: Array[Dictionary],
	start_node_id: String,
	end_node_id: String,
	start_position: Vector2,
	end_position: Vector2
) -> bool:
	for edge in blocking_edges:
		var other_points: Array[Vector2] = _edge_points(edge)
		if other_points.size() < 2:
			continue
		var allowed_points: Array[Vector2] = []
		var edge_a := str(edge.get("a", ""))
		var edge_b := str(edge.get("b", ""))
		if not start_node_id.is_empty() and (edge_a == start_node_id or edge_b == start_node_id):
			allowed_points.append(start_position)
		if not end_node_id.is_empty() and (edge_a == end_node_id or edge_b == end_node_id):
			allowed_points.append(end_position)
		if _paths_cross_away_from_allowed_points(candidate, other_points, allowed_points):
			return true
	return false


static func _edge_points(edge: Dictionary) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for point_value in edge.get("points", []):
		if point_value is Vector2:
			result.append(point_value)
		elif typeof(point_value) == TYPE_DICTIONARY:
			var point: Dictionary = point_value
			result.append(Vector2(float(point.get("x", 0.0)), float(point.get("y", 0.0))))
	return result


static func _paths_cross_away_from_allowed_points(
	first: Array[Vector2],
	second: Array[Vector2],
	allowed_points: Array[Vector2]
) -> bool:
	for first_index in range(1, first.size()):
		var first_a: Vector2 = first[first_index - 1]
		var first_b: Vector2 = first[first_index]
		for second_index in range(1, second.size()):
			var second_a: Vector2 = second[second_index - 1]
			var second_b: Vector2 = second[second_index]
			var crossings: Array[Vector2] = _segment_intersections(first_a, first_b, second_a, second_b)
			for crossing in crossings:
				if _is_allowed_crossing(crossing, allowed_points):
					continue
				return true
	return false


static func _is_allowed_crossing(crossing: Vector2, allowed_points: Array[Vector2]) -> bool:
	for allowed in allowed_points:
		if crossing.distance_to(allowed) <= ROAD_INTERSECTION_TOLERANCE_METERS:
			return true
	return false


static func _segment_intersections(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var first_direction := b - a
	var second_direction := d - c
	var denominator := first_direction.cross(second_direction)
	var offset := c - a
	if absf(denominator) > 0.00001:
		var t := offset.cross(second_direction) / denominator
		var u := offset.cross(first_direction) / denominator
		if t >= -0.00001 and t <= 1.00001 and u >= -0.00001 and u <= 1.00001:
			result.append(a + first_direction * clampf(t, 0.0, 1.0))
		return result

	# Parallel non-collinear segments never meet. For collinear roads collect
	# overlap endpoints as intersection witnesses so accidental shared corridors
	# are rejected as well as ordinary X crossings.
	if absf(offset.cross(first_direction)) > 0.001:
		return result
	for point in [a, b, c, d]:
		var candidate: Vector2 = point
		if _point_on_segment(candidate, a, b) and _point_on_segment(candidate, c, d):
			var duplicate := false
			for existing in result:
				if existing.distance_to(candidate) <= 0.001:
					duplicate = true
					break
			if not duplicate:
				result.append(candidate)
	return result


static func _point_on_segment(point: Vector2, start: Vector2, finish: Vector2) -> bool:
	var segment := finish - start
	var relative := point - start
	if absf(segment.cross(relative)) > 0.01:
		return false
	var dot := relative.dot(segment)
	if dot < -0.01:
		return false
	return dot <= segment.length_squared() + 0.01


static func _building_anchor(
	seed: int,
	bounds: Rect2,
	street: Dictionary,
	slot_index: int,
	slot_count: int,
	street_index: int
) -> Dictionary:
	var points: Array = street.get("points", [])
	var total_length := _polyline_length(points)
	if points.size() < 2 or total_length < 70.0:
		return {}
	var fraction := clampf(float(slot_index + 1) / float(slot_count + 1), 0.06, 0.94)
	var along := total_length * fraction
	var sample := _point_and_tangent(points, along)
	var access_point: Vector2 = sample["point"]
	var tangent: Vector2 = sample["tangent"]
	var normal := Vector2(-tangent.y, tangent.x)
	var preferred_side := -1.0 if ((slot_index + street_index) % 2 == 0) else 1.0
	var safe_padding := minf(120.0, minf(bounds.size.x, bounds.size.y) * 0.02)
	var safe_bounds := Rect2(bounds.position + Vector2.ONE * safe_padding, bounds.size - Vector2.ONE * safe_padding * 2.0)

	for side in [preferred_side, -preferred_side]:
		for lateral in [22.0, 28.0, 34.0]:
			var candidate := _clamp_to_rect(access_point + normal * float(side) * float(lateral), safe_bounds)
			if _point_is_buildable(seed, candidate, 20.0):
				return {"position": candidate, "access_point": access_point}
	return {}


static func _starter_building_type(tier: String, ordinal: int) -> String:
	if tier == "village":
		return "shop" if ordinal % 23 == 1 else "house"
	if ordinal % 17 == 1:
		return "shop"
	if ordinal % 11 == 0:
		return "apartment"
	if ordinal % 5 == 0:
		return "townhouse"
	return "house"


static func _building_footprint(building_type: String) -> Vector2:
	match building_type:
		"shop":
			return Vector2(22.0, 14.0)
		"townhouse":
			return Vector2(13.0, 20.0)
		"apartment":
			return Vector2(28.0, 22.0)
		_:
			return Vector2(14.0, 10.0)


static func _overlaps_existing_parcel(parcels: Array[Dictionary], position: Vector2, footprint: Vector2) -> bool:
	for parcel in parcels:
		var other_position: Vector2 = parcel.get("position", Vector2.ZERO)
		var other_footprint: Vector2 = parcel.get("footprint", Vector2(14.0, 10.0))
		if (
			absf(position.x - other_position.x) < (footprint.x + other_footprint.x) * 0.5 + 4.0
			and absf(position.y - other_position.y) < (footprint.y + other_footprint.y) * 0.5 + 4.0
		):
			return true
	return false


static func _point_is_buildable(seed: int, point: Vector2, max_slope: float) -> bool:
	var sample := _terrain_sample(seed, point)
	if float(sample.get("water_depth", 0.0)) > 0.05:
		return false
	if str(sample.get("water_kind", "")) not in ["", "none"]:
		return false
	return float(sample.get("slope_degrees", 0.0)) <= max_slope


static func _terrain_score(sample: Dictionary) -> float:
	var score := float(sample.get("slope_degrees", 0.0)) * 1.6
	score += float(sample.get("forest_potential", 0.0)) * 8.0
	if float(sample.get("water_depth", 0.0)) > 0.05 or str(sample.get("water_kind", "")) not in ["", "none"]:
		score += 10000.0
	return score


static func _terrain_sample(seed: int, point: Vector2) -> Dictionary:
	if _world_layers_script == null and ResourceLoader.exists(WORLD_LAYERS_PATH):
		_world_layers_script = load(WORLD_LAYERS_PATH) as Script
	if _world_layers_script != null:
		var sampler := "sample_route_terrain" if _world_layers_script.has_method("sample_route_terrain") else "sample"
		if _world_layers_script.has_method(sampler):
			var value: Variant = _world_layers_script.call(sampler, seed, point)
			if value is Dictionary:
				var result: Dictionary = value
				if not result.has("slope_degrees"):
					result["slope_degrees"] = Terrain.slope_degrees(seed, point.x, point.y)
				if not result.has("forest_potential"):
					result["forest_potential"] = Terrain.forest_potential(seed, point.x, point.y)
				return result
	return {
		"slope_degrees": Terrain.slope_degrees(seed, point.x, point.y),
		"forest_potential": Terrain.forest_potential(seed, point.x, point.y),
		"water_depth": 0.0,
		"water_kind": "",
	}


static func _point_and_tangent(points: Array, distance_along: float) -> Dictionary:
	var remaining := distance_along
	for index in range(1, points.size()):
		var start: Vector2 = points[index - 1]
		var finish: Vector2 = points[index]
		var segment_length := start.distance_to(finish)
		if segment_length <= 0.001:
			continue
		if remaining <= segment_length or index == points.size() - 1:
			var tangent := (finish - start).normalized()
			return {
				"point": start.lerp(finish, clampf(remaining / segment_length, 0.0, 1.0)),
				"tangent": tangent,
			}
		remaining -= segment_length
	return {
		"point": points.back(),
		"tangent": (points.back() - points[points.size() - 2]).normalized(),
	}


static func _polyline_length(points: Array) -> float:
	var length := 0.0
	for index in range(1, points.size()):
		length += (points[index] as Vector2).distance_to(points[index - 1] as Vector2)
	return length


static func _clamp_to_rect(point: Vector2, rect: Rect2) -> Vector2:
	return Vector2(
		clampf(point.x, rect.position.x, rect.end.x),
		clampf(point.y, rect.position.y, rect.end.y)
	)


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


static func _refresh_stats(plan: Dictionary) -> void:
	var stats: Dictionary = plan.get("stats", {}).duplicate(true)
	var max_population := 0
	var built_up_area_km2 := 0.0
	for settlement_value in plan.get("settlements", []):
		var settlement: Dictionary = settlement_value
		max_population = maxi(max_population, int(settlement.get("population", 0)))
		var radius_km := float(settlement.get("built_up_radius_m", 0.0)) / 1000.0
		built_up_area_km2 += PI * radius_km * radius_km
	stats["settlement_count"] = (plan.get("settlements", []) as Array).size()
	stats["edge_count"] = (plan.get("graph_edges", []) as Array).size()
	stats["regional_edge_count"] = _regional_edge_count(plan.get("graph_edges", []))
	stats["local_street_count"] = (plan.get("local_streets", []) as Array).size()
	stats["parcel_count"] = (plan.get("parcels", []) as Array).size()
	stats["building_anchor_count"] = (plan.get("building_anchors", []) as Array).size()
	stats["max_settlement_population"] = max_population
	stats["approx_built_up_area_km2"] = built_up_area_km2
	stats["bridge_crossing_count"] = _count_bridge_crossings(plan.get("graph_edges", []))
	plan["stats"] = stats


static func _regional_edge_count(edges: Array) -> int:
	var count := 0
	for edge_value in edges:
		var edge: Dictionary = edge_value
		if str(edge.get("role", "")) != "local_street":
			count += 1
	return count


static func _count_bridge_crossings(edges: Array) -> int:
	var count := 0
	for edge_value in edges:
		var edge: Dictionary = edge_value
		count += (edge.get("bridge_crossings", []) as Array).size()
	return count