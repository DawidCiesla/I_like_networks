extends SceneTree

const GameStoreScript = preload("res://scripts/core/game_store.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")

var failures := 0


func _initialize() -> void:
	var store = GameStoreScript.new()
	store.suppress_persistence = true
	store.city_seed = 731945
	store.reset_state(false)
	store.money = 10000000.0
	store.city["demographics"]["residents"] = 100000
	store.depot["built"] = true
	store.depot["garage_slots"] = 4

	_test_unlock_readiness_includes_minimum_line_capital(store)
	_test_bus_tram_corridors_and_atomic_track_reservation(store)
	_test_metro_is_grade_separated_and_uses_independent_stations(store)

	store.free()
	if failures == 0:
		print("Transit modes GameStore tests: PASS")
		quit(0)
	else:
		push_error("Transit modes GameStore tests: %d failure(s)" % failures)
		quit(1)


func _test_unlock_readiness_includes_minimum_line_capital(store) -> void:
	var original_money: float = store.money
	var original_unlocks: Dictionary = store.transit_network.get("unlocked_modes", {"bus": true}).duplicate(true)
	var unlocks: Dictionary = {"bus": true}
	store.transit_network["unlocked_modes"] = unlocks
	for mode in ["tram", "metro"]:
		var profile: Dictionary = store.transit_mode_profile(mode)
		var licence_cost := float(profile.get("unlock_cost", 0.0))
		var minimum_spacing := float(profile.get("minimum_stop_spacing", 1.0))
		var route: Array[Vector2] = [Vector2.ZERO, Vector2(minimum_spacing, 0.0)]
		store.money = 10000000.0
		var full_build_cost := float(store.free_line_build_cost(route, [], mode))
		var expected_line_cost := full_build_cost - licence_cost
		var expected_startup := expected_line_cost + licence_cost
		var status_with_funds: Dictionary = store.transit_mode_status(mode)
		_expect(is_equal_approx(float(status_with_funds.get("minimum_line_cost", -1.0)), expected_line_cost), "%s estimates its minimum legal line cost from the actual construction formula" % mode)
		_expect(is_equal_approx(float(status_with_funds.get("minimum_startup_capital", -1.0)), expected_startup), "%s includes both licence and minimum route capital" % mode)
		store.money = licence_cost
		var licence_only: Dictionary = store.transit_mode_status(mode)
		_expect(not bool(licence_only.get("unlocked", true)), "%s is not advertised as build-ready with licence funds alone" % mode)
		store.money = expected_startup
		_expect(bool(store.transit_mode_status(mode).get("unlocked", false)), "%s is build-ready at its minimum startup capital" % mode)
	store.money = original_money
	store.transit_network["unlocked_modes"] = original_unlocks


func _test_bus_tram_corridors_and_atomic_track_reservation(store) -> void:
	var road_fixture := _first_built_road_segment(store.city, 220.0, 1200.0)
	_expect(not road_fixture.is_empty(), "regional starter has a built corridor long enough for a tram stop pair")
	if road_fixture.is_empty():
		return
	var road_id := str(road_fixture["road_id"])
	var points: Array[Vector2] = []
	for point_value in road_fixture["points"]:
		points.append(point_value)
	_expect(_build_line(store, "bus", points), "player can establish the starter bus line on a built road")
	var bus_line_id := TransitNetwork.custom_line_ids(store.transit_network)[0]
	var bus_line: Dictionary = store.transit_line(bus_line_id)
	_expect(str(bus_line.get("mode", "")) == "bus", "new bus line persists its mode")

	var road: Dictionary = _road_by_id(store.city, road_id)
	var original_profile: Dictionary = road.get("profile", {}).duplicate(true)
	var invalid_profile := original_profile.duplicate(true)
	invalid_profile["speed_kph"] = 999.0
	road["profile"] = invalid_profile
	store.selected_transit_mode = "tram"
	_expect(store.begin_free_line_editor(), "tram route editor opens after population and treasury unlock requirements are met")
	_expect(_add_route_points(store, points), "tram stops can be placed on the selected built corridor")
	var money_before: float = store.money
	var lines_before := TransitNetwork.custom_line_ids(store.transit_network).size()
	_expect(not store.commit_route_editor(), "tram route rejects a road whose profile cannot reserve tracks")
	_expect(store.money == money_before, "a rejected tram corridor charges no construction cost")
	_expect(TransitNetwork.custom_line_ids(store.transit_network).size() == lines_before, "a rejected tram corridor creates no active line")
	_expect(not bool(road.get("tram_reservation", false)), "a rejected tram corridor leaves no partial track reservation")
	store.cancel_route_editor()
	road["profile"] = original_profile

	store.selected_transit_mode = "tram"
	_expect(store.begin_free_line_editor(), "tram editor remains available after fixing the road profile")
	_expect(_add_route_points(store, points), "tram stops are accepted on the restored corridor")
	_expect(store.commit_route_editor(), "valid tram corridor commits")
	var tram_line_ids := TransitNetwork.custom_line_ids(store.transit_network)
	_expect(tram_line_ids.size() == lines_before + 1, "tram is stored as its own custom transit line")
	var tram_line_id := str(tram_line_ids.back())
	var tram_line: Dictionary = store.transit_line(tram_line_id)
	_expect(str(tram_line.get("mode", "")) == "tram", "tram line keeps the tram operating profile")
	_expect(store.transit_vehicle_name(tram_line_id) == "tram", "tram fleet controls use the tram vehicle name")
	_expect(
		store.transit_vehicle_purchase_cost(tram_line_id) > store.vehicle_purchase_cost(),
		"tram fleet cost uses the tram construction multiplier"
	)
	_expect(not bool(tram_line.get("grade_separated", true)), "tram remains a surface transit mode")
	var bus_stops := TransitNetwork.line_stop_ids(store.transit_network, bus_line_id)
	var tram_stops := TransitNetwork.line_stop_ids(store.transit_network, tram_line_id)
	_expect(bus_stops[0] != tram_stops[0], "a bus stop is not reused as a tram stop at the same location")
	var reserved_profile: Dictionary = _road_by_id(store.city, road_id).get("profile", {})
	_expect(bool(reserved_profile.get("tram_reservation", false)), "committed tram writes a track reservation onto its road")
	var tram_lanes := 0
	for lane_value in reserved_profile.get("lanes", []):
		if str(lane_value.get("type", "")) == "tram":
			tram_lanes += 1
	_expect(tram_lanes >= 2, "committed tram road has two directional tram lanes")


func _test_metro_is_grade_separated_and_uses_independent_stations(store) -> void:
	var bus_line_ids := TransitNetwork.custom_line_ids(store.transit_network)
	var bus_line_id := ""
	for line_id_value in bus_line_ids:
		var candidate: Dictionary = store.transit_line(str(line_id_value))
		if str(candidate.get("mode", "bus")) == "bus":
			bus_line_id = str(line_id_value)
			break
	_expect(not bus_line_id.is_empty(), "bus route remains available before adding metro")
	if bus_line_id.is_empty():
		return
	var bus_stop_id := TransitNetwork.line_stop_ids(store.transit_network, bus_line_id)[0]
	var bus_position := TransitNetwork.stop_position(store.transit_network, bus_stop_id)
	var map_bounds := TerrainSurface.world_bounds()
	var metro_end := _inside_metro_target(bus_position, map_bounds)
	_expect(bus_position.distance_to(metro_end) >= 600.0 and bus_position.distance_to(metro_end) <= 2800.0, "metro test station pair respects the designed spacing range")
	if is_zero_approx(bus_position.distance_to(metro_end)):
		return
	store.selected_transit_mode = "metro"
	_expect(store.transit_mode_status("metro").get("unlocked", false), "metro unlocks when the region meets population and treasury requirements")
	_expect(store.begin_free_line_editor(), "metro line editor opens when unlocked")
	_expect(_add_route_points(store, [bus_position, metro_end]), "metro stations can be placed without road snapping")
	_expect(store.commit_route_editor(), "grade-separated metro line commits without a road corridor")
	var metro_line_id := ""
	for line_id_value in TransitNetwork.custom_line_ids(store.transit_network):
		var candidate: Dictionary = store.transit_line(str(line_id_value))
		if str(candidate.get("mode", "")) == "metro":
			metro_line_id = str(line_id_value)
			break
	_expect(not metro_line_id.is_empty(), "metro line is present in the transit network")
	if metro_line_id.is_empty():
		return
	var metro_line: Dictionary = store.transit_line(metro_line_id)
	_expect(store.transit_vehicle_name(metro_line_id) == "train", "metro fleet controls use the train vehicle name")
	_expect(
		store.transit_vehicle_purchase_cost(metro_line_id) > store.vehicle_purchase_cost(),
		"metro fleet cost uses the metro construction multiplier"
	)
	var metro_stop_ids := TransitNetwork.line_stop_ids(store.transit_network, metro_line_id)
	var metro_stops: Dictionary = store.transit_network.get("stops", {})
	_expect(bool(metro_line.get("grade_separated", false)), "metro line stores its grade-separated contract")
	_expect(bus_stop_id not in metro_stop_ids, "metro does not absorb a nearby bus stop into its station identity")
	var all_underground := true
	var all_accessible := true
	for stop_id in metro_stop_ids:
		var stop: Dictionary = metro_stops.get(stop_id, {})
		all_underground = all_underground and int(stop.get("concourse_level", 0)) == -1
		all_accessible = all_accessible and bool(stop.get("accessible", false))
	_expect(all_underground, "metro stations expose underground concourses")
	_expect(all_accessible, "metro stations meet accessibility requirements")
	var segments: Array = metro_line.get("route_segments", [])
	_expect(segments.size() == 1, "two metro stations create one route segment")
	if segments.size() == 1:
		var segment: Dictionary = segments[0]
		_expect(bool(segment.get("grade_separated", false)) and bool(segment.get("underground", false)), "metro segment remains grade-separated and underground")
		_expect(int(segment.get("level", 0)) == -1, "metro segment is stored below the surface road level")
		_expect(segment.get("road_ids", []).is_empty(), "metro does not create false surface road links")


func _build_line(store, mode: String, points: Array[Vector2]) -> bool:
	store.selected_transit_mode = mode
	if not store.begin_free_line_editor() or not _add_route_points(store, points):
		return false
	return store.commit_route_editor()


func _add_route_points(store, points: Array[Vector2]) -> bool:
	for point in points:
		if not store.route_editor_add_point(point):
			return false
	return true


func _first_built_road_segment(city: Dictionary, minimum: float, maximum: float) -> Dictionary:
	var roads_by_id: Dictionary = {}
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		roads_by_id[str(road.get("id", ""))] = road
	var nodes_by_id: Dictionary = {}
	for node_value in city.get("nodes", []):
		var node: Dictionary = node_value
		nodes_by_id[str(node.get("id", ""))] = Vector2(float(node.get("x", 0.0)), float(node.get("y", 0.0)))
	for edge_value in city.get("graph_edges", []):
		var edge: Dictionary = edge_value
		var road: Dictionary = roads_by_id.get(str(edge.get("roadId", "")), {})
		if str(road.get("status", "")) != "built":
			continue
		var start: Vector2 = nodes_by_id.get(str(edge.get("a", "")), Vector2.ZERO)
		var finish: Vector2 = nodes_by_id.get(str(edge.get("b", "")), Vector2.ZERO)
		var length := start.distance_to(finish)
		if length >= minimum and length <= maximum:
			return {"road_id": str(road.get("id", "")), "points": [start, finish]}
	return {}


func _road_by_id(city: Dictionary, road_id: String) -> Dictionary:
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("id", "")) == road_id:
			return road
	return {}


func _inside_metro_target(origin: Vector2, bounds: Rect2) -> Vector2:
	for direction in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN, Vector2(1, 1).normalized(), Vector2(-1, 1).normalized(), Vector2(1, -1).normalized(), Vector2(-1, -1).normalized()]:
		var candidate: Vector2 = origin + direction * 1400.0
		if bounds.has_point(candidate) and origin.distance_to(candidate) >= 600.0:
			return candidate
	return Vector2.ZERO


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	failures += 1
	push_error("Transit modes GameStore: %s" % description)
