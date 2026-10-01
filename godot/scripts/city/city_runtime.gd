extends RefCounted
class_name CityRuntime

const Data = preload("res://scripts/core/game_data.gd")
const PlanGenerator = preload("res://scripts/city/city_plan_generator.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")

const CITY_VERSION := 1
const MAX_ACTIVE_PROJECTS := 2
const STEP_SECONDS := 0.2

static func create_initial_city(seed: int = Data.DEFAULT_CITY_SEED) -> Dictionary:
	var plan := PlanGenerator.generate(seed)

	return {
		"version": CITY_VERSION,
		"seed": seed,
		"time_seconds": 0.0,
		"runtime_accumulator_seconds": 0.0,
		"next_project_id": 1,
		"nodes": plan.get("nodes", []),
		"graph_edges": plan.get("graphEdges", []),
		"junctions": plan.get("junctions", []),
		"roads": plan.get("roads", []),
		"districts": plan.get("districts", []),
		"blocks": plan.get("blocks", []),
		"parcels": plan.get("parcels", []),
		"reservations": plan.get("reservations", []),
		"buildings": [],
		"projects": [],
	}

static func ensure_city(store: Node) -> void:
	if typeof(store.city) != TYPE_DICTIONARY or int(store.city.get("version", 0)) != CITY_VERSION:
		store.city = create_initial_city(store.city_seed)

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
	var guard := 0

	while float(store.city["runtime_accumulator_seconds"]) >= STEP_SECONDS and guard < 8:
		guard += 1
		changed = _progress_active_projects(store.city, STEP_SECONDS) or changed
		changed = _queue_development_projects(store) or changed
		changed = _start_eligible_projects(store.city) or changed
		_update_development_levels(store)
		store.city["runtime_accumulator_seconds"] = float(store.city["runtime_accumulator_seconds"]) - STEP_SECONDS

	return changed

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
