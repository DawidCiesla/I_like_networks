extends SceneTree

const CityRuntime = preload("res://scripts/city/city_runtime.gd")
const RegionalHighwayPlanner = preload("res://scripts/city/regional_highway_planner.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")

var _failures := 0


func _init() -> void:
	var city := CityRuntime.create_initial_city(731945, MapDefinition.DEFAULT_MAP_ID)
	_assert_no_legacy_upgrade_hints(city)
	var road := _first_intercity_road(city)
	_expect(not road.is_empty(), "regional map exposes an intercity strategic road")
	if road.is_empty():
		_finish()
		return

	var a := _settlement(city, str(road.get("a", "")))
	var b := _settlement(city, str(road.get("b", "")))
	_expect(not a.is_empty() and not b.is_empty(), "strategic road connects two real settlements")
	var road_class_before := str(road.get("class", ""))
	var road_status_before := str(road.get("status", ""))
	var points_before: Array = road.get("points", []).duplicate(true)

	# Simulate later-game city scale. Highway need should create a separate
	# planning alignment rather than mutating the existing inhabited road.
	for settlement_value in city.get("regional_settlements", []):
		var settlement: Dictionary = settlement_value
		settlement["population"] = 65000
		settlement["jobs"] = 30000
		settlement["built_up_radius_m"] = 2600.0

	var changed := RegionalHighwayPlanner.refresh(city)
	_expect(changed, "large-city demand creates new infrastructure planning state")
	_expect(str(road.get("class", "")) == road_class_before, "existing regional road is never converted into a motorway")
	_expect(str(road.get("status", "")) == road_status_before, "existing regional road remains physically intact")
	_expect(road.get("points", []) == points_before, "existing regional-road geometry is preserved")
	_expect(not road.has("upgradeRecommendation"), "legacy in-place road upgrade recommendation is removed")
	_expect(float(road.get("capacityPressure", 0.0)) > 0.0, "existing road only records capacity pressure")
	_expect(bool(road.get("preserveExistingRoad", false)), "capacity analysis explicitly preserves roadside development corridor")

	var corridor := _proposal_for_road(city, str(road.get("id", "")))
	_expect(not corridor.is_empty(), "capacity need creates a separate relief-corridor proposal")
	if not corridor.is_empty():
		_expect(str(corridor.get("projectClass", "")) in ["bypass", "expressway", "motorway"], "proposal selects a separate high-capacity project class")
		_expect(bool(corridor.get("preserveExistingRoad", false)), "proposal leaves the old regional road in service")
		_expect(not bool(corridor.get("autoBuild", true)), "proposal can never auto-build a motorway")
		_expect(not bool(corridor.get("constructionAuthorized", true)), "planning does not authorize construction")
		_expect(str(corridor.get("designPrinciple", "")) == "new_outer_alignment", "intercity project uses a new outer alignment")
		var proposal_points: Array = corridor.get("points", [])
		_expect(proposal_points.size() >= 5, "outer corridor stores a multi-point bypass alignment")
		if proposal_points.size() >= 5:
			_expect(_minimum_distance(proposal_points, a.get("position", Vector2.ZERO)) > float(a.get("built_up_radius_m", 0.0)), "corridor stays outside the first city's built-up area")
			_expect(_minimum_distance(proposal_points, b.get("position", Vector2.ZERO)) > float(b.get("built_up_radius_m", 0.0)), "corridor stays outside the second city's built-up area")

	var rings := 0
	for proposal_value in city.get("infrastructure_proposals", []):
		var proposal: Dictionary = proposal_value
		if str(proposal.get("type", "")) != "urban_orbital":
			continue
		rings += 1
		_expect(str(proposal.get("designPrinciple", "")) == "orbital_outside_built_up_area", "ring proposal is explicitly routed outside urban fabric")
		_expect(not bool(proposal.get("autoBuild", true)), "municipal ring study still cannot auto-build")
	_expect(rings > 0, "mature multi-corridor cities can generate outer-ring planning studies")
	_finish()


func _assert_no_legacy_upgrade_hints(city: Dictionary) -> void:
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("regionalRole", "")) not in ["spine", "loop", "external_branch", "city_connector"]:
			continue
		_expect(not road.has("upgradeRecommendation"), "strategic roads expose no legacy in-place upgrade recommendation")
		_expect(not road.has("upgradePressure"), "strategic roads expose no legacy in-place upgrade pressure")
		_expect(bool(road.get("preserveExistingRoad", false)), "strategic roads are explicitly preserved")


func _first_intercity_road(city: Dictionary) -> Dictionary:
	var settlement_ids: Dictionary = {}
	for settlement_value in city.get("regional_settlements", []):
		var settlement: Dictionary = settlement_value
		settlement_ids[str(settlement.get("id", ""))] = true
	for road_value in city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("regionalRole", "")) not in ["spine", "loop", "city_connector"]:
			continue
		if settlement_ids.has(str(road.get("a", ""))) and settlement_ids.has(str(road.get("b", ""))):
			return road
	return {}


func _proposal_for_road(city: Dictionary, road_id: String) -> Dictionary:
	for proposal_value in city.get("infrastructure_proposals", []):
		var proposal: Dictionary = proposal_value
		if str(proposal.get("sourceCorridorRoadId", "")) == road_id:
			return proposal
	return {}


func _settlement(city: Dictionary, settlement_id: String) -> Dictionary:
	for settlement_value in city.get("regional_settlements", []):
		var settlement: Dictionary = settlement_value
		if str(settlement.get("id", "")) == settlement_id:
			return settlement
	return {}


func _minimum_distance(points: Array, center: Vector2) -> float:
	var result := INF
	for point_value in points:
		var point := Vector2(float(point_value.get("x", 0.0)), float(point_value.get("y", 0.0)))
		result = minf(result, point.distance_to(center))
	return result


func _finish() -> void:
	if _failures > 0:
		push_error("REGIONAL HIGHWAY PLANNER TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL HIGHWAY PLANNER TEST: PASS")
	quit(0)


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional highway planner: %s" % description)
