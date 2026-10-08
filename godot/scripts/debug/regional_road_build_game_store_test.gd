extends SceneTree

const GameStoreScript = preload("res://scripts/core/game_store.gd")
const CityRuntime = preload("res://scripts/city/city_runtime.gd")

var _failures := 0


func _initialize() -> void:
	var store = GameStoreScript.new()
	store.suppress_persistence = true
	store.reset_state(false)
	_test_frontier_corridor_opens_regional_growth(store)
	store.free()
	if _failures == 0:
		print("Regional road construction GameStore tests: PASS")
		quit(0)
	else:
		push_error("Regional road construction GameStore tests: %d failure(s)" % _failures)
		quit(1)


func _test_frontier_corridor_opens_regional_growth(store) -> void:
	var frontier_id := ""
	var frontier_role := ""
	var disconnected_id := ""
	for road_value in store.city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("source", "")) != "regional-existing" or str(road.get("status", "")) != "planned":
			continue
		var road_id := str(road.get("id", ""))
		var status: Dictionary = store.regional_road_build_status(road_id)
		if bool(status.get("available", false)):
			if frontier_id.is_empty() or str(road.get("regionalRole", "")) == "spine":
				frontier_id = road_id
				frontier_role = str(road.get("regionalRole", ""))
		elif str(status.get("reason", "")) == "not_connected_to_built_network":
			disconnected_id = road_id
	_expect(not frontier_id.is_empty(), "fresh regional map exposes at least one generated corridor from its built road network")
	_expect(frontier_role == "spine", "the starter exposes a strategic settlement connection to build")
	if frontier_id.is_empty():
		return
	var funds_before := float(store.money)
	if not disconnected_id.is_empty():
		_expect(not store.build_regional_road(disconnected_id), "a disconnected regional corridor cannot be started out of order")
		_expect(is_equal_approx(float(store.money), funds_before), "a rejected disconnected corridor charges no money")

	var construction: Dictionary = store.regional_road_build_status(frontier_id)
	var cost := float(construction.get("cost", 0.0))
	var settlement_to_open := str(construction.get("new_node", ""))
	_expect(cost > 0.0 and cost < funds_before, "the frontier corridor has a payable terrain-generated construction cost")
	_expect(store.build_regional_road(frontier_id), "the player can start a connected strategic regional road")
	_expect(is_equal_approx(float(store.money), funds_before - cost), "the corridor charges its displayed cost exactly once")
	var pending: Dictionary = store.regional_road_build_status(frontier_id)
	_expect(bool(pending.get("pending", false)), "the selected connection remains inspectable while construction is queued")

	for _step in range(1000):
		if str(_road_by_id(store.city, frontier_id).get("status", "")) == "built":
			break
		CityRuntime.advance(store, 0.2)
	_expect(str(_road_by_id(store.city, frontier_id).get("status", "")) == "built", "the road project completes on simulated time")
	var newly_reachable_local_road := false
	for road_value in store.city.get("roads", []):
		var road: Dictionary = road_value
		if str(road.get("regionalRole", "")) != "local_street" or str(road.get("status", "")) != "planned":
			continue
		if str(road.get("a", "")) != settlement_to_open and str(road.get("b", "")) != settlement_to_open:
			continue
		if bool(store.regional_road_build_status(str(road.get("id", ""))).get("available", false)):
			newly_reachable_local_road = true
			break
	_expect(newly_reachable_local_road, "connecting a settlement unlocks its local streets for player-funded construction")


func _road_by_id(city: Dictionary, road_id: String) -> Dictionary:
	for road_value in city.get("roads", []):
		if str(road_value.get("id", "")) == road_id:
			return road_value
	return {}


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional road construction GameStore: %s" % description)
