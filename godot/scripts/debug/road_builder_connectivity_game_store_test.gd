extends SceneTree

const GameStoreScript = preload("res://scripts/core/game_store.gd")
const CityRuntime = preload("res://scripts/city/city_runtime.gd")
const RoadTopology = preload("res://scripts/city/road_topology.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")

var _failures := 0


func _initialize() -> void:
	var store = GameStoreScript.new()
	store.suppress_persistence = true
	store.reset_state(false)
	_test_player_connector_reaches_named_frontier_and_growth(store)
	store.free()
	if _failures == 0:
		print("Road builder connectivity GameStore tests: PASS")
		quit(0)
	else:
		push_error("Road builder connectivity GameStore tests: %d failure(s)" % _failures)
		quit(1)


func _test_player_connector_reaches_named_frontier_and_growth(store) -> void:
	var settlements: Array = store.city.get("regional_settlements", [])
	_expect(not settlements.is_empty(), "the regional map has a named starter settlement")
	if settlements.is_empty():
		return
	var starter_id := str(settlements[0].get("id", ""))
	var frontier_id := "settlement-player-frontier-regression"
	var frontier_road_id := "regional-frontier-player-regression"
	var fixture := _find_grade_safe_points(int(store.city_seed))
	_expect(not fixture.is_empty(), "the fixed seed has a grade-safe route-builder fixture")
	if fixture.is_empty():
		return
	var start: Vector2 = fixture["start"]
	var finish: Vector2 = fixture["finish"]

	var start_road := {
		"id": "starter-access-regression",
		"a": starter_id,
		"b": "starter-local-regression",
		"settlementId": starter_id,
		"class": "local",
		"regionalRole": "local_street",
		"source": "regional-existing",
		"status": "built",
		"level": 0.0,
		"points": [_point(start), _point(start + Vector2(18.0, 0.0))],
	}
	var frontier_road := {
		"id": frontier_road_id,
		"a": frontier_id,
		"b": "frontier-external-gate",
		"settlementId": frontier_id,
		"class": "local",
		"regionalRole": "local_street",
		"source": "regional-existing",
		"status": "built",
		"level": 0.0,
		"points": [_point(finish), _point(finish + Vector2(18.0, 0.0))],
	}
	store.city["roads"] = [start_road, frontier_road]
	var graph := RoadTopology.compile_graph(store.city["roads"])
	store.city["nodes"] = graph.get("nodes", [])
	store.city["graph_edges"] = graph.get("graphEdges", [])
	store.city["junctions"] = graph.get("junctions", [])
	store.city["projects"] = []
	store.city["parcels"] = [{
		"id": "frontier-growth-parcel",
		"districtId": frontier_id,
		"x": finish.x + 24.0,
		"y": finish.y + 18.0,
		"zone": "residential",
		"status": "vacant",
		"frontageRoadId": frontier_road_id,
		"growthOrder": 0,
		"developmentOrder": 0,
		"density": 1,
	}]
	store.city["buildings"] = []
	store.city["regional_settlements"].append({
		"id": frontier_id,
		"name": "Frontier Test",
		"tier": "village",
		"population": 0,
		"jobs": 0,
		"position": finish,
	})
	store.city["districts"].append({
		"id": frontier_id,
		"name": "Frontier Test",
		"population": 0,
		"jobs": 0,
		"status": "active",
	})
	var target_parcel: Dictionary = store.city["parcels"][0]
	_expect(not CityRuntime._regional_parcel_has_strategic_access(store.city, target_parcel), "the named frontier starts disconnected from the starter region")

	_expect(store.begin_road_builder("collector"), "the player can begin a collector road")
	_expect(store.road_builder_add_point(start), "the first point snaps to the starter settlement road")
	_expect(store.road_builder_add_point(finish), "the second point snaps to the named regional frontier")
	var preview: Dictionary = store.road_builder_preview()
	_expect(bool(preview.get("ok", false)), "the player road between the named regions passes validation")
	_expect(str(preview.get("a", "")) == starter_id, "the first snapped endpoint resolves to its named starter graph node")
	_expect(str(preview.get("b", "")) == frontier_id, "the frontier endpoint resolves to its named settlement graph node")
	_expect(store.commit_road_builder(), "the player can commit the connector road")

	var player_road: Dictionary = {}
	for road_value in store.city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("source", "")) == "player":
			player_road = road
			break
	_expect(not player_road.is_empty(), "commit creates the player-authored road")
	if player_road.is_empty():
		return
	_expect(str(player_road.get("a", "")) == starter_id, "the saved road carries the starter graph endpoint ID")
	_expect(str(player_road.get("b", "")) == frontier_id, "the saved road carries the named frontier graph endpoint ID")
	_expect(
		player_road.get("graphEndpointIds", []) == [starter_id, frontier_id],
		"the saved road preserves its endpoint pair as explicit graph metadata"
	)

	# First finish construction at ordinary frame cadence. Organic regional
	# development intentionally runs much slower than the old 180 s auto-growth
	# path, so after the connector exists we advance a few explicit organic ticks
	# to verify that accessibility causes the frontier to develop.
	for _step in range(1600):
		CityRuntime.advance(store, 0.2)
		if str(player_road.get("status", "")) == "built":
			break
	_expect(str(player_road.get("status", "")) == "built", "the connector finishes construction")
	_expect(CityRuntime._regional_parcel_has_strategic_access(store.city, target_parcel), "the completed player road opens strategic access at the named frontier")

	for _growth_tick in range(4):
		if str(target_parcel.get("status", "")) == "built":
			break
		CityRuntime.advance(store, CityRuntime.REGIONAL_ORGANIC_GROWTH_INTERVAL_SECONDS)

	_expect(str(target_parcel.get("status", "")) == "built", "organic growth occupies the newly connected frontier parcel")
	var frontier: Dictionary = {}
	for settlement in store.city.get("regional_settlements", []):
		if str(settlement.get("id", "")) == frontier_id:
			frontier = settlement
			break
	_expect(int(frontier.get("population", 0)) > 0, "organic growth increases the connected frontier population")
	_expect(int(store.city.get("regional_auto_growth_count", 0)) == 0, "legacy regional auto-growth remains inactive")


func _find_grade_safe_points(seed: int) -> Dictionary:
	var bounds := TerrainSurface.world_bounds()
	var distances := [180.0, 240.0, 320.0, 450.0, 620.0, 820.0]
	for y_index in range(1, 6):
		var y := bounds.position.y + float(y_index) * bounds.size.y / 6.0
		for x_index in range(1, 6):
			var x := bounds.position.x + float(x_index) * bounds.size.x / 6.0
			for distance in distances:
				var start := Vector2(x, y)
				var finish := start + Vector2(distance, 0.0)
				if not bounds.has_point(finish):
					continue
				if _grade_is_valid(seed, start, finish):
					return {"start": start, "finish": finish}
	return {}


func _grade_is_valid(seed: int, start: Vector2, finish: Vector2) -> bool:
	var length := start.distance_to(finish)
	var steps := maxi(1, ceili(length / 70.0))
	var previous := TerrainSurface.height(seed, start.x, start.y)
	for index in range(1, steps + 1):
		var point := start.lerp(finish, float(index) / float(steps))
		var height := TerrainSurface.height(seed, point.x, point.y)
		if absf(height - previous) / (length / float(steps)) > 0.24:
			return false
		previous = height
	return true


func _point(value: Vector2) -> Dictionary:
	return {"x": value.x, "y": value.y}


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Road builder connectivity GameStore: %s" % description)
