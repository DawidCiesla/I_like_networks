extends SceneTree

const Data = preload("res://scripts/core/game_data.gd")
const GameStoreScript = preload("res://scripts/core/game_store.gd")
const RegionalTrafficRuntime = preload("res://scripts/simulation/regional_traffic_runtime.gd")
const RegionalTransitTrafficRuntime = preload("res://scripts/simulation/regional_transit_traffic_runtime.gd")
const RegionalAccessibility = preload("res://scripts/city/regional_accessibility.gd")
const RegionalEconomy = preload("res://scripts/simulation/regional_economy.gd")
const RegionalFleetManagement = preload("res://scripts/simulation/regional_fleet_management.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")

const DEFAULT_SEED := 731945
const DEFAULT_YEARS := 1.0
const REAL_STEP_SECONDS := 0.25
const MAX_SIMULATION_SPEED := 4


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var options := _parse_options(OS.get_cmdline_user_args())
	var scenario := str(options.get("scenario", "baseline"))
	var years := clampf(float(options.get("years", DEFAULT_YEARS)), 0.01, 20.0)
	var seed := int(options.get("seed", DEFAULT_SEED))
	var simulation_speed := clampi(int(options.get("speed", MAX_SIMULATION_SPEED)), 1, MAX_SIMULATION_SPEED)

	var store = GameStoreScript.new()
	store.suppress_persistence = true
	store.reset_state(false, seed)
	store.simulation_speed = simulation_speed

	var setup := _setup_scenario(store, scenario)
	if not bool(setup.get("success", false)):
		push_error("REGIONAL BALANCE PLAYTEST: scenario setup failed: %s" % str(setup.get("reason", "unknown")))
		store.free()
		quit(2)
		return

	_initialize_external_runtimes(store)
	var initial := _snapshot(store)
	var target_simulation_seconds := years * float(GameStoreScript.RESIDENT_HEALTH_SIMULATION_SECONDS_PER_YEAR)
	var start_elapsed := float(store.elapsed_seconds)
	var next_progress_fraction := 0.25
	var iterations := 0

	while float(store.elapsed_seconds) - start_elapsed < target_simulation_seconds:
		var elapsed_before := float(store.elapsed_seconds)
		store._advance_simulation(REAL_STEP_SECONDS)
		var simulation_delta := maxf(0.0, float(store.elapsed_seconds) - elapsed_before)
		_advance_external_runtimes(store, simulation_delta)
		iterations += 1
		var progress := (float(store.elapsed_seconds) - start_elapsed) / target_simulation_seconds
		if progress + 0.000001 >= next_progress_fraction:
			print("REGIONAL BALANCE PLAYTEST: %.0f%%" % (next_progress_fraction * 100.0))
			next_progress_fraction += 0.25

	# Force one final deterministic read of the same canonical state consumed by
	# the live HUD and progression systems.
	RegionalTrafficRuntime.refresh(store)
	RegionalAccessibility.apply(store)
	RegionalTransitTrafficRuntime.apply(store)
	store.city["economy"] = RegionalEconomy.evaluate(store)
	var final := _snapshot(store)
	var report := {
		"schema_version": 1,
		"scenario": scenario,
		"seed": seed,
		"years": years,
		"health_year_seconds": float(GameStoreScript.RESIDENT_HEALTH_SIMULATION_SECONDS_PER_YEAR),
		"simulation_speed": simulation_speed,
		"iterations": iterations,
		"setup": setup,
		"initial": initial,
		"final": final,
		"delta": _delta_snapshot(initial, final),
	}
	print("REGIONAL_BALANCE_REPORT=" + JSON.stringify(report))
	store.free()
	quit(0)


func _initialize_external_runtimes(store: Node) -> void:
	RegionalTrafficRuntime.ensure(store.city)
	RegionalTrafficRuntime.refresh(store)
	RegionalAccessibility.apply(store)
	RegionalTransitTrafficRuntime.apply(store)
	store.city["economy"] = RegionalEconomy.evaluate(store)


func _advance_external_runtimes(store: Node, simulation_delta_seconds: float) -> void:
	if simulation_delta_seconds <= 0.0:
		return
	RegionalEconomy.advance(
		store,
		simulation_delta_seconds * float(Data.GAME_MINUTES_PER_REAL_SECOND)
	)
	if RegionalTrafficRuntime.advance(store, simulation_delta_seconds):
		RegionalAccessibility.apply(store)
	RegionalTransitTrafficRuntime.apply(store)
	RegionalFleetManagement.process_retirements(store)


func _setup_scenario(store: Node, scenario: String) -> Dictionary:
	match scenario:
		"baseline":
			return {"success": true, "scenario": scenario, "description": "Starter region with no player-funded transit."}
		"starter_bus":
			return _setup_starter_bus(store)
		_:
			return {"success": false, "reason": "unknown_scenario", "scenario": scenario}


func _setup_starter_bus(store: Node) -> Dictionary:
	var fixture := _first_built_road_segment(store.city, 220.0, 1200.0)
	if fixture.is_empty():
		return {"success": false, "reason": "no_suitable_built_corridor", "scenario": "starter_bus"}
	var depot_cost := float(Data.ECONOMY["sandbox_depot_build_cost"])
	if float(store.money) < depot_cost:
		return {"success": false, "reason": "insufficient_depot_capital", "scenario": "starter_bus"}

	# The reference scenario assumes a depot located beside the chosen corridor.
	# Its cost is charged exactly once; the line itself is then built through the
	# real route editor so route CAPEX, stops and starter fleet use gameplay code.
	store.money = float(store.money) - depot_cost
	store.depot["built"] = true
	store.depot["garage_slots"] = maxi(4, int(store.depot.get("garage_slots", 0)))
	store.selected_transit_mode = "bus"
	if not store.begin_free_line_editor():
		return {"success": false, "reason": "route_editor_unavailable", "scenario": "starter_bus"}
	var points: Array[Vector2] = fixture.get("points", [])
	for point in points:
		if not store.route_editor_add_point(point):
			store.cancel_route_editor()
			return {"success": false, "reason": "route_point_rejected", "scenario": "starter_bus"}
	if not store.commit_route_editor():
		store.cancel_route_editor()
		return {"success": false, "reason": "line_commit_failed", "scenario": "starter_bus"}
	var custom_lines := TransitNetwork.custom_line_ids(store.transit_network)
	if custom_lines.is_empty():
		return {"success": false, "reason": "line_missing_after_commit", "scenario": "starter_bus"}
	var line_id := str(custom_lines.back())
	return {
		"success": true,
		"scenario": "starter_bus",
		"description": "Starter region plus one player-funded depot and a two-stop bus line on a real built corridor.",
		"depot_cost": depot_cost,
		"line_id": line_id,
		"road_id": str(fixture.get("road_id", "")),
		"line_build_cost": float(store.transit_line(line_id).get("construction_cost", 0.0)),
	}


func _snapshot(store: Node) -> Dictionary:
	var transport: Dictionary = store.resident_transport_metrics()
	var health: Dictionary = store.resident_health_metrics()
	var economy: Dictionary = RegionalEconomy.evaluate(store)
	var road_traffic: Dictionary = store.city.get("road_traffic", {})
	var demographics: Dictionary = store.city.get("demographics", {})
	var line_count := 0
	var active_fleet := 0
	for line_id in TransitNetwork.custom_line_ids(store.transit_network):
		var line: Dictionary = store.transit_line(line_id)
		if str(line.get("status", "")) != "active":
			continue
		line_count += 1
		active_fleet += maxi(0, int(line.get("fleet_count", 0)))
	var runway := float(economy.get("runway_minutes", INF))
	return {
		"elapsed_seconds": float(store.elapsed_seconds),
		"treasury": float(store.money),
		"population": float(transport.get("resident_count", demographics.get("residents", 0.0))),
		"jobs": float(demographics.get("jobs", 0.0)),
		"buildings": store.city.get("buildings", []).size(),
		"organic_buildings": _count_source(store.city.get("buildings", []), "organic-growth"),
		"roads": store.city.get("roads", []).size(),
		"organic_roads": _count_source(store.city.get("roads", []), "organic-growth"),
		"active_custom_lines": line_count,
		"active_fleet": active_fleet,
		"lifetime_passengers": float(store.stats.get("lifetime_passengers", 0.0)),
		"lifetime_revenue": float(store.stats.get("lifetime_revenue", 0.0)),
		"lifetime_operating_costs": float(store.stats.get("lifetime_operating_costs", 0.0)),
		"economy_status": str(economy.get("status", "")),
		"net_per_minute": float(economy.get("net_per_minute", 0.0)),
		"road_maintenance_per_minute": float(economy.get("road_maintenance_per_minute", 0.0)),
		"runway_minutes": runway if is_finite(runway) else -1.0,
		"average_commute_minutes": float(transport.get("average_commute_minutes", 0.0)),
		"transit_share": float(transport.get("transit_share", 0.0)),
		"car_share": float(transport.get("car_share", 0.0)),
		"unserved_share": float(transport.get("unserved_share", 0.0)),
		"average_wellbeing": float(transport.get("average_wellbeing", 0.0)),
		"health_index": float(health.get("health_index", 0.0)),
		"healthcare_coverage": float(health.get("healthcare_coverage", 0.0)),
		"accessibility": _accessibility_summary(store.city),
		"road_traffic": road_traffic.get("summary", {}).duplicate(true),
	}


func _delta_snapshot(initial: Dictionary, final: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in [
		"treasury",
		"population",
		"jobs",
		"buildings",
		"organic_buildings",
		"roads",
		"organic_roads",
		"lifetime_passengers",
		"lifetime_revenue",
		"lifetime_operating_costs",
		"average_commute_minutes",
		"transit_share",
		"car_share",
		"unserved_share",
		"average_wellbeing",
		"health_index",
		"healthcare_coverage",
	]:
		result[key] = float(final.get(key, 0.0)) - float(initial.get(key, 0.0))
	return result


func _accessibility_summary(city: Dictionary) -> Dictionary:
	var state_value: Variant = city.get("regional_accessibility", {})
	if typeof(state_value) != TYPE_DICTIONARY:
		return {"available_settlements": 0, "population_weighted_score": 0.0, "minimum_score": 0.0, "maximum_score": 0.0}
	var rows_value: Variant = (state_value as Dictionary).get("settlements", {})
	if typeof(rows_value) != TYPE_DICTIONARY:
		return {"available_settlements": 0, "population_weighted_score": 0.0, "minimum_score": 0.0, "maximum_score": 0.0}
	var rows: Dictionary = rows_value
	var weighted_score := 0.0
	var total_population := 0.0
	var minimum := INF
	var maximum := 0.0
	var count := 0
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var row_value: Variant = rows.get(str(settlement.get("id", "")), {})
		if typeof(row_value) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_value
		if not bool(row.get("available", false)):
			continue
		var score := clampf(float(row.get("score", 0.0)), 0.0, 1.0)
		var population := maxf(1.0, float(settlement.get("population", 0.0)))
		weighted_score += score * population
		total_population += population
		minimum = minf(minimum, score)
		maximum = maxf(maximum, score)
		count += 1
	return {
		"available_settlements": count,
		"population_weighted_score": weighted_score / total_population if total_population > 0.0 else 0.0,
		"minimum_score": minimum if count > 0 else 0.0,
		"maximum_score": maximum if count > 0 else 0.0,
	}


func _count_source(items: Array, source: String) -> int:
	var count := 0
	for item_value in items:
		if typeof(item_value) == TYPE_DICTIONARY and str((item_value as Dictionary).get("source", "")) == source:
			count += 1
	return count


func _first_built_road_segment(city: Dictionary, minimum: float, maximum: float) -> Dictionary:
	var roads_by_id: Dictionary = {}
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		roads_by_id[str(road.get("id", ""))] = road
	var nodes_by_id: Dictionary = {}
	for node_value in city.get("nodes", []):
		if typeof(node_value) != TYPE_DICTIONARY:
			continue
		var node: Dictionary = node_value
		nodes_by_id[str(node.get("id", ""))] = Vector2(float(node.get("x", 0.0)), float(node.get("y", 0.0)))
	for edge_value in city.get("graph_edges", []):
		if typeof(edge_value) != TYPE_DICTIONARY:
			continue
		var edge: Dictionary = edge_value
		var road: Dictionary = roads_by_id.get(str(edge.get("roadId", "")), {})
		if str(road.get("status", "")) != "built":
			continue
		var start: Vector2 = nodes_by_id.get(str(edge.get("a", "")), Vector2.ZERO)
		var finish: Vector2 = nodes_by_id.get(str(edge.get("b", "")), Vector2.ZERO)
		var length := start.distance_to(finish)
		if length >= minimum and length <= maximum:
			return {
				"road_id": str(road.get("id", "")),
				"points": [start.lerp(finish, 0.05), start.lerp(finish, 0.95)],
			}
	return {}


func _parse_options(args: PackedStringArray) -> Dictionary:
	var result := {
		"scenario": "baseline",
		"years": DEFAULT_YEARS,
		"seed": DEFAULT_SEED,
		"speed": MAX_SIMULATION_SPEED,
	}
	for argument in args:
		if argument.begins_with("--scenario="):
			result["scenario"] = argument.trim_prefix("--scenario=")
		elif argument.begins_with("--years="):
			result["years"] = float(argument.trim_prefix("--years="))
		elif argument.begins_with("--seed="):
			result["seed"] = int(argument.trim_prefix("--seed="))
		elif argument.begins_with("--speed="):
			result["speed"] = int(argument.trim_prefix("--speed="))
	return result
