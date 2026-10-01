extends RefCounted
class_name CityPlanGenerator

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const Terrain = preload("res://scripts/world/terrain_model.gd")
const Topology = preload("res://scripts/city/road_topology.gd")

const DISTRICT_SPECS := [
	{"id":"oldTown","name":"Old Town","lineKey":"line1","stopIndex":0,"theme":"residential","parentRoadId":"arterial-oldTown-existing","branchSide":1,"depth":250.0,"halfWidth":210.0,"crossRoadCount":2},
	{"id":"market","name":"Market Square","lineKey":"line1","stopIndex":1,"theme":"mixed","parentRoadId":"arterial-line1-0","branchSide":-1,"depth":280.0,"halfWidth":235.0,"crossRoadCount":2},
	{"id":"park","name":"City Park","lineKey":"line1","stopIndex":2,"theme":"park","parentRoadId":"arterial-line1-1","branchSide":1,"depth":270.0,"halfWidth":215.0,"crossRoadCount":2},
	{"id":"university","name":"University","lineKey":"line1","stopIndex":3,"theme":"campus","parentRoadId":"arterial-line1-2","branchSide":-1,"depth":310.0,"halfWidth":245.0,"crossRoadCount":2},
	{"id":"central","name":"Central","lineKey":"line1","stopIndex":4,"theme":"central","parentRoadId":"arterial-line1-3","branchSide":1,"depth":350.0,"halfWidth":285.0,"crossRoadCount":3},
	{"id":"riverside","name":"Riverside","lineKey":"line2","stopIndex":1,"theme":"riverside","parentRoadId":"arterial-line2-0","branchSide":1,"depth":280.0,"halfWidth":225.0,"crossRoadCount":2},
	{"id":"museum","name":"Museum","lineKey":"line2","stopIndex":2,"theme":"mixed","parentRoadId":"arterial-line2-1","branchSide":-1,"depth":300.0,"halfWidth":245.0,"crossRoadCount":2},
	{"id":"harbor","name":"Harbor","lineKey":"line2","stopIndex":3,"theme":"industrial","parentRoadId":"arterial-line2-2","branchSide":1,"depth":350.0,"halfWidth":300.0,"crossRoadCount":2},
	{"id":"northQuarter","name":"North Quarter","lineKey":"line3","stopIndex":1,"theme":"mixed","parentRoadId":"arterial-line3-0","branchSide":-1,"depth":310.0,"halfWidth":250.0,"crossRoadCount":2},
	{"id":"hillcrest","name":"Hillcrest","lineKey":"line3","stopIndex":2,"theme":"residential","parentRoadId":"arterial-line3-1","branchSide":1,"depth":330.0,"halfWidth":265.0,"crossRoadCount":2},
	{"id":"northgate","name":"Northgate","lineKey":"line3","stopIndex":3,"theme":"mixed","parentRoadId":"arterial-line3-2","branchSide":-1,"depth":320.0,"halfWidth":250.0,"crossRoadCount":2},
	{"id":"meadowEnd","name":"Meadow End","lineKey":"line3","stopIndex":4,"theme":"residential","parentRoadId":"arterial-line3-3","branchSide":1,"depth":360.0,"halfWidth":285.0,"crossRoadCount":2},
	{"id":"docklands","name":"Docklands","lineKey":"line4","stopIndex":1,"theme":"industrial","parentRoadId":"arterial-line4-0","branchSide":1,"depth":350.0,"halfWidth":165.0,"crossRoadCount":2},
	{"id":"eastgate","name":"Eastgate","lineKey":"line4","stopIndex":2,"theme":"mixed","parentRoadId":"arterial-line4-1","branchSide":-1,"depth":330.0,"halfWidth":275.0,"crossRoadCount":2},
	{"id":"stadium","name":"Stadium","lineKey":"line4","stopIndex":3,"theme":"central","parentRoadId":"arterial-line4-2","branchSide":1,"depth":350.0,"halfWidth":290.0,"crossRoadCount":3},
]

static func generate(seed: int) -> Dictionary:
	var roads := _primary_roads()
	var districts: Array = []
	var blocks: Array = []
	var parcels: Array = []
	var reservations := _reservations()
	var road_lookup := _index_by_id(roads)

	for spec_raw in DISTRICT_SPECS:
		var spec: Dictionary = spec_raw.duplicate(true)
		var district := _new_district(spec)
		var generated := _generate_district(seed, spec, roads, road_lookup, reservations)
		for road in generated["roads"]:
			roads.append(road)
			road_lookup[str(road["id"])] = road
			district["roadIds"].append(road["id"])

		for block in generated["blocks"]:
			blocks.append(block)
			district["blockIds"].append(block["id"])

		for parcel in generated["parcels"]:
			parcels.append(parcel)
			district["parcelIds"].append(parcel["id"])

		for road in roads:
			if str(road.get("districtId", "")) == str(spec["id"]) and not district["roadIds"].has(road["id"]):
				district["roadIds"].append(road["id"])

		districts.append(district)

	var graph := Topology.compile_graph(roads)

	return {
		"schemaVersion": 2,
		"source": "godot-native-plan-generator-v1",
		"seed": seed,
		"districts": districts,
		"roads": roads,
		"nodes": graph["nodes"],
		"graphEdges": graph["graphEdges"],
		"junctions": graph["junctions"],
		"blocks": blocks,
		"parcels": parcels,
		"reservations": reservations,
	}

static func _new_district(spec: Dictionary) -> Dictionary:
	return {
		"id": spec["id"],
		"name": spec["name"],
		"lineKey": spec["lineKey"],
		"stopIndex": spec["stopIndex"],
		"theme": spec["theme"],
		"status": "locked",
		"activatedAt": null,
		"developmentLevel": 0.0,
		"roadIds": [],
		"blockIds": [],
		"parcelIds": [],
	}

static func _primary_roads() -> Array:
	var roads: Array = []
	var old_town := Layout.stop_position("line1", 0)
	roads.append(_road(
		"arterial-oldTown-existing",
		"oldTown",
		"arterial",
		[old_town + Vector2(-380.0, 0.0), old_town],
		null,
		-20,
		"existing-arterial",
		[]
	))

	var district_by_line := {
		"line1": ["market", "park", "university", "central"],
		"line2": ["riverside", "museum", "harbor"],
		"line3": ["northQuarter", "hillcrest", "northgate", "meadowEnd"],
		"line4": ["docklands", "eastgate", "stadium", "central"],
	}

	for line_key in Data.LINE_KEYS:
		var count := int(Data.LINE_CONFIG[line_key]["max_stops"]) - 1
		for segment in range(count):
			var parent_id := ""
			if segment > 0:
				parent_id = "arterial-%s-%d" % [line_key, segment - 1]
			elif line_key == "line1":
				parent_id = "arterial-oldTown-existing"
			elif line_key == "line2":
				parent_id = "arterial-line1-1"
			elif line_key == "line3":
				parent_id = "arterial-line1-2"
			else:
				parent_id = "arterial-line2-2"

			roads.append(_road(
				"arterial-%s-%d" % [line_key, segment],
				district_by_line[line_key][segment],
				"arterial",
				Layout.segment_points(line_key, segment),
				{"lineKey": line_key, "stopCount": segment + 2},
				-10,
				"transport-corridor",
				[parent_id]
			))

	var depot_points := Layout.depot_spur()
	roads.append(_road(
		"depot-access",
		"park",
		"service",
		depot_points,
		{"requiresDepot": true},
		-5,
		"depot-access",
		["arterial-line1-1"]
	))
	return roads

static func _road(
	id: String,
	district_id: String,
	road_class: String,
	points: Array,
	unlock,
	build_order: int,
	source: String,
	parents: Array
) -> Dictionary:
	var serialized: Array = []
	for point in points:
		var value: Vector2 = point
		serialized.append({"x": value.x, "y": value.y})

	return {
		"id": id,
		"districtId": district_id,
		"class": road_class,
		"points": serialized,
		"unlock": unlock,
		"buildOrder": build_order,
		"source": source,
		"parentRoadIds": parents.duplicate(),
		"status": "planned",
		"constructionProgress": 0.0,
	}

static func _generate_district(
	seed: int,
	spec: Dictionary,
	existing_roads: Array,
	road_lookup: Dictionary,
	reservations: Array
) -> Dictionary:
	var parent: Dictionary = road_lookup.get(str(spec["parentRoadId"]), {})
	var stop := Layout.stop_position(str(spec["lineKey"]), int(spec["stopIndex"]))
	var tangent := _road_tangent_near(parent, stop)
	var outward := Vector2(-tangent.y, tangent.x) * float(spec["branchSide"])

	var preferred_score := _terrain_direction_score(seed, stop, outward, float(spec["depth"]))
	var alternate_score := _terrain_direction_score(seed, stop, -outward, float(spec["depth"]))
	if alternate_score + 1.4 < preferred_score:
		outward = -outward

	var district_roads: Array = []
	var collector_id := "collector-%s-main" % str(spec["id"])
	var collector := _road(
		collector_id,
		str(spec["id"]),
		"collector",
		[
			stop,
			stop + outward * float(spec["depth"]) * 0.52,
			stop + outward * float(spec["depth"]),
		],
		{"districtId": spec["id"]},
		0,
		"city",
		[str(spec["parentRoadId"])]
	)
	district_roads.append(collector)

	var cross_ids: Array[String] = []
	var cross_count := int(spec["crossRoadCount"])
	for index in range(cross_count):
		var t := float(index + 1) / float(cross_count + 1)
		var center := stop + outward * float(spec["depth"]) * t
		var jitter := (_unit_random(seed, "%s:cross:%d" % [spec["id"], index]) - 0.5) * 26.0
		center += outward * jitter
		var half_width := float(spec["halfWidth"]) * (0.82 + _unit_random(seed, "%s:width:%d" % [spec["id"], index]) * 0.18)
		var cross_id := "cross-%s-%d" % [spec["id"], index]
		var cross := _road(
			cross_id,
			str(spec["id"]),
			"local",
			[center - tangent * half_width, center + tangent * half_width],
			{"districtId": spec["id"]},
			10 + index,
			"city",
			[collector_id]
		)
		if not Topology.has_parallel_overlap(cross, existing_roads + district_roads, 5.0):
			district_roads.append(cross)
			cross_ids.append(cross_id)

	var local_offset := float(spec["halfWidth"]) * 0.58
	for side in [-1.0, 1.0]:
		var local_id := "local-%s-%s" % [spec["id"], "left" if side < 0.0 else "right"]
		var start: Vector2 = stop + outward * float(spec["depth"]) * 0.18 + tangent * local_offset * side
		var end: Vector2 = stop + outward * float(spec["depth"]) * 0.92 + tangent * local_offset * side
		var parents: Array = [collector_id]
		if not cross_ids.is_empty():
			parents = [cross_ids[0]]
		var local := _road(
			local_id,
			str(spec["id"]),
			"local",
			[start, end],
			{"districtId": spec["id"]},
			20,
			"city",
			parents
		)
		if not Topology.has_parallel_overlap(local, existing_roads + district_roads, 4.0):
			district_roads.append(local)

	if district_roads.size() < 3:
		for fallback_index in range(3 - district_roads.size()):
			var fraction := 0.38 + float(fallback_index) * 0.22
			var center := stop + outward * float(spec["depth"]) * fraction
			var service_id := "service-%s-fallback-%d" % [spec["id"], fallback_index]
			district_roads.append(_road(
				service_id,
				str(spec["id"]),
				"service",
				[
					center - tangent * float(spec["halfWidth"]) * 0.48,
					center + tangent * float(spec["halfWidth"]) * 0.48,
				],
				{"districtId": spec["id"]},
				30 + fallback_index,
				"city",
				[collector_id]
			))

	var blocks: Array = []
	var parcels: Array = []
	var parcel_serial := 1

	for road in district_roads:
		if str(road["class"]) not in ["local", "collector"]:
			continue
		var generated := _parcels_along_road(
			seed,
			spec,
			road,
			existing_roads + district_roads,
			reservations,
			parcel_serial
		)
		for block in generated["blocks"]:
			blocks.append(block)
		for parcel in generated["parcels"]:
			parcels.append(parcel)
		parcel_serial += int(generated["parcels"].size())

	if parcels.size() < 4:
		var fallback := _fallback_parcels(seed, spec, collector, reservations, parcel_serial)
		blocks.append_array(fallback["blocks"])
		parcels.append_array(fallback["parcels"])

	return {
		"roads": district_roads,
		"blocks": blocks,
		"parcels": parcels,
	}

static func _parcels_along_road(
	seed: int,
	spec: Dictionary,
	road: Dictionary,
	all_roads: Array,
	reservations: Array,
	start_serial: int
) -> Dictionary:
	var points: Array = road["points"]
	if points.size() < 2:
		return {"blocks": [], "parcels": []}

	var a := Vector2(float(points[0]["x"]), float(points[0]["y"]))
	var b := Vector2(float(points[points.size() - 1]["x"]), float(points[points.size() - 1]["y"]))
	var direction := (b - a).normalized()
	var normal := Vector2(-direction.y, direction.x)
	var length := a.distance_to(b)
	var spacing := 66.0 if str(spec["id"]) == "docklands" else (76.0 if str(spec["theme"]) == "central" else 86.0)
	var count := maxi(1, floori(length / spacing) - 1)
	var parcels: Array = []
	var blocks: Array = []

	for index in range(count):
		var along := float(index + 1) / float(count + 1)
		var center := a.lerp(b, along)
		for side in [-1.0, 1.0]:
			var serial := start_serial + parcels.size()
			var density := _density_for(spec, seed, serial)
			var zone := _zone_for(spec, seed, serial)
			var size := _footprint(str(spec["id"]), zone, density)
			var offset := Topology.road_half_width(str(road["class"])) + float(size.y) * 0.55 + 10.0
			var position: Vector2 = center + normal * offset * side
			position += direction * ((_unit_random(seed, "%s:parcel-jitter:%d" % [spec["id"], serial]) - 0.5) * 18.0)

			if not _parcel_allowed(seed, position, size, all_roads, reservations):
				continue

			var parcel_id := "parcel-%s-%d" % [spec["id"], serial]
			var block_id := "block-%s-%d" % [spec["id"], serial]
			var terrain_slope := Terrain.slope_degrees(seed, position.x, position.y)
			var forest := Terrain.forest_potential(seed, position.x, position.y)
			parcels.append({
				"id": parcel_id,
				"districtId": spec["id"],
				"blockId": block_id,
				"x": position.x,
				"y": position.y,
				"w": size.x,
				"h": size.y,
				"zone": zone,
				"density": density,
				"setback": 5.0 if density >= 3 else 7.0,
				"frontageRoadId": road["id"],
				"developmentOrder": float(serial) * 0.07 + _unit_random(seed, "%s:development:%d" % [spec["id"], serial]),
				"terrainSlope": terrain_slope,
				"forestPressure": forest,
				"status": "vacant",
				"reservedAt": null,
				"buildingId": null,
			})
			blocks.append({
				"id": block_id,
				"districtId": spec["id"],
				"status": "locked",
				"roadIds": [road["id"]],
				"parcelIds": [parcel_id],
			})

	return {"blocks": blocks, "parcels": parcels}

static func _fallback_parcels(
	seed: int,
	spec: Dictionary,
	collector: Dictionary,
	reservations: Array,
	start_serial: int
) -> Dictionary:
	var points: Array = collector["points"]
	var a := Vector2(float(points[0]["x"]), float(points[0]["y"]))
	var b := Vector2(float(points[points.size() - 1]["x"]), float(points[points.size() - 1]["y"]))
	var direction := (b - a).normalized()
	var normal := Vector2(-direction.y, direction.x)
	var parcels: Array = []
	var blocks: Array = []

	var candidate_index := 0
	while parcels.size() < 6 and candidate_index < 18:
		var serial := start_serial + candidate_index
		var column := candidate_index % 5
		var side := -1.0 if candidate_index % 2 == 0 else 1.0
		var t := 0.14 + float(column) * 0.18
		var density := _density_for(spec, seed, serial)
		var zone := _zone_for(spec, seed, serial)
		var size := _footprint(str(spec["id"]), zone, density)
		var extra_offset := float(candidate_index / 10) * 28.0
		var position := a.lerp(b, t) + normal * (
			Topology.road_half_width("collector")
			+ size.y * 0.65
			+ 14.0
			+ extra_offset
		) * side

		candidate_index += 1
		if _inside_reservation(position, size, reservations):
			continue

		var parcel_id := "parcel-%s-%d" % [spec["id"], serial]
		var block_id := "block-%s-%d" % [spec["id"], serial]
		parcels.append({
			"id": parcel_id,
			"districtId": spec["id"],
			"blockId": block_id,
			"x": position.x,
			"y": position.y,
			"w": size.x,
			"h": size.y,
			"zone": zone,
			"density": density,
			"setback": 6.0,
			"frontageRoadId": collector["id"],
			"developmentOrder": float(candidate_index) * 0.12,
			"terrainSlope": Terrain.slope_degrees(seed, position.x, position.y),
			"forestPressure": Terrain.forest_potential(seed, position.x, position.y),
			"status": "vacant",
			"reservedAt": null,
			"buildingId": null,
		})
		blocks.append({
			"id": block_id,
			"districtId": spec["id"],
			"status": "locked",
			"roadIds": [collector["id"]],
			"parcelIds": [parcel_id],
		})

	return {"blocks": blocks, "parcels": parcels}

static func _parcel_allowed(
	seed: int,
	position: Vector2,
	size: Vector2,
	roads: Array,
	reservations: Array
) -> bool:
	if Terrain.slope_degrees(seed, position.x, position.y) >= 17.0:
		return false
	if _inside_reservation(position, size, reservations):
		return false

	var radius: float = maxf(size.x, size.y) * 0.44
	for road in roads:
		var closest := Topology.closest_point_on_road(position, road)
		if closest.is_empty():
			continue
		var minimum: float = radius + Topology.road_half_width(str(road.get("class", "local"))) + 5.0
		if float(closest["distance"]) < minimum and str(road.get("id", "")) != "":
			var frontage_relax := str(road.get("class", "")) in ["local", "collector"]
			if not frontage_relax or float(closest["distance"]) < Topology.road_half_width(str(road.get("class", "local"))) + 4.0:
				return false
	return true

static func _inside_reservation(position: Vector2, size: Vector2, reservations: Array) -> bool:
	for reservation in reservations:
		var center := Vector2(float(reservation["x"]), float(reservation["y"]))
		var half := Vector2(float(reservation["w"]), float(reservation["h"])) * 0.5
		var parcel_half := size * 0.5
		if (
			abs(position.x - center.x) <= half.x + parcel_half.x
			and abs(position.y - center.y) <= half.y + parcel_half.y
		):
			return true
	return false

static func _terrain_direction_score(seed: int, start: Vector2, direction: Vector2, depth: float) -> float:
	var total := 0.0
	for index in range(1, 6):
		var point := start + direction * depth * float(index) / 5.0
		total += Terrain.slope_degrees(seed, point.x, point.y) * 1.8
		total += Terrain.forest_potential(seed, point.x, point.y) * 8.0
	return total / 5.0

static func _road_tangent_near(road: Dictionary, point: Vector2) -> Vector2:
	if road.is_empty():
		return Vector2.RIGHT
	var closest := Topology.closest_point_on_road(point, road)
	var points: Array = road.get("points", [])
	var index := int(closest.get("segment_index", 0))
	if points.size() < 2:
		return Vector2.RIGHT
	index = clampi(index, 0, points.size() - 2)
	var a := Vector2(float(points[index]["x"]), float(points[index]["y"]))
	var b := Vector2(float(points[index + 1]["x"]), float(points[index + 1]["y"]))
	var tangent := (b - a).normalized()
	return Vector2.RIGHT if tangent.length_squared() <= 0.000001 else tangent

static func _zone_for(spec: Dictionary, seed: int, serial: int) -> String:
	var roll := _unit_random(seed, "%s:zone:%d" % [spec["id"], serial])
	match str(spec["theme"]):
		"industrial":
			return "industrial" if roll < 0.68 else "mixed"
		"campus":
			return "civic" if roll < 0.55 else ("mixed" if roll < 0.8 else "residential")
		"central":
			return "commercial" if roll < 0.45 else ("mixed" if roll < 0.82 else "residential")
		"mixed":
			return "mixed" if roll < 0.52 else ("commercial" if roll < 0.72 else "residential")
		"park":
			return "residential" if roll < 0.62 else "mixed"
		_:
			return "residential" if roll < 0.75 else "mixed"

static func _density_for(spec: Dictionary, seed: int, serial: int) -> int:
	var roll := _unit_random(seed, "%s:density:%d" % [spec["id"], serial])
	match str(spec["theme"]):
		"central":
			return 3 + (1 if roll > 0.5 else 0)
		"campus", "mixed":
			return 2 + (1 if roll > 0.58 else 0)
		"industrial":
			return 1 + (1 if roll > 0.58 else 0) + (1 if roll > 0.88 else 0)
		_:
			return 1 + (1 if roll > 0.72 else 0)

static func _footprint(district_id: String, zone: String, density: int) -> Vector2:
	if district_id == "docklands":
		if zone == "industrial":
			return Vector2(48.0, 36.0)
		return Vector2(40.0, 34.0)
	if zone == "industrial":
		return Vector2(66.0, 50.0)
	if density >= 4:
		return Vector2(48.0, 44.0)
	if density >= 3:
		return Vector2(44.0, 40.0)
	if zone == "commercial" or zone == "mixed":
		return Vector2(40.0, 36.0)
	return Vector2(38.0, 34.0)

static func _reservations() -> Array:
	var depot := Layout.depot_position()
	var park := Layout.stop_position("line1", 2)
	return [
		{"id":"reservation-depot","x":depot.x,"y":depot.y,"w":150.0,"h":118.0,"type":"facility"},
		{"id":"reservation-city-park","x":park.x + 96.0,"y":park.y - 80.0,"w":165.0,"h":145.0,"type":"park"},
	]

static func _index_by_id(items: Array) -> Dictionary:
	var result := {}
	for item in items:
		result[str(item["id"])] = item
	return result

static func _unit_random(seed: int, key: String) -> float:
	return float(_hash32("%s:%s" % [seed, key])) / 4294967295.0

static func _hash32(value: String) -> int:
	var hash_value: int = 2166136261
	for index in range(value.length()):
		hash_value = (hash_value ^ value.unicode_at(index)) & 0xffffffff
		hash_value = (hash_value * 16777619) & 0xffffffff
	return hash_value
