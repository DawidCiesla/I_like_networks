extends Node

signal state_changed
signal city_changed
signal selection_changed(selection: String)
signal toast_requested(message: String)
signal route_editor_changed
signal terrain_changed

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const CityRuntime = preload("res://scripts/city/city_runtime.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")
const TransitPlanner = preload("res://scripts/transport/transit_planner.gd")
const TransitModes = preload("res://scripts/transport/transit_modes.gd")
const RoadRouter = preload("res://scripts/transport/road_router.gd")
const BrowserSaveImporter = preload("res://scripts/persistence/browser_save_importer.gd")
const WorldMapDefinition = preload("res://scripts/world/world_map_definition.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const TerrainEditData = preload("res://scripts/world/terrain_edit_data.gd")
const RoadTopology = preload("res://scripts/city/road_topology.gd")
const RoadProfile = preload("res://scripts/city/road_profile.gd")
const ResidentTravelChoice = preload("res://scripts/simulation/resident_travel_choice.gd")
const ResidentHealth = preload("res://scripts/simulation/resident_health.gd")
const CityServices = preload("res://scripts/city/city_services.gd")

const ROAD_BUILDER_SNAP_DISTANCE := 160.0
const ROAD_BUILDER_MIN_LENGTH := 120.0
const ROAD_BUILDER_MAX_LENGTH := 2400.0
const ROAD_BUILDER_MAX_GRADE_RATIO := 0.24
const RESIDENT_TRIPS_PER_PERSON_PER_DAY := 0.55
const RESIDENT_STOP_WALK_RADIUS := 720.0
const RESIDENT_WALK_SPEED_METERS_PER_MINUTE := 72.0
const RESIDENT_CAR_SPEED_KPH := 36.0
const RESIDENT_CAR_ACCESS_SPEED_KPH := 18.0
const RESIDENT_CAR_MAX_SNAP_DISTANCE := 720.0
const RESIDENT_CAR_CIRCUITY := 1.24
const RESIDENT_CAR_FIXED_MINUTES := 3.0
const RESIDENT_CAPACITY_PENALTY_MINUTES := 42.0
const RESIDENT_CAPACITY_PRESSURE_RECOVERY_MINUTES := 24.0
const RESIDENT_LOGIT_PARAMETERS := {
	"logit_scale_minutes": 12.0,
	"fare_minutes_per_currency": 0.15,
	"reference_income": 3200.0 / 30.0,
	"minimum_income": 800.0 / 30.0,
	"unserved_penalty_minutes": 72.0,
}
const RESIDENT_COHORTS := [
	{"id": "lower_no_car", "share": 0.20, "monthly_income": 1600.0, "fare_sensitivity": 1.30, "car_eligible": false},
	{"id": "lower_car", "share": 0.12, "monthly_income": 1600.0, "fare_sensitivity": 1.30, "car_eligible": true},
	{"id": "middle_no_car", "share": 0.08, "monthly_income": 3300.0, "fare_sensitivity": 1.00, "car_eligible": false},
	{"id": "middle_car", "share": 0.38, "monthly_income": 3300.0, "fare_sensitivity": 1.00, "car_eligible": true},
	{"id": "upper_car", "share": 0.22, "monthly_income": 7500.0, "fare_sensitivity": 0.75, "car_eligible": true},
]
const RESIDENT_AGE_PROFILES := [
	{"id": "children", "walk_radius": 500.0, "walk_speed": 54.0, "car_access": 0.0, "fare_multiplier": 0.60},
	{"id": "adults", "walk_radius": RESIDENT_STOP_WALK_RADIUS, "walk_speed": RESIDENT_WALK_SPEED_METERS_PER_MINUTE, "car_access": 1.0, "fare_multiplier": 1.0},
	{"id": "seniors", "walk_radius": 500.0, "walk_speed": 48.0, "car_access": 0.45, "fare_multiplier": 0.70},
]
const DEFAULT_RESIDENT_AGE_SHARES := {"children": 0.18, "adults": 0.64, "seniors": 0.18}
const RESIDENT_HEALTH_UPDATE_INTERVAL_SECONDS := 30.0
const RESIDENT_HEALTH_SIMULATION_SECONDS_PER_YEAR := 3600.0
const REGIONAL_SERVICE_COVERED_EPSILON := 0.005

const SAVE_PATH := "user://save_godot_v2.json"

var money: float = 0.0
var elapsed_seconds: float = 0.0
var simulation_speed: int = 1
var city_seed: int = Data.DEFAULT_CITY_SEED
var world_map: Dictionary = {}
var selected: String = ""
var terrain_tool_mode := ""

var lines: Dictionary = {}
var stations: Dictionary = {}
var depot: Dictionary = {}
var stats: Dictionary = {}
var city: Dictionary = {}
var transit_network: Dictionary = {}
var route_editor: Dictionary = {}
var road_builder: Dictionary = {}
var depot_placement_mode := false
var selected_transit_mode := "bus"

var _autosave_timer := 0.0
var _fare_changed_this_frame := false
var _custom_catchment_cache: Dictionary = {}
var _resident_transport_snapshot_cache: Dictionary = {}
var _resident_health_snapshot_cache: Dictionary = {}
var suppress_persistence := false

func _ready() -> void:
	reset_state(false)
	load_game()

func _process(delta: float) -> void:
	if simulation_speed > 0:
		_fare_changed_this_frame = false
		var city_did_change := _advance_simulation(delta)
		if _fare_changed_this_frame:
			state_changed.emit()
		if city_did_change:
			city_changed.emit()

	_autosave_timer += delta
	if _autosave_timer >= 12.0:
		_autosave_timer = 0.0
		if not suppress_persistence:
			save_game()

func _create_waiting_matrix(max_stops: int) -> Array:
	var result: Array = []
	for _index in range(max_stops):
		var row: Array = []
		row.resize(max_stops)
		row.fill(0.0)
		result.append(row)
	return result


func _create_fare_weight_matrix(stop_count: int) -> Array:
	var result: Array = []
	for _index in range(stop_count):
		var row: Array = []
		row.resize(stop_count)
		row.fill(0.0)
		result.append(row)
	return result


func _create_resident_transfer_matrix(stop_count: int) -> Array:
	var result: Array = []
	for _origin_index in range(stop_count):
		var row: Array = []
		for _destination_index in range(stop_count):
			row.append([])
		result.append(row)
	return result


func _resident_ride_legs(legs_value: Variant) -> Array:
	var result: Array = []
	if typeof(legs_value) != TYPE_ARRAY:
		return result
	var walk_minutes_before_next_ride := 0.0
	for leg_value in legs_value:
		if typeof(leg_value) != TYPE_DICTIONARY:
			continue
		var leg: Dictionary = leg_value
		match str(leg.get("mode", "")):
			"walk":
				var walk_minutes := maxf(0.0, float(leg.get("time_minutes", 0.0)))
				if is_finite(walk_minutes):
					walk_minutes_before_next_ride += walk_minutes
			"ride":
				var ride_leg := leg.duplicate(true)
				var existing_walk_minutes := maxf(
					0.0,
					float(ride_leg.get("transfer_walk_minutes_before", 0.0))
				)
				if not is_finite(existing_walk_minutes):
					existing_walk_minutes = 0.0
				ride_leg["transfer_walk_minutes_before"] = (
					existing_walk_minutes + walk_minutes_before_next_ride
				)
				walk_minutes_before_next_ride = 0.0
				result.append(ride_leg)
	return result


func _normalize_pending_resident_transfers(pending_value: Variant) -> Array:
	var result: Array = []
	if typeof(pending_value) != TYPE_ARRAY:
		return result
	for pending_value_item in pending_value:
		if typeof(pending_value_item) != TYPE_DICTIONARY:
			continue
		var pending: Dictionary = pending_value_item
		var passengers := maxf(0.0, float(pending.get("passengers", 0.0)))
		var fare_weighted_passengers := clampf(
			maxf(0.0, float(pending.get("fare_weighted_passengers", passengers))),
			0.0,
			passengers
		)
		var remaining_walk_minutes := maxf(
			0.0,
			float(pending.get("remaining_walk_minutes", 0.0))
		)
		if not is_finite(passengers) or not is_finite(fare_weighted_passengers):
			continue
		if not is_finite(remaining_walk_minutes):
			remaining_walk_minutes = 0.0
		var remaining_ride_legs := _resident_ride_legs(pending.get("remaining_ride_legs", []))
		if passengers <= 0.000001 or remaining_ride_legs.is_empty():
			continue
		result.append({
			"remaining_walk_minutes": remaining_walk_minutes,
			"passengers": passengers,
			"fare_weighted_passengers": fare_weighted_passengers,
			"remaining_ride_legs": remaining_ride_legs,
		})
	return result


func _normalize_resident_transfer_groups(
	groups_value: Variant,
	passenger_limit: float = INF
) -> Array:
	var result: Array = []
	if typeof(groups_value) != TYPE_ARRAY:
		return result
	var total := 0.0
	for group_value in groups_value:
		if typeof(group_value) != TYPE_DICTIONARY:
			continue
		var group: Dictionary = group_value
		var passengers := maxf(0.0, float(group.get("passengers", 0.0)))
		var remaining_ride_legs := _resident_ride_legs(group.get("remaining_ride_legs", []))
		if passengers <= 0.000001 or remaining_ride_legs.is_empty():
			continue
		var fare_weight := clampf(
			maxf(0.0, float(group.get("fare_weighted_passengers", passengers))),
			0.0,
			passengers
		)
		result.append({
			"passengers": passengers,
			"fare_weighted_passengers": fare_weight,
			"remaining_ride_legs": remaining_ride_legs,
		})
		total += passengers
	var safe_limit := maxf(0.0, passenger_limit)
	if total > safe_limit and total > 0.000001:
		var scale := safe_limit / total
		for index in range(result.size()):
			var group: Dictionary = result[index]
			group["passengers"] = float(group["passengers"]) * scale
			group["fare_weighted_passengers"] = float(group["fare_weighted_passengers"]) * scale
			result[index] = group
	return result

func _new_line_state(line_key: String) -> Dictionary:
	var max_stops := int(Data.LINE_CONFIG[line_key]["max_stops"])
	return {
		"built": false,
		"stop_count": 1 if line_key == "line1" else 0,
		"fleet_count": 0,
		"demand_per_stop_ppm": float(Data.LINE_CONFIG[line_key]["demand_per_stop_ppm"]),
		"waiting_by_stop": _create_waiting_matrix(max_stops),
		"waiting_fare_weights_by_stop": _create_fare_weight_matrix(max_stops),
		"queue_passengers": 0.0,
		"current_abandonment_ppm": 0.0,
		"total_abandoned_passengers": 0.0,
		"last_delivered_ppm": 0.0,
		"vehicles": [],
		"next_vehicle_id": 1,
		"event_serial": 0,
		"last_passenger_event": null,
		"passenger_events": [],
	}

func _empty_transit_network() -> Dictionary:
	return {
		"schema_version": TransitNetwork.SCHEMA_VERSION,
		"source": TransitNetwork.SOURCE_FREE_LINES,
		"next_stop_serial": 1,
		"next_line_serial": 1,
		"unlocked_modes": {"bus": true},
		"stops": {},
		"lines": {},
		"pending_resident_transfers": [],
	}

func _empty_road_builder() -> Dictionary:
	return {
		"active": false,
		"road_class": "collector",
		"draft_points": [],
		"snaps": [],
	}

func is_sandbox() -> bool:
	return str(world_map.get("id", WorldMapDefinition.LEGACY_CITY_MAP_ID)) != WorldMapDefinition.LEGACY_CITY_MAP_ID


## Returns resident travel-choice diagnostics for the regional sandbox. Demand
## is modeled as daily aggregate OD/cohort trips; the simulation converts it to
## passenger counts per elapsed game minute. The treasury value is live.
func resident_transport_metrics() -> Dictionary:
	if not is_sandbox():
		return {
			"transit_share": 0.0,
			"car_share": 0.0,
			"average_commute_minutes": 0.0,
			"expected_transit_trips_per_hour": 0.0,
			"resident_count": 0,
			"average_wellbeing": 0.0,
			"public_treasury": money,
		}
	var snapshot := _resident_transport_snapshot()
	var metrics: Dictionary = snapshot.get("metrics", {}).duplicate(true)
	metrics["public_treasury"] = money
	return metrics


## Returns aggregate health and healthcare estimates for the regional sandbox.
## Pollution is inferred from the modeled car share by settlement; it is not a
## particle-level or medical simulation.
func resident_health_metrics() -> Dictionary:
	if not is_sandbox():
		return {"health_index": 100.0, "healthcare_coverage": 0.0, "preventable_burden": 0.0, "population": 0.0, "districts": {}, "cohorts": {}}
	var transport := _resident_transport_snapshot()
	var signature := _resident_health_signature(str(transport.get("signature", "")))
	if (
		str(_resident_health_snapshot_cache.get("signature", "")) == signature
		and _resident_health_snapshot_cache.has("metrics")
	):
		return _resident_health_snapshot_cache["metrics"].duplicate(true)
	var transport_metrics: Dictionary = transport.get("metrics", {}).duplicate(true)
	var metrics: Dictionary = ResidentHealth.advance(
		city.get("resident_health_state", {}),
		_resident_health_input(transport_metrics),
		0.0
	).get("metrics", {})
	_resident_health_snapshot_cache = {"signature": signature, "metrics": metrics}
	return metrics.duplicate(true)


## Returns cost and coverage for adding one public service facility to a
## settlement. Starter services have intentionally limited capacity so the
## player can decide which local needs to fund first.
func regional_service_build_status(settlement_id: String, service_type: String) -> Dictionary:
	if not is_sandbox():
		return {"available": false, "reason": "sandbox_only"}
	if service_type not in CityServices.SERVICE_TYPES:
		return {"available": false, "reason": "unknown_service"}
	var settlement: Dictionary = {}
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) == TYPE_DICTIONARY and str(settlement_value.get("id", "")) == settlement_id:
			settlement = settlement_value
			break
	if settlement.is_empty():
		return {"available": false, "reason": "unknown_settlement"}
	var service_results := _current_regional_service_results()
	var services: Dictionary = service_results.get("services", {}).get("districts", {}).get(settlement_id, {}).get("services", {})
	var service_metrics: Dictionary = services.get(service_type, {})
	var coverage := clampf(float(service_metrics.get("coverage", 0.0)), 0.0, 1.0)
	var cost_table: Dictionary = Data.ECONOMY.get("sandbox_service_build_costs", {})
	var cost := int(cost_table.get(service_type, 0))
	if coverage >= 1.0 - REGIONAL_SERVICE_COVERED_EPSILON:
		return {"available": false, "reason": "service_already_covered", "coverage": coverage, "cost": cost}
	return {
		"available": money >= float(cost),
		"reason": "" if money >= float(cost) else "insufficient_funds",
		"coverage": coverage,
		"cost": cost,
		"service": service_type,
		"settlement_id": settlement_id,
	}


func build_regional_service(settlement_id: String, service_type: String) -> bool:
	var build_status := regional_service_build_status(settlement_id, service_type)
	if not bool(build_status.get("available", false)):
		var reason := str(build_status.get("reason", "unavailable"))
		_request_toast("Service facility cannot be built: %s." % reason.replace("_", " "))
		return false
	var settlement: Dictionary = {}
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) == TYPE_DICTIONARY and str(settlement_value.get("id", "")) == settlement_id:
			settlement = settlement_value
			break
	if settlement.is_empty():
		return false
	var serial := int(city.get("next_player_service_serial", 1))
	city["next_player_service_serial"] = serial + 1
	var position := _resident_point(settlement.get("position", Vector2.ZERO))
	var population := maxf(0.0, float(settlement.get("population", 0.0)))
	var capacity_share := float(Data.ECONOMY.get("sandbox_service_capacity_share", 0.30))
	var operating_costs: Dictionary = Data.ECONOMY.get("sandbox_service_operating_costs_per_minute", {})
	var service_buildings: Array = city.get("service_buildings", [])
	service_buildings.append({
		"id": "player-service-%04d" % serial,
		"districtId": settlement_id,
		"service": service_type,
		"x": position.x,
		"y": position.y,
		"catchmentRadius": _regional_service_catchment_radius(str(settlement.get("tier", "village"))),
		"capacity": population * CityRuntime._service_demand_ratio(service_type) * capacity_share,
		"operatingCostPerMinute": maxf(0.0, float(operating_costs.get(service_type, 0.0))),
		"condition": 1.0,
		"status": "operational",
		"source": "player",
	})
	city["service_buildings"] = service_buildings
	var cost := int(build_status.get("cost", 0))
	money -= float(cost)
	var computed := _current_regional_service_results()
	var service_bundle: Dictionary = city.get("service_results", {}).duplicate(true)
	service_bundle["services"] = computed.get("services", {})
	city["service_results"] = service_bundle
	_request_toast("%s facility built in %s · $%s." % [service_type.capitalize(), str(settlement.get("name", settlement_id)), _compact_money(cost)])
	_commit_change()
	return true


func _regional_service_catchment_radius(tier: String) -> float:
	match tier:
		"capital":
			return 2500.0
		"market":
			return 1450.0
		_:
			return 620.0


func _resident_health_input(transport_metrics: Dictionary = {}) -> Dictionary:
	if transport_metrics.is_empty():
		transport_metrics = _resident_transport_snapshot().get("metrics", {})
	var health_state: Dictionary = city.get("resident_health_state", {})
	var health_districts: Dictionary = health_state.get("districts", {})
	var input_settlements: Array = city.get("regional_settlements", []).duplicate(true)
	for settlement_value in input_settlements:
		if not (settlement_value is Dictionary):
			continue
		var settlement: Dictionary = settlement_value
		var district: Dictionary = health_districts.get(str(settlement.get("id", "")), {})
		if district.is_empty():
			continue
		var simulated_population := maxf(0.0, float(district.get("population", 0.0)))
		var observed_population := maxf(
			0.0,
			float(district.get("observed_population", simulated_population))
		)
		# The city stores the health-adjusted headcount for transport and growth.
		# Remove the previous health model's net adjustment before reconciliation,
		# so its own births/deaths are not mistaken for an external city edit.
		var modeled_adjustment := simulated_population - observed_population
		settlement["population"] = maxf(
			0.0,
			float(settlement.get("population", observed_population)) - modeled_adjustment
		)
	return {
		"settlements": input_settlements,
		"service_results": _current_regional_service_results(),
		"transport_metrics": transport_metrics,
		"exposure_by_settlement": _health_exposure_by_settlement(transport_metrics),
	}


func _advance_resident_health(delta_seconds: float) -> bool:
	if not is_sandbox() or delta_seconds <= 0.0:
		return false
	var accumulated := float(city.get("resident_health_accumulator_seconds", 0.0)) + delta_seconds
	if accumulated < RESIDENT_HEALTH_UPDATE_INTERVAL_SECONDS:
		city["resident_health_accumulator_seconds"] = accumulated
		return false
	var elapsed_simulation_seconds := accumulated
	city["resident_health_accumulator_seconds"] = 0.0
	var previous_state: Dictionary = city.get("resident_health_state", {})
	var transport := _resident_transport_snapshot()
	var transport_metrics: Dictionary = transport.get("metrics", {})
	var advanced: Dictionary = ResidentHealth.advance(
		previous_state,
		_resident_health_input(transport_metrics),
		elapsed_simulation_seconds / RESIDENT_HEALTH_SIMULATION_SECONDS_PER_YEAR
	)
	city["resident_health_state"] = advanced.get("state", {})
	var health_districts: Dictionary = advanced.get("metrics", {}).get("districts", {})
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var settlement_id := str(settlement.get("id", ""))
		if health_districts.has(settlement_id):
			var health_district: Dictionary = health_districts[settlement_id]
			settlement["population"] = maxf(0.0, float(health_district.get("population", settlement.get("population", 0.0))))
	CityRuntime._refresh_regional_demographics(city)
	_resident_health_snapshot_cache = {
		"signature": _resident_health_signature(str(transport.get("signature", ""))),
		"metrics": advanced.get("metrics", {}),
	}
	return true


func _resident_health_signature(transport_signature: String) -> String:
	var parts: Array[String] = [transport_signature]
	parts.append("health_state:%s" % JSON.stringify(city.get("resident_health_state", {})))
	var facilities: Array[Dictionary] = []
	for facility_value in city.get("service_buildings", []):
		if typeof(facility_value) != TYPE_DICTIONARY:
			continue
		var facility: Dictionary = facility_value
		facilities.append(facility)
	facilities.sort_custom(func(a, b): return str(a.get("id", "")) < str(b.get("id", "")))
	for facility in facilities:
		parts.append("%s:%s:%s:%.2f:%.2f:%.2f:%.1f:%.1f" % [
			str(facility.get("id", "")),
			str(facility.get("service", "")),
			str(facility.get("status", "")),
			float(facility.get("x", 0.0)),
			float(facility.get("y", 0.0)),
			float(facility.get("catchmentRadius", 0.0)),
			float(facility.get("capacity", 0.0)),
			float(facility.get("condition", 1.0)),
		])
	return "|".join(parts)


func _current_regional_service_results() -> Dictionary:
	var districts: Array[Dictionary] = []
	var demand_points: Array[Dictionary] = []
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var settlement_id := str(settlement.get("id", ""))
		if settlement_id.is_empty():
			continue
		var population := maxf(0.0, float(settlement.get("population", 0.0)))
		var position := _resident_point(settlement.get("position", Vector2.ZERO))
		districts.append({"id": settlement_id})
		demand_points.append({
			"id": "health-demand-%s" % settlement_id,
			"districtId": settlement_id,
			"x": position.x,
			"y": position.y,
			"demands": {
				"healthcare": population * 0.10,
				"education": population * 0.16,
				"fire": population * 0.025,
				"police": population * 0.035,
				"waste": population * 0.85,
				"recreation": population * 0.35,
			},
		})
	var coverage := CityServices.evaluate_district_coverage(
		districts,
		demand_points,
		city.get("service_buildings", [])
	)
	return {"services": coverage}


func _health_exposure_by_settlement(transport_metrics: Dictionary) -> Dictionary:
	var exposures: Dictionary = {}
	var transport_districts: Dictionary = transport_metrics.get("districts", {})
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var settlement_id := str(settlement.get("id", ""))
		var local: Dictionary = transport_districts.get(settlement_id, {})
		var car_share := clampf(float(local.get("car_share", transport_metrics.get("car_share", 0.0))), 0.0, 1.0)
		var unserved_share := clampf(float(local.get("unserved_share", transport_metrics.get("unserved_share", 0.0))), 0.0, 1.0)
		exposures[settlement_id] = clampf(0.06 + car_share * 0.60 + unserved_share * 0.12, 0.0, 1.0)
	return exposures


func _resident_transport_snapshot() -> Dictionary:
	var signature := _resident_transport_signature()
	if (
		str(_resident_transport_snapshot_cache.get("signature", "")) == signature
		and _resident_transport_snapshot_cache.has("metrics")
	):
		return _resident_transport_snapshot_cache

	var settlements: Array[Dictionary] = []
	var resident_count := 0.0
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var population := maxf(0.0, float(settlement.get("population", 0.0)))
		if population <= 0.0:
			continue
		var position := _resident_point(settlement.get("position", Vector2.ZERO))
		var normalized := {
			"id": str(settlement.get("id", "")),
			"tier": str(settlement.get("tier", "settlement")),
			"population": population,
			"jobs": maxf(0.0, float(settlement.get("jobs", population * 0.43))),
			"position": position,
			"age_cohorts": _resident_age_cohorts(str(settlement.get("id", "")), population),
		}
		settlements.append(normalized)
		resident_count += population

	var available_stops := _resident_operational_stops()
	var route_by_od: Dictionary = {}
	var route_by_od_age: Dictionary = {}
	var journey_cache: Dictionary = {}
	var car_by_od: Dictionary = {}
	var model_rows: Array[Dictionary] = []
	var od_diagnostics: Array[Dictionary] = []
	var district_flow_totals: Dictionary = {}
	var daily_income_basis := 0.0
	var reachable_od_pairs := 0
	var reachable_car_od_pairs := 0
	var total_od_pairs := 0
	var current_fare := maxf(0.0, float(Data.ECONOMY["fare_per_passenger"]))

	for origin_value in settlements:
		var origin: Dictionary = origin_value
		for destination_share_value in _resident_destination_distribution(origin, settlements):
			var destination_share: Dictionary = destination_share_value
			var destination: Dictionary = destination_share["settlement"]
			var origin_id := str(origin["id"])
			var destination_id := str(destination["id"])
			var od_id := _resident_od_id(origin_id, destination_id)
			var origin_position: Vector2 = origin["position"]
			var destination_position: Vector2 = destination["position"]
			var transit_route: Dictionary = {}
			for age_profile_value in RESIDENT_AGE_PROFILES:
				var age_profile: Dictionary = age_profile_value
				var age_group := str(age_profile["id"])
				var age_route := _best_resident_transit_route(
					origin_position,
					destination_position,
					available_stops,
					journey_cache,
					float(age_profile["walk_radius"]),
					float(age_profile["walk_speed"])
				)
				route_by_od_age[_resident_age_route_key(od_id, age_group)] = age_route
				if age_group == "adults":
					transit_route = age_route
			var transit_reachable := bool(transit_route.get("reachable", false))
			var ride_count := int(transit_route.get("ride_count", 0)) if transit_reachable else 0
			var transit_fare := current_fare * float(ride_count)
			var car_route := _resident_car_route(origin_position, destination_position)
			route_by_od[od_id] = transit_route
			car_by_od[od_id] = car_route
			total_od_pairs += 1
			if transit_reachable:
				reachable_od_pairs += 1
			if bool(car_route.get("reachable", false)):
				reachable_car_od_pairs += 1
			od_diagnostics.append({
				"od_id": od_id,
				"origin_id": origin_id,
				"destination_id": destination_id,
				"car_reachable": bool(car_route.get("reachable", false)),
				"transit_reachable": transit_reachable,
				"transit_minutes": float(transit_route.get("minutes", 0.0)) if transit_reachable else 0.0,
				"transit_capacity_pressure": float(transit_route.get("capacity_pressure", 0.0)),
				"transit_trips_per_hour": 0.0,
				"car_trips_per_hour": 0.0,
				"unserved_trips_per_hour": 0.0,
			})

			var destination_weight := float(destination_share.get("share", 0.0))
			for age_cohort_value in origin.get("age_cohorts", []):
				var age_cohort: Dictionary = age_cohort_value
				var age_group := str(age_cohort.get("age_group", "adults"))
				var age_profile := _resident_age_profile(age_group)
				var age_route: Dictionary = route_by_od_age.get(
					_resident_age_route_key(od_id, age_group),
					transit_route
				)
				var age_transit_reachable := bool(age_route.get("reachable", false))
				var age_ride_count := int(age_route.get("ride_count", 0)) if age_transit_reachable else 0
				var age_fare := current_fare * float(age_profile.get("fare_multiplier", 1.0)) * float(age_ride_count)
				for cohort_value in RESIDENT_COHORTS:
					var cohort: Dictionary = cohort_value
					var segment_population := float(age_cohort.get("population", 0.0)) * float(cohort["share"]) * destination_weight
					var daily_trips := segment_population * RESIDENT_TRIPS_PER_PERSON_PER_DAY
					var daily_income := float(cohort["monthly_income"]) / 30.0
					model_rows.append({
						"od_id": od_id,
						"origin_id": origin_id,
						"destination_id": destination_id,
						"cohort_id": "%s:%s" % [str(cohort["id"]), age_group],
						"age_group": age_group,
						"population": segment_population,
						"trip_count": daily_trips,
						"income": daily_income,
						"fare_sensitivity": float(cohort["fare_sensitivity"]),
						"car_eligible": bool(cohort["car_eligible"]),
						"car_availability": float(age_profile.get("car_access", 1.0)) if bool(cohort["car_eligible"]) else 0.0,
						"car": car_route,
						"transit": {
							"minutes": float(age_route.get("minutes", 0.0)) if age_transit_reachable else 0.0,
							"cost": age_fare,
							"reachable": age_transit_reachable,
						},
					})
					daily_income_basis += segment_population * daily_income

	var parameters: Dictionary = RESIDENT_LOGIT_PARAMETERS.duplicate(true)
	var choice: Dictionary = ResidentTravelChoice.evaluate({
		"od_cohorts": model_rows,
		"parameters": parameters,
	})
	var choice_totals: Dictionary = choice.get("totals", {})
	var mode_flows: Dictionary = choice_totals.get("flows", {})
	var mode_shares: Dictionary = choice_totals.get("shares", {})
	var transit_daily := float(mode_flows.get("transit", 0.0))
	var transit_boardings_daily := 0.0
	var commute_time_trip_sum := 0.0
	var served_daily := 0.0
	var transit_capacity_pressure_trip_sum := 0.0
	var evaluated_rows: Array = choice.get("flows", [])
	var diagnostic_index_by_od: Dictionary = {}
	for diagnostic_index in range(od_diagnostics.size()):
		diagnostic_index_by_od[str(od_diagnostics[diagnostic_index]["od_id"])] = diagnostic_index
	for row_value in evaluated_rows:
		var flow: Dictionary = row_value
		var od_id := str(flow.get("od_id", ""))
		var flows: Dictionary = flow.get("flows", {})
		var car_flow := float(flows.get("car", 0.0))
		var transit_flow := float(flows.get("transit", 0.0))
		var unserved_flow := float(flows.get("unserved", 0.0))
		var car_route: Dictionary = car_by_od.get(od_id, {})
		var car_time := float(car_route.get("minutes", 0.0))
		var age_group := str(flow.get("age_group", "adults"))
		var route: Dictionary = route_by_od_age.get(
			_resident_age_route_key(od_id, age_group),
			route_by_od.get(od_id, {})
		)
		var transit_time := float(route.get("minutes", 0.0))
		var ride_count := int(route.get("ride_count", 0)) if bool(route.get("reachable", false)) else 0
		transit_boardings_daily += transit_flow * float(ride_count)
		transit_capacity_pressure_trip_sum += transit_flow * float(route.get("capacity_pressure", 0.0))
		commute_time_trip_sum += car_flow * car_time + transit_flow * transit_time
		served_daily += car_flow + transit_flow
		var origin_id := str(flow.get("origin_id", ""))
		if origin_id.is_empty():
			origin_id = str(flow.get("od_id", "")).split("->", false, 1)[0]
		var district_flow: Dictionary = district_flow_totals.get(origin_id, {
			"total_trips_daily": 0.0,
			"car_trips_daily": 0.0,
			"transit_trips_daily": 0.0,
			"capacity_pressure_trip_sum": 0.0,
			"unserved_trips_daily": 0.0,
			"commute_trip_minutes_daily": 0.0,
			"age_groups": {},
		})
		var effective_commute := (
			car_flow * car_time
			+ transit_flow * transit_time
			+ unserved_flow * float(RESIDENT_LOGIT_PARAMETERS["unserved_penalty_minutes"])
		)
		district_flow["total_trips_daily"] = float(district_flow["total_trips_daily"]) + car_flow + transit_flow + unserved_flow
		district_flow["car_trips_daily"] = float(district_flow["car_trips_daily"]) + car_flow
		district_flow["transit_trips_daily"] = float(district_flow["transit_trips_daily"]) + transit_flow
		district_flow["capacity_pressure_trip_sum"] = float(district_flow["capacity_pressure_trip_sum"]) + transit_flow * float(route.get("capacity_pressure", 0.0))
		district_flow["unserved_trips_daily"] = float(district_flow["unserved_trips_daily"]) + unserved_flow
		district_flow["commute_trip_minutes_daily"] = float(district_flow["commute_trip_minutes_daily"]) + effective_commute
		var district_age_groups: Dictionary = district_flow.get("age_groups", {})
		var age_flow: Dictionary = district_age_groups.get(age_group, {
			"total": 0.0,
			"car": 0.0,
			"transit": 0.0,
			"unserved": 0.0,
			"commute_trip_minutes": 0.0,
		})
		age_flow["total"] = float(age_flow["total"]) + car_flow + transit_flow + unserved_flow
		age_flow["car"] = float(age_flow["car"]) + car_flow
		age_flow["transit"] = float(age_flow["transit"]) + transit_flow
		age_flow["unserved"] = float(age_flow["unserved"]) + unserved_flow
		age_flow["commute_trip_minutes"] = float(age_flow["commute_trip_minutes"]) + effective_commute
		district_age_groups[age_group] = age_flow
		district_flow["age_groups"] = district_age_groups
		district_flow_totals[origin_id] = district_flow
		if diagnostic_index_by_od.has(od_id):
			var diagnostic_index := int(diagnostic_index_by_od[od_id])
			var diagnostic: Dictionary = od_diagnostics[diagnostic_index]
			diagnostic["transit_trips_per_hour"] = (
				float(diagnostic["transit_trips_per_hour"]) + transit_flow / 24.0
			)
			diagnostic["car_trips_per_hour"] = float(diagnostic["car_trips_per_hour"]) + car_flow / 24.0
			diagnostic["unserved_trips_per_hour"] = float(diagnostic["unserved_trips_per_hour"]) + unserved_flow / 24.0
			od_diagnostics[diagnostic_index] = diagnostic

	var district_transport_metrics: Dictionary = {}
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var settlement_id := str(settlement.get("id", ""))
		var district_flow: Dictionary = district_flow_totals.get(settlement_id, {})
		var total_trips_daily := float(district_flow.get("total_trips_daily", 0.0))
		var local_commute := (
			float(district_flow.get("commute_trip_minutes_daily", 0.0)) / total_trips_daily
			if total_trips_daily > 0.000001
			else float(RESIDENT_LOGIT_PARAMETERS["unserved_penalty_minutes"])
		)
		var local_unserved_share := (
			float(district_flow.get("unserved_trips_daily", 0.0)) / total_trips_daily
			if total_trips_daily > 0.000001 else 1.0
		)
		var local_age_metrics: Dictionary = {}
		var local_age_flows: Dictionary = district_flow.get("age_groups", {})
		for age_group in ["children", "adults", "seniors"]:
			var age_flow: Dictionary = local_age_flows.get(age_group, {})
			var age_total := float(age_flow.get("total", 0.0))
			var age_unserved_share := float(age_flow.get("unserved", 0.0)) / age_total if age_total > 0.000001 else 1.0
			var age_commute := float(age_flow.get("commute_trip_minutes", 0.0)) / age_total if age_total > 0.000001 else float(RESIDENT_LOGIT_PARAMETERS["unserved_penalty_minutes"])
			local_age_metrics[age_group] = {
				"trips_daily": age_total,
				"average_commute_minutes": age_commute,
				"average_wellbeing": clampf(100.0 - age_commute * 0.55 - age_unserved_share * 45.0, 0.0, 100.0),
				"car_share": float(age_flow.get("car", 0.0)) / age_total if age_total > 0.000001 else 0.0,
				"transit_share": float(age_flow.get("transit", 0.0)) / age_total if age_total > 0.000001 else 0.0,
				"unserved_share": float(age_flow.get("unserved", 0.0)) / age_total if age_total > 0.000001 else 0.0,
			}
		district_transport_metrics[settlement_id] = {
			"average_commute_minutes": local_commute,
			"average_wellbeing": clampf(100.0 - local_commute * 0.55 - local_unserved_share * 45.0, 0.0, 100.0),
			"car_share": float(district_flow.get("car_trips_daily", 0.0)) / total_trips_daily if total_trips_daily > 0.000001 else 0.0,
			"transit_share": float(district_flow.get("transit_trips_daily", 0.0)) / total_trips_daily if total_trips_daily > 0.000001 else 0.0,
			"average_transit_capacity_pressure": float(district_flow.get("capacity_pressure_trip_sum", 0.0)) / float(district_flow.get("transit_trips_daily", 0.0)) if float(district_flow.get("transit_trips_daily", 0.0)) > 0.000001 else 0.0,
			"unserved_share": local_unserved_share,
			"age_groups": local_age_metrics,
		}

	var average_commute := (
		commute_time_trip_sum / served_daily
		if served_daily > 0.000001 else float(RESIDENT_LOGIT_PARAMETERS["unserved_penalty_minutes"])
	)
	var fare_burden := (
		float(choice_totals.get("expected_fare_paid", 0.0)) / daily_income_basis
		if daily_income_basis > 0.000001 else 0.0
	)
	var unserved_share := float(mode_shares.get("unserved", 0.0))
	var wellbeing := clampf(
		100.0 - average_commute * 0.55 - unserved_share * 45.0 - fare_burden * 120.0,
		0.0,
		100.0
	)
	var metrics := {
		"transit_share": float(mode_shares.get("transit", 0.0)),
		"car_share": float(mode_shares.get("car", 0.0)),
		"unserved_share": unserved_share,
		"average_commute_minutes": average_commute,
		"expected_transit_trips_per_hour": transit_daily / 24.0,
		"expected_transit_boardings_per_hour": transit_boardings_daily / 24.0,
		"average_transit_capacity_pressure": transit_capacity_pressure_trip_sum / transit_daily if transit_daily > 0.000001 else 0.0,
		"resident_count": roundi(resident_count),
		"average_wellbeing": wellbeing,
		"public_treasury": money,
		"average_fare_burden": fare_burden,
		"total_od_pairs": total_od_pairs,
		"reachable_transit_od_pairs": reachable_od_pairs,
		"reachable_car_od_pairs": reachable_car_od_pairs,
		"cohort_welfare": choice.get("cohort_welfare", {}).duplicate(true),
		"age_group_transport": _resident_age_transport_metrics(choice.get("cohort_welfare", {})),
		"od_diagnostics": od_diagnostics,
		"districts": district_transport_metrics,
	}
	_resident_transport_snapshot_cache = {
		"signature": signature,
		"metrics": metrics,
		"choice": choice,
		"routes_by_od": route_by_od,
		"routes_by_od_age": route_by_od_age,
	}
	return _resident_transport_snapshot_cache


func _resident_transport_signature() -> String:
	var parts: Array[String] = [str(Data.ECONOMY["fare_per_passenger"])]
	var health_districts: Dictionary = city.get("resident_health_state", {}).get("districts", {})
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		var point := _resident_point(settlement.get("position", Vector2.ZERO))
		parts.append("%s:%.3f:%.3f:%.1f" % [
			str(settlement.get("id", "")),
			point.x,
			point.y,
			maxf(0.0, float(settlement.get("population", 0.0))),
		])
		parts.append("jobs:%s:%.1f" % [
			str(settlement.get("id", "")),
			maxf(0.0, float(settlement.get("jobs", 0.0))),
		])
		var health_district: Dictionary = health_districts.get(str(settlement.get("id", "")), {})
		var health_cohorts: Dictionary = health_district.get("cohorts", {})
		var health_cohort_ids: Array[String] = []
		for cohort_id_value in health_cohorts.keys():
			health_cohort_ids.append(str(cohort_id_value))
		health_cohort_ids.sort()
		for cohort_id in health_cohort_ids:
			var health_cohort: Dictionary = health_cohorts.get(cohort_id, {})
			parts.append("age:%s:%s:%.3f" % [
				str(settlement.get("id", "")),
				str(health_cohort.get("age_group", cohort_id)),
				maxf(0.0, float(health_cohort.get("population", 0.0))),
			])
	var roads_by_id: Dictionary = {}
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		roads_by_id[str(road.get("id", ""))] = road
	var road_ids: Array[String] = []
	for road_id_value in roads_by_id.keys():
		road_ids.append(str(road_id_value))
	road_ids.sort()
	for road_id in road_ids:
		var road: Dictionary = roads_by_id[road_id]
		var road_class := str(road.get("class", "local"))
		var base_profile := RoadProfile.base_profile(road_class)
		var profile: Dictionary = road.get("profile", base_profile)
		parts.append("road:%s:%s:%s:%.2f" % [
			road_id,
			str(road.get("status", "")),
			road_class,
			float(profile.get("speed_kph", RESIDENT_CAR_SPEED_KPH)),
		])
	var line_ids: Array[String] = []
	for line_id_value in transit_network.get("lines", {}).keys():
		line_ids.append(str(line_id_value))
	line_ids.sort()
	var network_lines: Dictionary = transit_network.get("lines", {})
	for line_id in line_ids:
		var line: Dictionary = network_lines.get(line_id, {})
		parts.append("%s:%s:%d:%s:%s:%s" % [
			line_id,
			str(line.get("status", "")),
			int(line.get("fleet_count", 0)),
			str(line.get("stop_ids", [])),
			str(line.get("route_segments", [])),
			str(line.get("mode", "bus")),
		])
		parts.append("capacity:%s:%.4f" % [line_id, clampf(float(line.get("crowding_ratio", 0.0)), 0.0, 1.0)])
	var stop_ids: Array[String] = []
	for stop_id_value in transit_network.get("stops", {}).keys():
		stop_ids.append(str(stop_id_value))
	stop_ids.sort()
	var stops: Dictionary = transit_network.get("stops", {})
	for stop_id in stop_ids:
		var stop: Dictionary = stops.get(stop_id, {})
		parts.append("%s:%s:%.3f:%.3f:%s" % [
			stop_id,
			str(stop.get("status", "")),
			float(stop.get("x", 0.0)),
			float(stop.get("y", 0.0)),
			str(stop.get("served_line_ids", [])),
		])
	return "|".join(parts)


func _resident_age_cohorts(settlement_id: String, population: float) -> Array[Dictionary]:
	var totals := {"children": 0.0, "adults": 0.0, "seniors": 0.0}
	var health_state: Dictionary = city.get("resident_health_state", {})
	var districts: Dictionary = health_state.get("districts", {})
	var district: Dictionary = districts.get(settlement_id, {})
	var cohorts: Dictionary = district.get("cohorts", {})
	var cohort_population := 0.0
	for cohort_id_value in cohorts.keys():
		var cohort_id := str(cohort_id_value)
		var cohort: Dictionary = cohorts[cohort_id_value]
		var age_group := _resident_age_group_name(str(cohort.get("age_group", cohort_id)))
		var age_population := maxf(0.0, float(cohort.get("population", 0.0)))
		totals[age_group] = float(totals[age_group]) + age_population
		cohort_population += age_population
	if cohort_population <= 0.000001:
		totals = DEFAULT_RESIDENT_AGE_SHARES.duplicate(true)
		cohort_population = 1.0
	var result: Array[Dictionary] = []
	for profile_value in RESIDENT_AGE_PROFILES:
		var profile: Dictionary = profile_value
		var age_group := str(profile["id"])
		var age_weight := float(totals.get(age_group, 0.0)) / cohort_population
		result.append({
			"age_group": age_group,
			"population": population * age_weight,
		})
	return result


func _resident_age_group_name(value: String) -> String:
	var normalized := value.strip_edges().to_lower()
	if normalized in ["child", "children", "youth", "young"]:
		return "children"
	if normalized in ["senior", "seniors", "elderly", "older", "retired"]:
		return "seniors"
	return "adults"


func _resident_age_profile(age_group: String) -> Dictionary:
	for profile_value in RESIDENT_AGE_PROFILES:
		var profile: Dictionary = profile_value
		if str(profile.get("id", "adults")) == age_group:
			return profile
	return RESIDENT_AGE_PROFILES[1]


func _resident_age_route_key(od_id: String, age_group: String) -> String:
	return "%s|%s" % [od_id, age_group]


func _resident_age_transport_metrics(cohort_welfare: Dictionary) -> Dictionary:
	var aggregates := {
		"children": {"population": 0.0, "trips": 0.0, "car": 0.0, "transit": 0.0, "unserved": 0.0, "fare": 0.0, "income_base": 0.0, "commute_minutes": 0.0},
		"adults": {"population": 0.0, "trips": 0.0, "car": 0.0, "transit": 0.0, "unserved": 0.0, "fare": 0.0, "income_base": 0.0, "commute_minutes": 0.0},
		"seniors": {"population": 0.0, "trips": 0.0, "car": 0.0, "transit": 0.0, "unserved": 0.0, "fare": 0.0, "income_base": 0.0, "commute_minutes": 0.0},
	}
	for cohort_value in cohort_welfare.values():
		if typeof(cohort_value) != TYPE_DICTIONARY:
			continue
		var cohort: Dictionary = cohort_value
		var age_group := _resident_age_group_name(str(cohort.get("age_group", "adults")))
		var accumulator: Dictionary = aggregates[age_group]
		var flows: Dictionary = cohort.get("flows", {})
		accumulator["population"] = float(accumulator["population"]) + maxf(0.0, float(cohort.get("population", 0.0)))
		accumulator["trips"] = float(accumulator["trips"]) + maxf(0.0, float(cohort.get("trips", 0.0)))
		accumulator["commute_minutes"] = float(accumulator["commute_minutes"]) + maxf(0.0, float(cohort.get("average_commute_minutes", 0.0))) * maxf(0.0, float(cohort.get("trips", 0.0)))
		accumulator["income_base"] = float(accumulator["income_base"]) + maxf(0.0, float(cohort.get("income_base", 0.0)))
		for mode in ["car", "transit", "unserved"]:
			accumulator[mode] = float(accumulator[mode]) + maxf(0.0, float(flows.get(mode, 0.0)))
		accumulator["fare"] = float(accumulator["fare"]) + maxf(0.0, float(cohort.get("expected_fare_paid", 0.0)))
		aggregates[age_group] = accumulator
	var result: Dictionary = {}
	for age_group in aggregates:
		var accumulator: Dictionary = aggregates[age_group]
		var trips := float(accumulator["trips"])
		result[age_group] = {
			"population": float(accumulator["population"]),
			"trips_per_day": trips,
			"average_commute_minutes": float(accumulator["commute_minutes"]) / trips if trips > 0.000001 else 0.0,
			"car_share": float(accumulator["car"]) / trips if trips > 0.000001 else 0.0,
			"transit_share": float(accumulator["transit"]) / trips if trips > 0.000001 else 0.0,
			"unserved_share": float(accumulator["unserved"]) / trips if trips > 0.000001 else 0.0,
			"expected_fare_paid": float(accumulator["fare"]),
			"fare_burden": float(accumulator["fare"]) / float(accumulator["income_base"]) if float(accumulator["income_base"]) > 0.000001 else 0.0,
			"fare_per_transit_trip": float(accumulator["fare"]) / float(accumulator["transit"]) if float(accumulator["transit"]) > 0.000001 else 0.0,
		}
	return result


func _resident_operational_stops() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var stops: Dictionary = transit_network.get("stops", {})
	var stop_ids: Array[String] = []
	for stop_id_value in stops.keys():
		stop_ids.append(str(stop_id_value))
	stop_ids.sort()
	for stop_id in stop_ids:
		var stop: Dictionary = stops[stop_id]
		if str(stop.get("status", "")) != "built":
			continue
		var operational_lines: Array[String] = []
		for line_id_value in stop.get("served_line_ids", []):
			var line_id := str(line_id_value)
			if _resident_line_operational(line_id):
				operational_lines.append(line_id)
		operational_lines.sort()
		if operational_lines.is_empty():
			continue
		result.append({
			"id": stop_id,
			"position": TransitNetwork.stop_position(transit_network, stop_id),
			"line_ids": operational_lines,
		})
	return result


func _resident_line_operational(line_id: String) -> bool:
	var network_lines: Dictionary = transit_network.get("lines", {})
	if not network_lines.has(line_id):
		return false
	var line: Dictionary = network_lines[line_id]
	return str(line.get("status", "")) == "active" and int(line.get("fleet_count", 0)) > 0


func _resident_stop_served_by(stop_id: String, line_id: String) -> bool:
	var stops: Dictionary = transit_network.get("stops", {})
	if not stops.has(stop_id):
		return false
	var stop: Dictionary = stops[stop_id]
	return str(stop.get("status", "")) == "built" and line_id in stop.get("served_line_ids", [])


func _best_resident_transit_route(
	origin: Vector2,
	destination: Vector2,
	available_stops: Array[Dictionary],
	journey_cache: Dictionary,
	walk_radius: float = RESIDENT_STOP_WALK_RADIUS,
	walk_speed: float = RESIDENT_WALK_SPEED_METERS_PER_MINUTE
) -> Dictionary:
	var origin_candidates: Array[Dictionary] = []
	var destination_candidates: Array[Dictionary] = []
	for stop in available_stops:
		var position: Vector2 = stop["position"]
		var origin_distance := origin.distance_to(position)
		if origin_distance <= walk_radius:
			origin_candidates.append({"stop": stop, "distance": origin_distance})
		var destination_distance := destination.distance_to(position)
		if destination_distance <= walk_radius:
			destination_candidates.append({"stop": stop, "distance": destination_distance})
	if origin_candidates.is_empty() or destination_candidates.is_empty():
		return {"reachable": false, "minutes": 0.0, "ride_count": 0, "legs": []}

	var best: Dictionary = {}
	var best_minutes := INF
	var best_key := ""
	for origin_candidate_value in origin_candidates:
		var origin_candidate: Dictionary = origin_candidate_value
		var origin_stop: Dictionary = origin_candidate["stop"]
		var from_stop_id := str(origin_stop["id"])
		for destination_candidate_value in destination_candidates:
			var destination_candidate: Dictionary = destination_candidate_value
			var destination_stop: Dictionary = destination_candidate["stop"]
			var to_stop_id := str(destination_stop["id"])
			if from_stop_id == to_stop_id:
				continue
			var journey_key := "%s>%s@%.1f" % [from_stop_id, to_stop_id, walk_speed]
			var journey: Dictionary = journey_cache.get(journey_key, {})
			if journey.is_empty():
				journey = TransitPlanner.find_journey(
					transit_network,
					from_stop_id,
					to_stop_id,
					TransitNetwork.TRANSFER_WALK_RADIUS,
					walk_speed
				)
				journey_cache[journey_key] = journey
			if not bool(journey.get("success", false)):
				continue
			var route := _resident_journey_metrics(
				journey,
				from_stop_id,
				to_stop_id,
				float(origin_candidate["distance"]),
				float(destination_candidate["distance"]),
				walk_speed
			)
			if not bool(route.get("reachable", false)):
				continue
			var route_key := str(route.get("route_key", ""))
			var route_minutes := float(route.get("minutes", INF))
			if (
				route_minutes < best_minutes - 0.000001
				or (is_equal_approx(route_minutes, best_minutes) and (best_key.is_empty() or route_key < best_key))
			):
				best = route
				best_minutes = route_minutes
				best_key = route_key
	return best if not best.is_empty() else {"reachable": false, "minutes": 0.0, "ride_count": 0, "legs": []}


func _resident_journey_metrics(
	journey: Dictionary,
	from_stop_id: String,
	to_stop_id: String,
	access_distance: float,
	egress_distance: float,
	walk_speed: float = RESIDENT_WALK_SPEED_METERS_PER_MINUTE
) -> Dictionary:
	var legs: Array = journey.get("legs", [])
	var ride_count := 0
	var capacity_pressure := 0.0
	var safe_walk_speed := maxf(1.0, walk_speed)
	var minutes := (access_distance + egress_distance) / safe_walk_speed
	var route_parts: Array[String] = [from_stop_id]
	for leg_value in legs:
		var leg: Dictionary = leg_value
		var mode := str(leg.get("mode", ""))
		var leg_from := str(leg.get("from_stop_id", ""))
		var leg_to := str(leg.get("to_stop_id", ""))
		if mode == "ride":
			var line_id := str(leg.get("line_id", ""))
			if not _resident_line_operational(line_id):
				return {"reachable": false, "minutes": 0.0, "ride_count": 0, "legs": []}
			var network_lines: Dictionary = transit_network.get("lines", {})
			var line: Dictionary = network_lines.get(line_id, {})
			capacity_pressure = maxf(
				capacity_pressure,
				clampf(float(line.get("crowding_ratio", 0.0)), 0.0, 1.0)
			)
			var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
			if not stop_ids.has(leg_from) or not stop_ids.has(leg_to):
				return {"reachable": false, "minutes": 0.0, "ride_count": 0, "legs": []}
			if not _resident_stop_served_by(leg_from, line_id) or not _resident_stop_served_by(leg_to, line_id):
				return {"reachable": false, "minutes": 0.0, "ride_count": 0, "legs": []}
			var ride_world_distance := maxf(0.0, float(leg.get("cost", 0.0)))
			if ride_world_distance <= 0.0:
				ride_world_distance = TransitNetwork.stop_position(transit_network, leg_from).distance_to(
					TransitNetwork.stop_position(transit_network, leg_to)
				)
			var transit_speed := float(TransitModes.profile(str(line.get("mode", "bus"))).get("speed_kph", Data.BUS["speed_kph"]))
			minutes += ride_world_distance / float(Data.WORLD_UNITS_PER_KM) / maxf(1.0, transit_speed) * 60.0
			var headway := _resident_line_headway(line_id, line)
			minutes += minf(30.0, maxf(0.0, headway * 0.5))
			minutes += RESIDENT_CAPACITY_PENALTY_MINUTES * clampf(
				float(line.get("crowding_ratio", 0.0)),
				0.0,
				1.0
			)
			ride_count += 1
			route_parts.append("%s:%s>%s" % [line_id, leg_from, leg_to])
		elif mode == "walk":
			var walk_distance := TransitNetwork.stop_position(transit_network, leg_from).distance_to(
				TransitNetwork.stop_position(transit_network, leg_to)
			)
			minutes += walk_distance / safe_walk_speed + 3.0
			route_parts.append("walk:%s>%s" % [leg_from, leg_to])
	if ride_count <= 0:
		return {"reachable": false, "minutes": 0.0, "ride_count": 0, "legs": []}
	route_parts.append(to_stop_id)
	return {
		"reachable": true,
		"minutes": minutes,
		"ride_count": ride_count,
		"capacity_pressure": capacity_pressure,
		"from_stop_id": from_stop_id,
		"to_stop_id": to_stop_id,
		"legs": legs.duplicate(true),
		"route_key": "|".join(route_parts),
	}


func _resident_line_headway(line_id: String, line: Dictionary) -> float:
	if str(line.get("source", "")) == "custom":
		var custom_headway := custom_line_headway_minutes(line_id)
		if not is_inf(custom_headway) and custom_headway > 0.0:
			return custom_headway
	var legacy_key := str(line.get("legacy_line_key", line_id))
	if lines.has(legacy_key):
		var legacy_headway := line_headway_minutes(legacy_key)
		if not is_inf(legacy_headway) and legacy_headway > 0.0:
			return legacy_headway
	return 24.0


func _resident_destination_distribution(origin: Dictionary, settlements: Array[Dictionary]) -> Array[Dictionary]:
	# Allocate each origin's daily trips by job attraction, tier, and distance gravity.
	var candidates: Array[Dictionary] = []
	var total_weight := 0.0
	var origin_id := str(origin.get("id", ""))
	var origin_position: Vector2 = origin.get("position", Vector2.ZERO)
	for settlement in settlements:
		var settlement_id := str(settlement.get("id", ""))
		if settlement_id == origin_id:
			continue
		var employment := maxf(1.0, float(settlement.get("jobs", 0.0)))
		var destination_position: Vector2 = settlement.get("position", Vector2.ZERO)
		var distance_km := origin_position.distance_to(destination_position) / float(Data.WORLD_UNITS_PER_KM)
		var distance_friction := pow(maxf(1.0, distance_km), 1.15)
		var weight := employment / distance_friction
		match str(settlement.get("tier", "")):
			"capital":
				weight *= 1.65
			"market":
				weight *= 1.10
			"village":
				weight *= 0.75
		candidates.append({
			"settlement": settlement,
			"weight": weight,
			"employment_attraction": employment,
			"distance_km": distance_km,
		})
		total_weight += weight
	if total_weight <= 0.0:
		return []
	for index in range(candidates.size()):
		var candidate: Dictionary = candidates[index]
		candidate["share"] = float(candidate["weight"]) / total_weight
		candidates[index] = candidate
	return candidates


func _resident_car_route(origin: Vector2, destination: Vector2) -> Dictionary:
	var route := RoadRouter.route_between_points(
		city,
		origin,
		destination,
		true,
		true,
		RESIDENT_CAR_MAX_SNAP_DISTANCE
	)
	if not bool(route.get("success", false)):
		return {"minutes": 0.0, "cost": 0.0, "reachable": false}

	var roads_by_id: Dictionary = {}
	for road_value in city.get("roads", []):
		if typeof(road_value) == TYPE_DICTIONARY:
			var road: Dictionary = road_value
			roads_by_id[str(road.get("id", ""))] = road
	var route_minutes := 0.0
	for edge_value in route.get("edge_path", []):
		var edge: Dictionary = edge_value
		var road: Dictionary = roads_by_id.get(str(edge.get("road_id", "")), {})
		var road_class := str(edge.get("class", road.get("class", "local")))
		var default_profile := RoadProfile.base_profile(road_class)
		var profile: Dictionary = road.get("profile", default_profile)
		var speed_kph := maxf(5.0, float(profile.get("speed_kph", RESIDENT_CAR_SPEED_KPH)))
		route_minutes += float(edge.get("length", 0.0)) / float(Data.WORLD_UNITS_PER_KM) / speed_kph * 60.0

	var start_snap: Dictionary = route.get("start_snap", {})
	var end_snap: Dictionary = route.get("end_snap", {})
	var access_distance := (
		maxf(0.0, float(start_snap.get("distance", 0.0)))
		+ maxf(0.0, float(end_snap.get("distance", 0.0)))
	)
	var access_minutes := (
		access_distance / float(Data.WORLD_UNITS_PER_KM)
		/ RESIDENT_CAR_ACCESS_SPEED_KPH * 60.0
	)
	var driven_distance := maxf(0.0, float(route.get("length", 0.0))) * RESIDENT_CAR_CIRCUITY
	var distance_km := driven_distance / float(Data.WORLD_UNITS_PER_KM)
	return {
		"minutes": maxf(0.0, RESIDENT_CAR_FIXED_MINUTES + route_minutes + access_minutes),
		"cost": 0.75 + distance_km * 0.32,
		"reachable": true,
	}


func _resident_od_id(origin_id: String, destination_id: String) -> String:
	return "%s>%s" % [origin_id, destination_id]


func _resident_point(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if typeof(value) == TYPE_DICTIONARY:
		var point: Dictionary = value
		return Vector2(float(point.get("x", 0.0)), float(point.get("y", 0.0)))
	return Vector2.ZERO

func reset_state(emit_signal: bool = true, new_city_seed: int = Data.DEFAULT_CITY_SEED) -> void:
	elapsed_seconds = 0.0
	simulation_speed = 1
	city_seed = new_city_seed
	world_map = WorldMapDefinition.create(WorldMapDefinition.DEFAULT_MAP_ID, city_seed)
	money = float(Data.ECONOMY["sandbox_starting_money"])
	WorldMapDefinition.set_active(world_map)
	TerrainSurface.set_terrain_edit_payload(world_map.get("terrain_edits", {}))
	terrain_tool_mode = ""
	selected = ""
	route_editor = _empty_route_editor()
	road_builder = _empty_road_builder()
	depot_placement_mode = false
	selected_transit_mode = "bus"
	_custom_catchment_cache.clear()
	_resident_transport_snapshot_cache.clear()
	_resident_health_snapshot_cache.clear()

	lines = {}
	for line_key in Data.LINE_KEYS:
		var line_state := _new_line_state(line_key)
		line_state["stop_count"] = 0
		lines[line_key] = line_state

	stations = {}
	for station_id in Data.all_station_ids():
		stations[station_id] = {"level": 0}

	depot = {
		"built": false,
		"garage_slots": 4,
		"level": 0,
		"position": null,
	}

	city = CityRuntime.create_initial_city(city_seed, str(world_map.get("id", WorldMapDefinition.LEGACY_CITY_MAP_ID)))
	_sync_world_map_external_connections()
	transit_network = _empty_transit_network()
	CityRuntime.sync_with_transport(self)

	stats = {
		"lifetime_revenue": 0.0,
		"lifetime_operating_costs": 0.0,
		"lifetime_passengers": 0.0,
		"last_fare_event_value": 0.0,
		"last_operating_cost": 0.0,
		"last_fare_event_serial": 0,
		"last_fare_line": "",
		"last_fare_stop_index": -1,
	}
	if is_sandbox():
		var initial_transport := _resident_transport_snapshot()
		var initial_metrics: Dictionary = initial_transport.get("metrics", {})
		var initial_health: Dictionary = ResidentHealth.advance(
			{},
			_resident_health_input(initial_metrics),
			0.0
		)
		city["resident_health_state"] = initial_health.get("state", {})
		_resident_health_snapshot_cache = {
			"signature": _resident_health_signature(str(initial_transport.get("signature", ""))),
			"metrics": initial_health.get("metrics", {}),
		}

	if emit_signal:
		state_changed.emit()
		selection_changed.emit(selected)


func raise_terrain(center: Vector2, radius: float, strength: float) -> Dictionary:
	return _apply_terrain_edit("raise", center, radius, strength)


func lower_terrain(center: Vector2, radius: float, strength: float) -> Dictionary:
	return _apply_terrain_edit("lower", center, radius, strength)


func flatten_terrain_to_target(
	center: Vector2,
	radius: float,
	target_height: float,
	strength: float = 1.0
) -> Dictionary:
	return _apply_terrain_edit("flatten_target", center, radius, strength, target_height)


func flatten_terrain_to_sample(
	center: Vector2,
	radius: float,
	strength: float = 1.0
) -> Dictionary:
	return _apply_terrain_edit("flatten_sample", center, radius, strength)


func smooth_terrain(center: Vector2, radius: float, strength: float = 1.0) -> Dictionary:
	return _apply_terrain_edit("smooth", center, radius, strength)


func _apply_terrain_edit(
	operation: String,
	center: Vector2,
	radius: float,
	strength: float,
	target_height: float = 0.0
) -> Dictionary:
	var terrain_seed := int(world_map.get("seed", city_seed))
	var raw_edits: Variant = world_map.get("terrain_edits", {})
	var layer: TerrainEditData
	if typeof(raw_edits) == TYPE_DICTIONARY and not (raw_edits as Dictionary).is_empty():
		var imported: Dictionary = TerrainEditData.from_dict(raw_edits)
		if not bool(imported.get("ok", false)):
			return {"ok": false, "error": str(imported.get("error", "invalid terrain edits"))}
		layer = imported["data"]
		if layer.seed != terrain_seed:
			return {"ok": false, "error": "terrain edits use a different seed than the active map"}
	else:
		layer = TerrainEditData.new(
			terrain_seed,
			TerrainSurface.SAMPLE_STEP,
			TerrainEditData.SOURCE_TERRAIN_MODEL
		)

	var result: Dictionary = {}
	match operation:
		"raise":
			result = layer.raise_brush(center, radius, strength)
		"lower":
			result = layer.lower_brush(center, radius, strength)
		"flatten_target":
			result = layer.flatten_to_target(center, radius, target_height, strength)
		"flatten_sample":
			result = layer.flatten_to_terrain_sample(center, radius, strength)
		"smooth":
			result = layer.smooth_brush(center, radius, strength)
		_:
			return {"ok": false, "error": "unknown terrain edit operation"}
	if not bool(result.get("ok", false)) or int(result.get("changed", 0)) <= 0:
		return result

	world_map["terrain_edits"] = layer.to_dict()
	WorldMapDefinition.set_active(world_map)
	TerrainSurface.set_terrain_edit_payload(world_map["terrain_edits"])
	terrain_changed.emit()
	if not suppress_persistence:
		save_game()
	return result


func _sync_world_map_external_connections() -> void:
	var generated: Array = city.get("outside_connections", [])
	if generated.is_empty():
		return
	var serialized: Array[Dictionary] = []
	for connection in generated:
		var position: Vector2 = connection.get("position", Vector2.ZERO)
		serialized.append({
			"id": str(connection.get("id", "")),
			"kind": str(connection.get("kind", "road")),
			"side": str(connection.get("side", "")),
			"position": {"x": position.x, "y": position.y},
		})
	world_map["outside_connections"] = serialized
	WorldMapDefinition.set_active(world_map)

func set_speed(speed: int) -> void:
	if speed not in [0, 1, 2, 4]:
		return
	simulation_speed = speed
	state_changed.emit()

func set_selection(value: String) -> void:
	selected = value
	selection_changed.emit(selected)

func transit_stop(stop_id: String) -> Dictionary:
	var stops: Dictionary = transit_network.get("stops", {})
	return stops.get(stop_id, {}).duplicate(true)

func transit_line(line_id: String) -> Dictionary:
	var network_lines: Dictionary = transit_network.get("lines", {})
	return network_lines.get(line_id, {}).duplicate(true)

func snap_transit_point(
	point: Vector2,
	built_only: bool = true,
	max_distance: float = 90.0
) -> Dictionary:
	return RoadRouter.snap_to_road(city, point, built_only, max_distance)

func preview_transit_route(
	start_point: Vector2,
	end_point: Vector2,
	built_only: bool = true,
	prefer_major_roads: bool = true,
	max_snap_distance: float = 90.0
) -> Dictionary:
	if _route_editor_transit_mode() == "metro":
		return _direct_transit_route(start_point, end_point, [])
	return RoadRouter.route_between_points(
		city,
		start_point,
		end_point,
		built_only,
		prefer_major_roads,
		max_snap_distance
	)


func _route_editor_transit_mode() -> String:
	if route_editor_active():
		return str(route_editor.get("transit_mode", "bus"))
	return selected_transit_mode


func snap_transit_point_for_editor(
	point: Vector2,
	built_only: bool = true,
	max_distance: float = 90.0
) -> Dictionary:
	if _route_editor_transit_mode() != "metro":
		return snap_transit_point(point, built_only, max_distance)
	var bounds := TerrainSurface.world_bounds()
	if not bounds.has_point(point):
		return {}
	return {"valid": true, "point": point, "distance": 0.0, "road_id": "", "road_class": ""}


func _direct_transit_route(start_point: Vector2, end_point: Vector2, waypoints: Array) -> Dictionary:
	var bounds := TerrainSurface.world_bounds()
	var controls: Array[Vector2] = [start_point]
	for waypoint_value in waypoints:
		if waypoint_value is Vector2:
			controls.append(waypoint_value)
		elif waypoint_value is Dictionary:
			var raw: Dictionary = waypoint_value
			controls.append(Vector2(float(raw.get("x", 0.0)), float(raw.get("y", 0.0))))
	controls.append(end_point)
	var length := 0.0
	for point in controls:
		if not bounds.has_point(point):
			return {"success": false, "reason": "outside_map_bounds", "points": [], "length": 0.0, "road_ids": []}
	for index in range(controls.size() - 1):
		length += controls[index].distance_to(controls[index + 1])
	return {"success": true, "reason": "", "points": controls, "length": length, "road_ids": [], "grade_separated": true}

func _empty_route_editor() -> Dictionary:
	return {
		"active": false,
		"mode": "",
		"line_id": "",
		"transit_mode": "bus",
		"draft_points": [],
		"draft_stop_ids": [],
		"draft_waypoints": [],
		"selected_index": -1,
		"hover_point": null,
		"hover_valid": false,
		"preview_route": {},
		"estimated_cost": 0,
	}

func route_editor_active() -> bool:
	return bool(route_editor.get("active", false))

func road_builder_active() -> bool:
	return bool(road_builder.get("active", false))

func road_builder_points() -> Array[Vector2]:
	var result: Array[Vector2] = []
	for point_value in road_builder.get("draft_points", []):
		if point_value is Vector2:
			result.append(point_value)
		elif typeof(point_value) == TYPE_DICTIONARY:
			var point: Dictionary = point_value
			result.append(Vector2(float(point.get("x", 0.0)), float(point.get("y", 0.0))))
	return result

func begin_road_builder(road_class: String = "collector") -> bool:
	if not is_sandbox():
		_request_toast("Road construction is available in the regional sandbox.")
		return false
	if route_editor_active():
		_request_toast("Finish or cancel the current line first.")
		return false
	if road_class not in RoadProfile.ROAD_CLASSES:
		return false
	depot_placement_mode = false
	terrain_tool_mode = ""
	road_builder = _empty_road_builder()
	road_builder["active"] = true
	road_builder["road_class"] = road_class
	_request_toast("Click two points on completed roads to plan a connection.")
	state_changed.emit()
	return true


func cancel_road_builder() -> void:
	if not road_builder_active():
		return
	road_builder = _empty_road_builder()
	state_changed.emit()

func road_builder_add_point(point: Vector2) -> bool:
	if not road_builder_active() or road_builder_points().size() >= 2:
		return false
	var snap := RoadRouter.snap_to_road(
		city,
		point,
		true,
		ROAD_BUILDER_SNAP_DISTANCE
	)
	if snap.is_empty():
		_request_toast("Road endpoints must connect to an existing completed road.")
		return false
	var snapped_point: Vector2 = snap.get("point", point)
	var points := road_builder_points()
	if not points.is_empty() and points[0].distance_to(snapped_point) < ROAD_BUILDER_MIN_LENGTH:
		_request_toast("Choose a farther endpoint for this road.")
		return false
	points.append(snapped_point)
	var snaps: Array = road_builder.get("snaps", [])
	snaps.append(snap)
	road_builder["draft_points"] = points
	road_builder["snaps"] = snaps
	state_changed.emit()
	return true

func road_builder_undo_point() -> void:
	if not road_builder_active():
		return
	var points := road_builder_points()
	var snaps: Array = road_builder.get("snaps", [])
	if not points.is_empty():
		points.pop_back()
	if not snaps.is_empty():
		snaps.pop_back()
	road_builder["draft_points"] = points
	road_builder["snaps"] = snaps
	state_changed.emit()

func road_builder_preview() -> Dictionary:
	var points := road_builder_points()
	if points.size() != 2:
		return {"ok": false, "reason": "need_two_endpoints"}
	var snaps: Array = road_builder.get("snaps", [])
	if snaps.size() != 2:
		return {"ok": false, "reason": "missing_graph_endpoint"}
	var graph_endpoints: Array[String] = []
	for snap_value in snaps:
		if typeof(snap_value) != TYPE_DICTIONARY:
			return {"ok": false, "reason": "missing_graph_endpoint"}
		var endpoint_id := _road_builder_connectivity_node(snap_value)
		if endpoint_id.is_empty():
			return {"ok": false, "reason": "missing_graph_endpoint"}
		graph_endpoints.append(endpoint_id)
	var length := points[0].distance_to(points[1])
	if length < ROAD_BUILDER_MIN_LENGTH or length > ROAD_BUILDER_MAX_LENGTH:
		return {"ok": false, "reason": "road_length_out_of_range", "length": length}
	var bounds := TerrainSurface.world_bounds()
	var steps := maxi(1, ceili(length / 70.0))
	var previous_height := 0.0
	for index in range(steps + 1):
		var ratio := float(index) / float(steps)
		var point := points[0].lerp(points[1], ratio)
		if not bounds.has_point(point):
			return {"ok": false, "reason": "outside_map_bounds", "length": length}
		var height := TerrainSurface.height(city_seed, point.x, point.y)
		if index > 0:
			var horizontal_distance := length / float(steps)
			if absf(height - previous_height) / maxf(horizontal_distance, 0.001) > ROAD_BUILDER_MAX_GRADE_RATIO:
				return {"ok": false, "reason": "grade_too_steep", "length": length}
		previous_height = height
	var parent_ids: Array[String] = []
	for snap_value in snaps:
		var road_id := str(snap_value.get("road_id", ""))
		if not road_id.is_empty() and not parent_ids.has(road_id):
			parent_ids.append(road_id)
	parent_ids.sort()
	var road_class := str(road_builder.get("road_class", "collector"))
	var candidate := {
		"id": "road-preview",
		"class": road_class,
		"points": [_serialize_world_point(points[0]), _serialize_world_point(points[1])],
		"parentRoadIds": parent_ids,
		"a": graph_endpoints[0],
		"b": graph_endpoints[1],
		"level": 0.0,
	}
	if RoadTopology.has_parallel_overlap(candidate, city.get("roads", []), 8.0):
		return {"ok": false, "reason": "parallel_overlap", "length": length}
	var cost := roundi(length * float(Data.ECONOMY["sandbox_road_cost_per_world_unit"]))
	return {
		"ok": true,
		"length": length,
		"cost": cost,
		"road_class": road_class,
		"a": graph_endpoints[0],
		"b": graph_endpoints[1],
		"graph_endpoint_ids": graph_endpoints.duplicate(),
	}

func commit_road_builder() -> bool:
	if not road_builder_active():
		return false
	var preview := road_builder_preview()
	if not bool(preview.get("ok", false)):
		_request_toast("Road invalid: %s." % _road_builder_reason(str(preview.get("reason", "invalid"))))
		return false
	var cost := int(preview.get("cost", 0))
	if money < float(cost):
		_request_toast("Not enough money for this road.")
		return false
	var serial := int(city.get("next_player_road_serial", 1))
	city["next_player_road_serial"] = serial + 1
	var road_id := "player-road-%04d" % serial
	var points := road_builder_points()
	var parent_ids: Array[String] = []
	for snap_value in road_builder.get("snaps", []):
		var parent_id := str(snap_value.get("road_id", ""))
		if not parent_id.is_empty() and not parent_ids.has(parent_id):
			parent_ids.append(parent_id)
	parent_ids.sort()
	var road_class := str(road_builder.get("road_class", "collector"))
	var road := {
		"id": road_id,
		"districtId": "regional-infrastructure",
		"class": road_class,
		"points": [_serialize_world_point(points[0]), _serialize_world_point(points[1])],
		"unlock": null,
		"buildOrder": 100000 + serial,
		"source": "player",
		"a": str(preview.get("a", "")),
		"b": str(preview.get("b", "")),
		"graphEndpointIds": [str(preview.get("a", "")), str(preview.get("b", ""))],
		"parentRoadIds": parent_ids,
		"status": "planned",
		"constructionProgress": 0.0,
		"level": 0.0,
		"profile": RoadProfile.base_profile(road_class),
	}
	city["roads"].append(road)
	var graph := RoadTopology.compile_graph(city["roads"])
	city["nodes"] = graph.get("nodes", [])
	city["graph_edges"] = graph.get("graphEdges", [])
	city["junctions"] = graph.get("junctions", [])
	var project_serial := int(city.get("next_player_road_project_serial", 1))
	city["next_player_road_project_serial"] = project_serial + 1
	city["projects"].append({
		"id": "player-road-project-%04d" % project_serial,
		"type": "road",
		"targetId": road_id,
		"districtId": "regional-infrastructure",
		"status": "queued",
		"progress": 0.0,
		"duration": maxf(6.0, float(preview.get("length", 0.0)) / 110.0),
		"eligibleAt": float(city.get("time_seconds", 0.0)),
		"startedAt": null,
		"completedAt": null,
	})
	money -= float(cost)
	road_builder = _empty_road_builder()
	_request_toast("Road project started · $%s." % _compact_money(cost))
	_commit_change()
	return true


func _road_builder_connectivity_node(snap: Dictionary) -> String:
	var snap_point: Vector2 = _resident_point(snap.get("point", Vector2.ZERO))
	var road_id := str(snap.get("road_id", ""))
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("id", "")) != road_id:
			continue
		var a_id := str(road.get("a", ""))
		var b_id := str(road.get("b", ""))
		if not a_id.is_empty() and not b_id.is_empty():
			var points: Array = road.get("points", [])
			var along_ratio := _road_builder_snap_progress(points, snap_point)
			return a_id if along_ratio <= 0.5 else b_id
		if not a_id.is_empty():
			return a_id
		if not b_id.is_empty():
			return b_id
		var settlement_id := str(road.get("settlementId", road.get("settlement_id", "")))
		if not settlement_id.is_empty():
			return settlement_id
		break

	# Old non-regional roads may not carry semantic endpoints. Preserve a valid
	# graph node from the snapped edge so subsequent player roads can connect to it.
	var node_lookup: Dictionary = {}
	for node_value in city.get("nodes", []):
		if typeof(node_value) != TYPE_DICTIONARY:
			continue
		var node: Dictionary = node_value
		node_lookup[str(node.get("id", ""))] = _resident_point(node)
	var closest_id := ""
	var closest_distance := INF
	for node_id in [str(snap.get("a", "")), str(snap.get("b", ""))]:
		if not node_lookup.has(node_id):
			continue
		var distance := Vector2(node_lookup[node_id]).distance_to(snap_point)
		if distance < closest_distance:
			closest_id = node_id
			closest_distance = distance
	if not closest_id.is_empty():
		return closest_id
	return "map-node-%d-%d" % [roundi(snap_point.x * 10.0), roundi(snap_point.y * 10.0)]


func _road_builder_snap_progress(points: Array, point: Vector2) -> float:
	if points.size() < 2:
		return clampf(float(point.x), 0.0, 1.0)
	var total_length := RoadTopology.polyline_length(points)
	if total_length <= 0.001:
		return 0.0
	var accumulated := 0.0
	var closest_distance := INF
	var closest_along := 0.0
	for index in range(points.size() - 1):
		var start := _resident_point(points[index])
		var finish := _resident_point(points[index + 1])
		var segment := finish - start
		var segment_length := segment.length()
		if segment_length <= 0.001:
			continue
		var projected_t := clampf((point - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
		var projected := start + segment * projected_t
		var distance := projected.distance_to(point)
		if distance < closest_distance:
			closest_distance = distance
			closest_along = accumulated + segment_length * projected_t
		accumulated += segment_length
	return clampf(closest_along / total_length, 0.0, 1.0)

func _road_builder_reason(reason: String) -> String:
	match reason:
		"need_two_endpoints":
			return "choose two endpoints"
		"road_length_out_of_range":
			return "segment length is outside the supported range"
		"outside_map_bounds":
			return "segment leaves the map"
		"grade_too_steep":
			return "terrain grade is too steep"
		"parallel_overlap":
			return "segment overlaps an existing road"
		"missing_graph_endpoint":
			return "a snapped road connection has no graph node"
		_:
			return reason.replace("_", " ")


## Returns the construction state for a generated regional corridor. Only a
## planned road that touches the currently built regional network is a valid
## next project, preventing disconnected one-off routes from appearing.
func regional_road_build_status(road_id: String) -> Dictionary:
	if not is_sandbox():
		return {"available": false, "reason": "sandbox_only"}
	var target: Dictionary = {}
	for road_value in city.get("roads", []):
		if not (road_value is Dictionary):
			continue
		var candidate: Dictionary = road_value
		if str(candidate.get("id", "")) == road_id:
			target = candidate
			break
	if target.is_empty() or str(target.get("source", "")) not in ["regional-existing", "player"]:
		return {"available": false, "reason": "not_regional_road"}
	var road_status := str(target.get("status", ""))
	if road_status == "built":
		return {"available": false, "reason": "already_built", "status": road_status}
	for project_value in city.get("projects", []):
		if not (project_value is Dictionary):
			continue
		var project: Dictionary = project_value
		if str(project.get("type", "")) == "road" and str(project.get("targetId", "")) == road_id:
			if str(project.get("status", "")) in ["queued", "active", "complete"]:
				return {
					"available": false,
					"pending": str(project.get("status", "")) != "complete",
					"reason": "construction_pending",
					"status": road_status,
					"project_status": str(project.get("status", "")),
					"progress": float(project.get("progress", 0.0)),
				}
	if road_status != "planned":
		return {"available": false, "reason": "road_not_planned", "status": road_status}
	var connected_node := _regional_road_connected_endpoint(target)
	if connected_node.is_empty():
		return {"available": false, "reason": "not_connected_to_built_network", "status": road_status}
	var points: Array[Vector2] = []
	for point_value in target.get("points", []):
		points.append(_resident_point(point_value))
	var length := 0.0
	for index in range(1, points.size()):
		length += points[index - 1].distance_to(points[index])
	if points.size() < 2 or length < 1.0:
		return {"available": false, "reason": "invalid_geometry", "status": road_status}
	var road_class := str(target.get("class", "collector"))
	var class_multiplier := 1.0
	if road_class == "arterial":
		class_multiplier = 1.45
	elif road_class == "local":
		class_multiplier = 0.40
	var cost := roundi(length * float(Data.ECONOMY["sandbox_road_cost_per_world_unit"]) * class_multiplier)
	return {
		"available": money >= float(cost),
		"reason": "" if money >= float(cost) else "insufficient_funds",
		"status": road_status,
		"length": length,
		"cost": cost,
		"road_class": road_class,
		"regional_role": str(target.get("regionalRole", "")),
		"a": str(target.get("a", "")),
		"b": str(target.get("b", "")),
		"connected_node": connected_node,
		"new_node": str(target.get("b", "")) if connected_node == str(target.get("a", "")) else str(target.get("a", "")),
	}


func _regional_road_connected_endpoint(target: Dictionary) -> String:
	var connected_nodes: Dictionary = {}
	for road_value in city.get("roads", []):
		if not (road_value is Dictionary):
			continue
		var road: Dictionary = road_value
		if str(road.get("status", "")) != "built":
			continue
		for endpoint in [str(road.get("a", "")), str(road.get("b", ""))]:
			if not endpoint.is_empty():
				connected_nodes[endpoint] = true
	var a := str(target.get("a", ""))
	var b := str(target.get("b", ""))
	if connected_nodes.has(a):
		return a
	if connected_nodes.has(b):
		return b
	return ""


func build_regional_road(road_id: String) -> bool:
	var build_status := regional_road_build_status(road_id)
	if not bool(build_status.get("available", false)):
		var reason := str(build_status.get("reason", "invalid_road"))
		_request_toast("Regional road cannot be started: %s." % reason.replace("_", " "))
		return false
	var road: Dictionary = {}
	for road_value in city.get("roads", []):
		if str(road_value.get("id", "")) == road_id:
			road = road_value
			break
	if road.is_empty():
		return false
	var cost := int(build_status.get("cost", 0))
	var length := float(build_status.get("length", 0.0))
	var serial := int(city.get("next_player_road_project_serial", 1))
	city["next_player_road_project_serial"] = serial + 1
	road["source"] = "player"
	road["owner"] = "player"
	road["status"] = "planned"
	road["constructionProgress"] = 0.0
	city["projects"].append({
		"id": "regional-road-project-%04d" % serial,
		"type": "road",
		"targetType": "road",
		"targetId": road_id,
		"districtId": str(road.get("districtId", "regional-settlements")),
		"source": "player",
		"status": "queued",
		"queuedAt": float(city.get("time_seconds", 0.0)),
		"eligibleAt": float(city.get("time_seconds", 0.0)),
		"startedAt": null,
		"completedAt": null,
		"duration": maxf(6.0, length / 110.0),
		"progress": 0.0,
		"cost": cost,
	})
	money -= float(cost)
	_request_toast("Regional road project started · $%s." % _compact_money(cost))
	_commit_change()
	return true

func _serialize_world_point(point: Vector2) -> Dictionary:
	return {"x": point.x, "y": point.y}

func depot_placement_active() -> bool:
	return depot_placement_mode

func begin_depot_placement() -> bool:
	if not is_sandbox() or bool(depot.get("built", false)):
		return false
	if route_editor_active() or road_builder_active():
		_request_toast("Finish or cancel the current tool first.")
		return false
	if not _has_completed_road():
		_request_toast("Build a connected road before placing the depot.")
		return false
	terrain_tool_mode = ""
	depot_placement_mode = true
	_request_toast("Click beside a completed road to place the depot.")
	state_changed.emit()
	return true

func cancel_depot_placement() -> void:
	if not depot_placement_mode:
		return
	depot_placement_mode = false
	state_changed.emit()

func build_depot_at(point: Vector2) -> bool:
	if not depot_placement_mode or not is_sandbox() or bool(depot.get("built", false)):
		return false
	if not TerrainSurface.world_bounds().has_point(point):
		_request_toast("Choose a location inside the map.")
		return false
	var snap := RoadRouter.snap_to_road(city, point, true, 165.0)
	if snap.is_empty() or float(snap.get("distance", INF)) < 32.0:
		_request_toast("Place the depot close to, but not on, a completed road.")
		return false
	var cost := float(Data.ECONOMY["sandbox_depot_build_cost"])
	if money < cost:
		_request_toast("Not enough money to build the depot.")
		return false
	var slope := _terrain_grade_near(point, 70.0)
	if slope > ROAD_BUILDER_MAX_GRADE_RATIO:
		_request_toast("The depot site is too steep.")
		return false
	money -= cost
	depot["built"] = true
	depot["position"] = _serialize_world_point(point)
	depot_placement_mode = false
	_request_toast("Depot built · $%s." % _compact_money(roundi(cost)))
	_commit_change()
	return true

func _has_completed_road() -> bool:
	for road_value in city.get("roads", []):
		if str(road_value.get("status", "")) == "built":
			return true
	return false

func _terrain_grade_near(point: Vector2, radius: float) -> float:
	var center_height := TerrainSurface.height(city_seed, point.x, point.y)
	var sample_step := maxf(8.0, radius * 0.5)
	var maximum_grade := 0.0
	for offset_value in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var offset: Vector2 = offset_value
		var sample: Vector2 = point + offset * sample_step
		if not TerrainSurface.world_bounds().has_point(sample):
			continue
		var rise := absf(TerrainSurface.height(city_seed, sample.x, sample.y) - center_height)
		maximum_grade = maxf(maximum_grade, rise / sample_step)
	return maximum_grade

func _compact_money(amount: int) -> String:
	if amount >= 1000000:
		return "%.1fM" % (float(amount) / 1000000.0)
	if amount >= 10000:
		return "%.1fK" % (float(amount) / 1000.0)
	return str(amount)


func set_terrain_tool_mode(mode: String) -> void:
	var allowed_modes := ["", "raise", "lower", "flatten", "smooth"]
	var next_mode := mode if allowed_modes.has(mode) else ""
	if route_editor_active():
		next_mode = ""
	if not next_mode.is_empty():
		cancel_road_builder()
		cancel_depot_placement()
	if terrain_tool_mode == next_mode:
		return
	terrain_tool_mode = next_mode
	state_changed.emit()

func route_editor_points() -> Array[Vector2]:
	var result: Array[Vector2] = []
	for raw_value in route_editor.get("draft_points", []):
		if raw_value is Vector2:
			result.append(raw_value)
		elif typeof(raw_value) == TYPE_DICTIONARY:
			var raw: Dictionary = raw_value
			result.append(Vector2(
				float(raw.get("x", 0.0)),
				float(raw.get("y", 0.0))
			))
	return result

func route_editor_stop_ids() -> Array[String]:
	var result: Array[String] = []
	for value in route_editor.get("draft_stop_ids", []):
		result.append(str(value))
	var point_count := route_editor_points().size()
	while result.size() < point_count:
		result.append("")
	if result.size() > point_count:
		result.resize(point_count)
	return result

func route_editor_waypoints() -> Array:
	var stop_count := route_editor_points().size()
	var segment_count := maxi(0, stop_count - 1)
	var raw_waypoints = route_editor.get("draft_waypoints", [])
	var result: Array = []
	for segment_index in range(segment_count):
		var segment_points: Array[Vector2] = []
		if (
			typeof(raw_waypoints) == TYPE_ARRAY
			and segment_index < raw_waypoints.size()
			and typeof(raw_waypoints[segment_index]) == TYPE_ARRAY
		):
			for raw_value in raw_waypoints[segment_index]:
				if raw_value is Vector2:
					segment_points.append(raw_value)
				elif typeof(raw_value) == TYPE_DICTIONARY:
					var raw: Dictionary = raw_value
					segment_points.append(Vector2(
						float(raw.get("x", 0.0)),
						float(raw.get("y", 0.0))
					))
		result.append(segment_points)
	return result

func _set_route_editor_waypoints(waypoints: Array) -> void:
	var points := route_editor_points()
	var segment_count := maxi(0, points.size() - 1)
	var normalized: Array = []
	for segment_index in range(segment_count):
		var segment_points: Array[Vector2] = []
		if segment_index < waypoints.size():
			for point_value in waypoints[segment_index]:
				if point_value is Vector2:
					segment_points.append(point_value)
				elif typeof(point_value) == TYPE_DICTIONARY:
					var raw: Dictionary = point_value
					segment_points.append(Vector2(
						float(raw.get("x", 0.0)),
						float(raw.get("y", 0.0))
					))
		normalized.append(segment_points)
	route_editor["draft_waypoints"] = normalized

func _clear_route_editor_waypoints_if_needed() -> void:
	var waypoints := route_editor_waypoints()
	var had_waypoints := false
	for segment_value in waypoints:
		var segment: Array = segment_value
		if not segment.is_empty():
			had_waypoints = true
			break
	_set_route_editor_waypoints([])
	if had_waypoints:
		_request_toast("Routing waypoints reset after changing stop order.")

func can_begin_free_line() -> bool:
	return bool(depot.get("built", false)) and _has_free_garage_slot()


func _sandbox_population() -> int:
	var demographics: Dictionary = city.get("demographics", {})
	if demographics.has("residents"):
		return maxi(0, int(demographics.get("residents", 0)))
	var total := 0
	for settlement_value in city.get("regional_settlements", []):
		if settlement_value is Dictionary:
			total += maxi(0, int(settlement_value.get("population", 0)))
	return total


func transit_mode_status(mode: String) -> Dictionary:
	var unlocked_modes: Dictionary = transit_network.get("unlocked_modes", {"bus": true})
	if bool(unlocked_modes.get(mode, false)):
		var owned_line_cost := _minimum_transit_line_cost(mode)
		return {
			"unlocked": true,
			"reason": "already_unlocked",
			"unlock_cost": 0.0,
			"licence_cost": 0.0,
			"minimum_line_cost": owned_line_cost,
			"minimum_startup_capital": owned_line_cost,
			"funds_remaining": 0.0,
		}
	var profile := TransitModes.profile(mode)
	if profile.is_empty():
		return TransitModes.unlock_status(mode, _sandbox_population(), money)
	var licence_cost := float(profile.get("unlock_cost", 0.0))
	var minimum_line_cost := _minimum_transit_line_cost(mode)
	var minimum_startup_capital := minimum_line_cost + licence_cost
	var status := TransitModes.unlock_status(
		mode,
		_sandbox_population(),
		money,
		minimum_startup_capital
	)
	status["licence_cost"] = licence_cost
	status["minimum_line_cost"] = minimum_line_cost
	status["minimum_startup_capital"] = minimum_startup_capital
	return status


func _minimum_transit_line_cost(mode: String) -> float:
	var profile := TransitModes.profile(mode)
	if profile.is_empty():
		return 0.0
	var minimum_spacing := maxf(1.0, float(profile.get("minimum_stop_spacing", 1.0)))
	var minimum_route: Array[Vector2] = [Vector2.ZERO, Vector2(minimum_spacing, 0.0)]
	var estimate := free_line_build_cost(minimum_route, [], mode)
	if not bool(transit_network.get("unlocked_modes", {"bus": true}).get(mode, false)):
		estimate -= roundi(float(profile.get("unlock_cost", 0.0)))
	return maxf(0.0, float(estimate))


func transit_mode_profile(mode: String) -> Dictionary:
	return TransitModes.profile(mode)


func cycle_selected_transit_mode() -> String:
	var mode_ids := TransitModes.mode_ids()
	var current_index := mode_ids.find(selected_transit_mode)
	for offset in range(1, mode_ids.size() + 1):
		var candidate := str(mode_ids[posmod(current_index + offset, mode_ids.size())])
		var status := transit_mode_status(candidate)
		if bool(status.get("unlocked", false)):
			selected_transit_mode = candidate
			if route_editor_active() and str(route_editor.get("mode", "")) == "new":
				route_editor["transit_mode"] = candidate
				_update_route_editor_cost()
				route_editor_changed.emit()
			state_changed.emit()
			return candidate
		_request_toast(_transit_mode_locked_message(candidate, status))
	return selected_transit_mode


func _transit_mode_locked_message(mode: String, status: Dictionary) -> String:
	var profile := TransitModes.profile(mode)
	var reason := str(status.get("reason", "locked"))
	if reason == "population_requirement_not_met":
		return "%s unlocks at %s residents." % [mode.capitalize(), _compact_number(int(profile.get("unlock_population", 0)))]
	if reason == "unlock_cost_not_met":
		var capital_required := float(status.get(
			"minimum_startup_capital",
			status.get("unlock_cost", profile.get("unlock_cost", 0.0))
		))
		var funds_remaining := float(status.get("funds_remaining", 0.0))
		return "%s needs $%s for its licence and a minimum viable line; the treasury is short by $%s." % [
			mode.capitalize(),
			_compact_number(roundi(capital_required)),
			_compact_number(roundi(funds_remaining)),
		]
	return "%s is not unlocked." % mode.capitalize()


func _compact_number(value: int) -> String:
	if value >= 1000000:
		return "%.1fM" % (float(value) / 1000000.0)
	if value >= 1000:
		return "%.0fK" % (float(value) / 1000.0)
	return str(value)

func begin_free_line_editor() -> bool:
	if not can_begin_free_line():
		_request_toast("Build the depot and keep one garage slot free.")
		return false
	cancel_road_builder()
	cancel_depot_placement()
	terrain_tool_mode = ""
	route_editor = _empty_route_editor()
	route_editor["active"] = true
	route_editor["mode"] = "new"
	var mode_status := transit_mode_status(selected_transit_mode)
	if not bool(mode_status.get("unlocked", false)):
		_request_toast(_transit_mode_locked_message(selected_transit_mode, mode_status))
		selected_transit_mode = "bus"
	route_editor["transit_mode"] = selected_transit_mode
	route_editor["estimated_cost"] = free_line_build_cost([])
	set_selection("route_editor")
	route_editor_changed.emit()
	state_changed.emit()
	return true

func begin_edit_line_editor(line_id: String) -> bool:
	var line := transit_line(line_id)
	if line.is_empty() or str(line.get("source", "")) != "custom":
		return false
	terrain_tool_mode = ""
	route_editor = _empty_route_editor()
	route_editor["active"] = true
	route_editor["mode"] = "edit"
	route_editor["line_id"] = line_id
	route_editor["transit_mode"] = str(line.get("mode", "bus"))
	var points: Array[Vector2] = []
	for stop_id in TransitNetwork.line_stop_ids(transit_network, line_id):
		points.append(TransitNetwork.stop_position(transit_network, stop_id))
	route_editor["draft_points"] = points
	route_editor["draft_stop_ids"] = TransitNetwork.line_stop_ids(
		transit_network,
		line_id
	)
	var stored_waypoints := TransitNetwork.segment_waypoints(
		transit_network,
		line_id
	)
	var editor_waypoints: Array = []
	for segment_value in stored_waypoints:
		var segment: Array[Vector2] = []
		for waypoint_value in segment_value:
			if typeof(waypoint_value) == TYPE_DICTIONARY:
				var raw: Dictionary = waypoint_value
				segment.append(Vector2(
					float(raw.get("x", 0.0)),
					float(raw.get("y", 0.0))
				))
		editor_waypoints.append(segment)
	route_editor["draft_waypoints"] = editor_waypoints
	route_editor["estimated_cost"] = free_line_edit_cost(points, editor_waypoints)
	set_selection("route_editor")
	route_editor_changed.emit()
	state_changed.emit()
	return true

func cancel_route_editor() -> void:
	if not route_editor_active():
		return
	route_editor = _empty_route_editor()
	set_selection("")
	route_editor_changed.emit()
	state_changed.emit()

func set_route_editor_hover(
	point: Vector2,
	valid: bool,
	preview_route: Dictionary = {}
) -> void:
	if not route_editor_active():
		return
	route_editor["hover_point"] = point
	route_editor["hover_valid"] = valid
	route_editor["preview_route"] = preview_route
	route_editor_changed.emit()

func clear_route_editor_hover() -> void:
	if not route_editor_active():
		return
	route_editor["hover_point"] = null
	route_editor["hover_valid"] = false
	route_editor["preview_route"] = {}
	route_editor_changed.emit()

func show_route_editor_message(message: String) -> void:
	_request_toast(message)


func show_message(message: String) -> void:
	_request_toast(message)

func route_editor_select_stop(index: int) -> void:
	if not route_editor_active():
		return
	var points := route_editor_points()
	route_editor["selected_index"] = index if index >= 0 and index < points.size() else -1
	route_editor_changed.emit()
	state_changed.emit()

func route_editor_reorder_selected(delta: int) -> bool:
	if not route_editor_active() or delta == 0:
		return false
	var points := route_editor_points()
	var selected_index := int(route_editor.get("selected_index", -1))
	if selected_index < 0 or selected_index >= points.size():
		return false
	var target_index := selected_index + delta
	if target_index < 0 or target_index >= points.size():
		return false
	var temporary := points[selected_index]
	points[selected_index] = points[target_index]
	points[target_index] = temporary
	var stop_ids := route_editor_stop_ids()
	var temporary_id := stop_ids[selected_index]
	stop_ids[selected_index] = stop_ids[target_index]
	stop_ids[target_index] = temporary_id
	route_editor["draft_points"] = points
	route_editor["draft_stop_ids"] = stop_ids
	route_editor["selected_index"] = target_index
	_clear_route_editor_waypoints_if_needed()
	_update_route_editor_cost()
	route_editor_changed.emit()
	state_changed.emit()
	return true

func route_editor_add_waypoint(point: Vector2, segment_index: int) -> bool:
	if not route_editor_active():
		return false
	var points := route_editor_points()
	if segment_index < 0 or segment_index >= points.size() - 1:
		return false
	var snap := snap_transit_point_for_editor(point, true, 110.0)
	if snap.is_empty():
		_request_toast("Waypoints must be inside the map and on a built road for surface lines.")
		return false
	var snapped: Vector2 = snap["point"]
	var waypoints := route_editor_waypoints()
	var segment: Array[Vector2] = waypoints[segment_index]
	for existing in segment:
		if existing.distance_to(snapped) < 24.0:
			_request_toast("A routing waypoint is already nearby.")
			return false
	segment.append(snapped)
	waypoints[segment_index] = segment
	_set_route_editor_waypoints(waypoints)
	_update_route_editor_cost()
	route_editor_changed.emit()
	state_changed.emit()
	return true

func route_editor_remove_nearest_waypoint(
	point: Vector2,
	radius: float = 32.0
) -> bool:
	if not route_editor_active():
		return false
	var waypoints := route_editor_waypoints()
	var best_segment := -1
	var best_index := -1
	var best_distance := radius
	for segment_index in range(waypoints.size()):
		var segment: Array = waypoints[segment_index]
		for waypoint_index in range(segment.size()):
			var waypoint: Vector2 = segment[waypoint_index]
			var distance := waypoint.distance_to(point)
			if distance < best_distance:
				best_distance = distance
				best_segment = segment_index
				best_index = waypoint_index
	if best_segment < 0:
		return false
	var segment: Array = waypoints[best_segment]
	segment.remove_at(best_index)
	waypoints[best_segment] = segment
	_set_route_editor_waypoints(waypoints)
	_update_route_editor_cost()
	route_editor_changed.emit()
	state_changed.emit()
	return true

func preview_transit_route_via(
	start_point: Vector2,
	end_point: Vector2,
	waypoints: Array
) -> Dictionary:
	if _route_editor_transit_mode() == "metro":
		return _direct_transit_route(start_point, end_point, waypoints)
	var controls: Array[Vector2] = [start_point]
	for waypoint_value in waypoints:
		if waypoint_value is Vector2:
			controls.append(waypoint_value)
		elif typeof(waypoint_value) == TYPE_DICTIONARY:
			var raw: Dictionary = waypoint_value
			controls.append(Vector2(
				float(raw.get("x", 0.0)),
				float(raw.get("y", 0.0))
			))
	controls.append(end_point)

	var combined: Array[Vector2] = []
	var total := 0.0
	var road_ids: Array[String] = []
	for index in range(controls.size() - 1):
		var route := preview_transit_route(
			controls[index],
			controls[index + 1],
			true,
			true,
			115.0
		)
		if not bool(route.get("success", false)):
			return {
				"success": false,
				"reason": route.get("reason", "no_path"),
				"points": [],
				"length": 0.0,
				"road_ids": [],
			}
		total += float(route.get("length", 0.0))
		for road_id_value in route.get("road_ids", []):
			var road_id := str(road_id_value)
			if not road_ids.has(road_id):
				road_ids.append(road_id)
		for point_value in route.get("points", []):
			if not (point_value is Vector2):
				continue
			var route_point: Vector2 = point_value
			if (
				not combined.is_empty()
				and combined.back().distance_to(route_point) <= 0.001
			):
				continue
			combined.append(route_point)
	return {
		"success": true,
		"reason": "",
		"points": combined,
		"length": total,
		"road_ids": road_ids,
	}

func route_editor_segment_preview(segment_index: int) -> Dictionary:
	var points := route_editor_points()
	var waypoints := route_editor_waypoints()
	if segment_index < 0 or segment_index >= points.size() - 1:
		return {"success": false, "points": [], "length": 0.0}
	var segment_waypoints: Array = (
		waypoints[segment_index]
		if segment_index < waypoints.size()
		else []
	)
	return preview_transit_route_via(
		points[segment_index],
		points[segment_index + 1],
		segment_waypoints
	)

func route_editor_add_point(point: Vector2, insert_after: int = -1) -> bool:
	if not route_editor_active():
		return false
	var mode := str(route_editor.get("transit_mode", "bus"))
	var snap := snap_transit_point_for_editor(point, true, 110.0)
	if snap.is_empty():
		_request_toast("Stops must be inside the map; surface modes also need a built road.")
		return false
	var snapped: Vector2 = snap["point"]
	var profile := TransitModes.profile(mode)
	var minimum_spacing := maxf(
		TransitNetwork.MIN_STOP_SPACING,
		float(profile.get("minimum_stop_spacing", TransitNetwork.MIN_STOP_SPACING))
	)
	var points := route_editor_points()
	if points.size() >= TransitNetwork.MAX_CUSTOM_STOPS:
		_request_toast("This line already has the maximum number of stops.")
		return false
	for existing in points:
		if existing.distance_to(snapped) < minimum_spacing:
			_request_toast("Stops are too close together.")
			return false
	var stop_ids := route_editor_stop_ids()
	if insert_after >= 0 and insert_after < points.size() - 1:
		points.insert(insert_after + 1, snapped)
		stop_ids.insert(insert_after + 1, "")
	else:
		points.append(snapped)
		stop_ids.append("")
	route_editor["draft_points"] = points
	route_editor["draft_stop_ids"] = stop_ids
	route_editor["selected_index"] = -1
	_clear_route_editor_waypoints_if_needed()
	_update_route_editor_cost()
	route_editor_changed.emit()
	state_changed.emit()
	return true

func route_editor_move_selected(point: Vector2) -> bool:
	if not route_editor_active():
		return false
	var selected_index := int(route_editor.get("selected_index", -1))
	var points := route_editor_points()
	if selected_index < 0 or selected_index >= points.size():
		return false
	var mode := str(route_editor.get("transit_mode", "bus"))
	var snap := snap_transit_point_for_editor(point, true, 110.0)
	if snap.is_empty():
		_request_toast("Stops must be inside the map; surface modes also need a built road.")
		return false
	var snapped: Vector2 = snap["point"]
	var profile := TransitModes.profile(mode)
	var minimum_spacing := maxf(
		TransitNetwork.MIN_STOP_SPACING,
		float(profile.get("minimum_stop_spacing", TransitNetwork.MIN_STOP_SPACING))
	)
	for index in range(points.size()):
		if index == selected_index:
			continue
		if points[index].distance_to(snapped) < minimum_spacing:
			_request_toast("Stops are too close together.")
			return false
	points[selected_index] = snapped
	route_editor["draft_points"] = points
	route_editor["selected_index"] = -1
	_update_route_editor_cost()
	route_editor_changed.emit()
	state_changed.emit()
	return true

func route_editor_remove_selected() -> bool:
	if not route_editor_active():
		return false
	var points := route_editor_points()
	var selected_index := int(route_editor.get("selected_index", -1))
	if selected_index < 0 or selected_index >= points.size():
		return false
	points.remove_at(selected_index)
	var stop_ids := route_editor_stop_ids()
	if selected_index < stop_ids.size():
		stop_ids.remove_at(selected_index)
	route_editor["draft_points"] = points
	route_editor["draft_stop_ids"] = stop_ids
	route_editor["selected_index"] = -1
	_clear_route_editor_waypoints_if_needed()
	_update_route_editor_cost()
	route_editor_changed.emit()
	state_changed.emit()
	return true

func route_editor_undo_last() -> bool:
	if not route_editor_active():
		return false
	var points := route_editor_points()
	if points.is_empty():
		return false
	points.pop_back()
	var stop_ids := route_editor_stop_ids()
	if not stop_ids.is_empty():
		stop_ids.pop_back()
	route_editor["draft_points"] = points
	route_editor["draft_stop_ids"] = stop_ids
	route_editor["selected_index"] = -1
	_clear_route_editor_waypoints_if_needed()
	_update_route_editor_cost()
	route_editor_changed.emit()
	state_changed.emit()
	return true

func free_line_build_cost(
	points: Array[Vector2],
	waypoints: Array = [],
	mode_override: String = ""
) -> int:
	var mode := mode_override if not mode_override.is_empty() else _route_editor_transit_mode()
	var route_length := _draft_route_length(points, waypoints, mode)
	if is_sandbox():
		var cost := roundi(
			float(Data.ECONOMY["sandbox_line_base_cost"])
			+ float(points.size()) * float(Data.ECONOMY["sandbox_stop_cost"])
			+ route_length * float(Data.ECONOMY["sandbox_route_cost_per_world_unit"])
			+ float(vehicle_purchase_cost())
		)
		cost = roundi(float(cost) * float(TransitModes.profile(mode).get("construction_cost_multiplier", 1.0)))
		var unlocked_modes: Dictionary = transit_network.get("unlocked_modes", {"bus": true})
		if mode != "bus" and not bool(unlocked_modes.get(mode, false)):
			cost += roundi(float(TransitModes.profile(mode).get("unlock_cost", 0.0)))
		return cost
	return roundi(
		float(Data.ECONOMY["free_line_base_cost"])
		+ float(points.size()) * float(Data.ECONOMY["free_stop_cost"])
		+ route_length * float(Data.ECONOMY["free_route_cost_per_world_unit"])
	)

func free_line_edit_cost(
	points: Array[Vector2],
	waypoints: Array = [],
	mode_override: String = ""
) -> int:
	var mode := mode_override if not mode_override.is_empty() else _route_editor_transit_mode()
	if is_sandbox():
		return roundi(
			float(Data.ECONOMY["free_line_edit_base_cost"])
			+ _draft_route_length(points, waypoints, mode)
			* float(Data.ECONOMY["sandbox_route_cost_per_world_unit"])
			* 0.12
			* float(TransitModes.profile(mode).get("construction_cost_multiplier", 1.0))
		)
	return roundi(
		float(Data.ECONOMY["free_line_edit_base_cost"])
		+ _draft_route_length(points, waypoints, mode)
		* float(Data.ECONOMY["free_route_cost_per_world_unit"])
		* 0.12
	)

func _draft_route_length(
	points: Array[Vector2],
	waypoints: Array = [],
	mode_override: String = ""
) -> float:
	var previous_mode := selected_transit_mode
	if not mode_override.is_empty():
		selected_transit_mode = mode_override
	var total := 0.0
	for index in range(points.size() - 1):
		var segment_waypoints: Array = (
			waypoints[index]
			if index < waypoints.size()
			else []
		)
		var route := preview_transit_route_via(
			points[index],
			points[index + 1],
			segment_waypoints
		)
		if not bool(route.get("success", false)):
			selected_transit_mode = previous_mode
			return 0.0
		total += float(route.get("length", 0.0))
	selected_transit_mode = previous_mode
	return total


func _transit_mode_route_payload(mode: String, points: Array[Vector2], waypoints: Array) -> Dictionary:
	var stations: Array[Dictionary] = []
	var station_spacings: Array[float] = []
	var road_ids: Array[String] = []
	for point in points:
		stations.append({"x": point.x, "y": point.y, "accessible": mode == "metro"})
	for index in range(points.size() - 1):
		station_spacings.append(points[index].distance_to(points[index + 1]))
		var segment_waypoints: Array = waypoints[index] if index < waypoints.size() else []
		var route := preview_transit_route_via(points[index], points[index + 1], segment_waypoints)
		if not bool(route.get("success", false)):
			return {"success": false, "reason": str(route.get("reason", "segment_unroutable"))}
		for road_id_value in route.get("road_ids", []):
			var road_id := str(road_id_value)
			if not road_ids.has(road_id):
				road_ids.append(road_id)
	return {
		"success": true,
		"road_corridor": mode != "metro",
		"tram_corridor": mode == "tram",
		"grade_separated": mode == "metro",
		"stations": stations,
		"station_spacings": station_spacings,
		"road_ids": road_ids,
		"built_road_ids": road_ids.duplicate(),
		"roads": city.get("roads", []),
		"route_segments": [],
	}


func _prepare_tram_track_profiles(road_id_values: Variant) -> Dictionary:
	if typeof(road_id_values) != TYPE_ARRAY or road_id_values.is_empty():
		return {}
	var target_ids: Dictionary = {}
	for road_id_value in road_id_values:
		var road_id := str(road_id_value)
		if not road_id.is_empty():
			target_ids[road_id] = true
	if target_ids.is_empty():
		return {}
	var prepared: Dictionary = {}
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		var road_id := str(road.get("id", ""))
		if not target_ids.has(road_id):
			continue
		if str(road.get("status", "")) != "built":
			return {}
		var raw_profile: Variant = road.get("profile", RoadProfile.base_profile(str(road.get("class", "local"))))
		if typeof(raw_profile) != TYPE_DICTIONARY:
			return {}
		var profile: Dictionary = raw_profile.duplicate(true)
		var lanes_value: Variant = profile.get("lanes", [])
		if typeof(lanes_value) != TYPE_ARRAY:
			return {}
		var lanes: Array = lanes_value.duplicate(true)
		if not bool(profile.get("tram_reservation", false)):
			lanes.append({"type": "tram", "direction": "forward", "width_m": 1.5, "side": "center"})
			lanes.append({"type": "tram", "direction": "backward", "width_m": 1.5, "side": "center"})
		profile["lanes"] = lanes
		profile["tram_reservation"] = true
		var validation := RoadProfile.validate(profile)
		if not bool(validation.get("valid", false)):
			return {}
		prepared[road_id] = profile
	if prepared.size() != target_ids.size():
		return {}
	return prepared


func _apply_tram_tracks(line_id: String) -> bool:
	var line := transit_line(line_id)
	var road_ids: Dictionary = {}
	for segment_value in line.get("route_segments", []):
		if not (segment_value is Dictionary):
			continue
		for road_id_value in segment_value.get("road_ids", []):
			road_ids[str(road_id_value)] = true
	if road_ids.is_empty():
		return false
	var prepared := _prepare_tram_track_profiles(road_ids.keys())
	if prepared.size() != road_ids.size():
		return false
	for road_value in city.get("roads", []):
		if not (road_value is Dictionary):
			continue
		var road: Dictionary = road_value
		var road_id := str(road.get("id", ""))
		if not prepared.has(road_id):
			continue
		road["profile"] = prepared[road_id].duplicate(true)
		road["tram_reservation"] = true
	return true

func _update_route_editor_cost() -> void:
	var points := route_editor_points()
	var waypoints := route_editor_waypoints()
	route_editor["estimated_cost"] = (
		free_line_build_cost(points, waypoints, str(route_editor.get("transit_mode", "bus")))
		if str(route_editor.get("mode", "")) == "new"
		else free_line_edit_cost(points, waypoints, str(route_editor.get("transit_mode", "bus")))
	)

func commit_route_editor() -> bool:
	if not route_editor_active():
		return false
	var points := route_editor_points()
	if points.size() < 2:
		_request_toast("A line needs at least two stops.")
		return false

	var mode := str(route_editor.get("mode", ""))
	var waypoints := route_editor_waypoints()
	var transit_mode := str(route_editor.get("transit_mode", "bus"))
	if mode == "edit":
		transit_mode = str(transit_line(str(route_editor.get("line_id", ""))).get("mode", "bus"))
	var mode_status := transit_mode_status(transit_mode)
	if not bool(mode_status.get("unlocked", false)):
		_request_toast(_transit_mode_locked_message(transit_mode, mode_status))
		return false
	var cost := (
		free_line_build_cost(points, waypoints, transit_mode)
		if mode == "new"
		else free_line_edit_cost(points, waypoints, transit_mode)
	)
	if money < float(cost):
		_request_toast("Not enough money.")
		return false
	var route_validation := TransitModes.validate_route(
		transit_mode,
		_transit_mode_route_payload(transit_mode, points, waypoints)
	)
	if not bool(route_validation.get("valid", false)):
		var reason := str(route_validation.get("reason", "invalid_route"))
		_request_toast("This %s route cannot be built: %s." % [transit_mode, reason.replace("_", " ")])
		return false
	if transit_mode == "tram":
		var route_payload := _transit_mode_route_payload(transit_mode, points, waypoints)
		if _prepare_tram_track_profiles(route_payload.get("road_ids", [])).is_empty():
			_request_toast("The tram route needs valid road profiles across every segment.")
			return false

	if mode == "new":
		if not can_begin_free_line():
			_request_toast("No free garage slot for the starter bus.")
			return false
		var serial := int(transit_network.get("next_line_serial", 1))
		var palette_index := (serial - 1) % Data.FREE_LINE_COLORS.size()
		var color: Color = Data.FREE_LINE_COLORS[palette_index]
		var network_before_build: Dictionary = transit_network.duplicate(true)
		var created := TransitNetwork.create_custom_line(
			transit_network,
			city,
			points,
			color,
			"",
			waypoints,
			transit_mode
		)
		if not bool(created.get("success", false)):
			_request_toast(_route_editor_failure_message(str(created.get("reason", ""))))
			return false
		var line_id := str(created.get("line_id", ""))
		if transit_mode != "bus":
			var unlocked_modes: Dictionary = transit_network.get("unlocked_modes", {"bus": true})
			unlocked_modes[transit_mode] = true
			transit_network["unlocked_modes"] = unlocked_modes
		if transit_mode == "tram" and not _apply_tram_tracks(line_id):
			transit_network = network_before_build
			_request_toast("The tram corridor could not reserve tracks on every road segment.")
			return false
		_ensure_custom_line_runtime(line_id)
		money -= float(cost)
		_request_toast("New %s line opened." % transit_mode)
		route_editor = _empty_route_editor()
		_commit_change()
		set_selection("free_line:%s" % line_id)
		route_editor_changed.emit()
		return true

	var line_id := str(route_editor.get("line_id", ""))
	var network_before_edit: Dictionary = transit_network.duplicate(true)
	var updated := TransitNetwork.update_custom_line_points(
		transit_network,
		city,
		line_id,
		points,
		waypoints,
		route_editor_stop_ids()
	)
	if not bool(updated.get("success", false)):
		_request_toast(_route_editor_failure_message(str(updated.get("reason", ""))))
		return false
	if transit_mode == "tram" and not _apply_tram_tracks(line_id):
		transit_network = network_before_edit
		_request_toast("The tram corridor could not reserve tracks on every road segment.")
		return false
	_ensure_custom_line_runtime(line_id)
	money -= float(cost)
	_request_toast("Line updated.")
	route_editor = _empty_route_editor()
	_commit_change()
	set_selection("free_line:%s" % line_id)
	route_editor_changed.emit()
	return true

func _route_editor_failure_message(reason: String) -> String:
	match reason:
		"stops_too_close":
			return "Stops are too close together."
		"segment_unroutable":
			return "The road network cannot connect those stops."
		"stop_not_on_built_road":
			return "A stop is not on a built road."
		"too_many_stops":
			return "Too many stops on one line."
		_:
			return "This line cannot be built here."

func _sync_transit_network_bridge() -> void:
	if is_sandbox():
		if transit_network.is_empty():
			transit_network = _empty_transit_network()
		else:
			transit_network["schema_version"] = TransitNetwork.SCHEMA_VERSION
			transit_network["source"] = TransitNetwork.SOURCE_FREE_LINES
			if not transit_network.has("stops"):
				transit_network["stops"] = {}
			if not transit_network.has("lines"):
				transit_network["lines"] = {}
			if not transit_network.has("next_stop_serial"):
				transit_network["next_stop_serial"] = 1
			if not transit_network.has("next_line_serial"):
				transit_network["next_line_serial"] = 1
		return
	transit_network = TransitNetwork.ensure_legacy_bridge(
		transit_network,
		city,
		lines,
		stations
	)

func station_level(station_id: String) -> int:
	var station: Dictionary = stations.get(station_id, {"level": 0})
	return int(station.get("level", 0))

func station_tier(station_id: String) -> String:
	return str(Data.STATION_UPGRADE["tier_names"][station_level(station_id)])

func station_upgrade_cost(station_id: String) -> int:
	var level := station_level(station_id)
	return roundi(
		float(Data.STATION_UPGRADE["base_cost"])
		* pow(float(Data.STATION_UPGRADE["cost_growth"]), level)
	)

func station_capacity(station_id: String) -> int:
	return int(Data.STATION_UPGRADE["waiting_capacity"][station_level(station_id)])

func station_is_built(station_id: String) -> bool:
	if station_id == "old-town":
		return true

	for line_key in Data.LINE_KEYS:
		var index: int = Data.STATION_IDS[line_key].find(station_id)
		if index < 0:
			continue

		var line: Dictionary = lines[line_key]
		if line_key == "line1":
			if index < int(line["stop_count"]):
				return true
		elif bool(line["built"]) and index < int(line["stop_count"]):
			return true

	return false

func station_served_lines(station_id: String) -> Array[String]:
	var result: Array[String] = []
	for line_key in Data.LINE_KEYS:
		var line: Dictionary = lines[line_key]
		if not bool(line["built"]):
			continue
		var index: int = Data.STATION_IDS[line_key].find(station_id)
		if index >= 0 and index < int(line["stop_count"]):
			result.append(line_key)
	return result

func station_waiting_passengers(station_id: String) -> float:
	var total := 0.0
	for line_key in Data.LINE_KEYS:
		var line: Dictionary = lines[line_key]
		if not bool(line["built"]):
			continue
		var stop_index: int = Data.STATION_IDS[line_key].find(station_id)
		if stop_index >= 0 and stop_index < int(line["stop_count"]):
			total += stop_waiting_passengers(line_key, stop_index)
	return total

func stop_demand(line_key: String, stop_index: int) -> float:
	var line: Dictionary = lines[line_key]
	var station_id: String = Data.STATION_IDS[line_key][stop_index]
	return (
		float(line["demand_per_stop_ppm"])
		+ float(Data.STATION_UPGRADE["demand_bonus"][station_level(station_id)])
	)

func line_demand(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	if not bool(line["built"]) or int(line["stop_count"]) < 2:
		return 0.0
	var total := 0.0
	for stop_index in range(int(line["stop_count"])):
		total += stop_demand(line_key, stop_index)
	return total

func line_route_length_km(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	var segment_count: int = maxi(0, int(line["stop_count"]) - 1)
	var lengths: Array = Data.LINE_CONFIG[line_key]["segment_lengths_km"]
	var total := 0.0
	for index in range(segment_count):
		total += float(lengths[index])
	return total

func _base_stop_dwell_minutes(line_key: String, stop_index: int) -> float:
	var station_id: String = Data.STATION_IDS[line_key][stop_index]
	var reduction := float(Data.STATION_UPGRADE["dwell_reduction"][station_level(station_id)])
	return max(0.12, float(Data.BUS["dwell_minutes"]) - reduction)

func _stop_dwell_minutes(line_key: String, stop_index: int) -> float:
	var line: Dictionary = lines[line_key]
	var is_endpoint := stop_index == 0 or stop_index == int(line["stop_count"]) - 1
	return (
		_base_stop_dwell_minutes(line_key, stop_index)
		+ (float(Data.BUS["turnaround_minutes"]) / 2.0 if is_endpoint else 0.0)
	)

func _segment_travel_minutes(line_key: String, from_stop: int, to_stop: int) -> float:
	var segment_index := mini(from_stop, to_stop)
	var lengths: Array = Data.LINE_CONFIG[line_key]["segment_lengths_km"]
	var length_km := float(lengths[segment_index])
	return length_km / float(Data.BUS["speed_kph"]) * 60.0

func line_cycle_minutes(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	if not bool(line["built"]) or int(line["stop_count"]) < 2:
		return 0.0

	var driving := line_route_length_km(line_key) / float(Data.BUS["speed_kph"]) * 60.0 * 2.0
	var dwell := 0.0

	for stop_index in range(int(line["stop_count"])):
		var visits := 1 if stop_index == 0 or stop_index == int(line["stop_count"]) - 1 else 2
		dwell += _base_stop_dwell_minutes(line_key, stop_index) * float(visits)

	return driving + dwell + float(Data.BUS["turnaround_minutes"])

func line_headway_minutes(line_key: String) -> float:
	var fleet := int(lines[line_key]["fleet_count"])
	if fleet <= 0:
		return INF
	return line_cycle_minutes(line_key) / float(fleet)

func line_capacity_ppm(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	var fleet := int(line["fleet_count"])
	if not bool(line["built"]) or fleet <= 0:
		return 0.0
	var cycle := line_cycle_minutes(line_key)
	if cycle <= 0.0:
		return 0.0
	return float(Data.BUS["capacity"]) * float(fleet) * 2.0 / cycle

func line_is_stable(line_key: String) -> bool:
	return bool(lines[line_key]["built"]) and line_capacity_ppm(line_key) >= line_demand(line_key)

func stop_waiting_passengers(line_key: String, stop_index: int) -> float:
	var line: Dictionary = lines[line_key]
	var matrix: Array = line["waiting_by_stop"]
	if stop_index < 0 or stop_index >= matrix.size():
		return 0.0

	var row: Array = matrix[stop_index]
	var total := 0.0
	for destination in range(mini(row.size(), int(line["stop_count"]))):
		total += max(0.0, float(row[destination]))
	return total

func line_waiting_passengers(line_key: String) -> float:
	var line: Dictionary = lines[line_key]
	var total := 0.0
	for stop_index in range(int(line["stop_count"])):
		total += stop_waiting_passengers(line_key, stop_index)
	return total

func line_onboard_passengers(line_key: String) -> float:
	var total := 0.0
	var line: Dictionary = lines[line_key]
	for vehicle in line["vehicles"]:
		total += float(vehicle.get("onboard_passengers", 0.0))
	return total

func garage_used() -> int:
	var total := 0
	for line_key in Data.LINE_KEYS:
		total += int(lines[line_key]["fleet_count"])
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		var line := transit_line(line_id)
		total += int(line.get("fleet_count", 0))
	return total

func vehicle_purchase_cost() -> int:
	if is_sandbox():
		return roundi(
			float(Data.ECONOMY["sandbox_bus_cost"])
			* pow(float(Data.ECONOMY["bus_cost_growth"]), garage_used())
		)
	var built_lines := 0
	for line_key in Data.LINE_KEYS:
		if bool(lines[line_key]["built"]):
			built_lines += 1
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		var custom_line := transit_line(line_id)
		if str(custom_line.get("status", "")) == "active":
			built_lines += 1
	var purchased: int = maxi(0, garage_used() - built_lines)
	return roundi(
		float(Data.ECONOMY["bus_base_cost"])
		* pow(float(Data.ECONOMY["bus_cost_growth"]), purchased)
	)

func custom_line_stop_count(line_id: String) -> int:
	return TransitNetwork.line_stop_ids(transit_network, line_id).size()

func custom_line_route_length_km(line_id: String) -> float:
	var line := transit_line(line_id)
	return float(line.get("route_length_world", 0.0)) / float(Data.WORLD_UNITS_PER_KM)

func custom_line_demand(line_id: String) -> float:
	var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
	if stop_ids.size() < 2:
		return 0.0
	var total := 0.0
	for stop_id in stop_ids:
		var stats := _cached_custom_stop_catchment(stop_id)
		total += float(stats.get("demand_ppm", 0.0))
	return total

func custom_line_cycle_minutes(line_id: String) -> float:
	var line := transit_line(line_id)
	var mode_profile := TransitModes.profile(str(line.get("mode", "bus")))
	var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
	if stop_ids.size() < 2:
		return 0.0
	var speed_kph := maxf(1.0, float(mode_profile.get("speed_kph", Data.BUS["speed_kph"])))
	var driving := custom_line_route_length_km(line_id) / speed_kph * 60.0 * 2.0
	var dwell := 0.0
	for stop_index in range(stop_ids.size()):
		var visits := 1 if stop_index == 0 or stop_index == stop_ids.size() - 1 else 2
		dwell += _custom_stop_dwell_minutes(line_id, stop_index, false) * float(visits)
	return driving + dwell + float(Data.BUS["turnaround_minutes"])

func custom_line_headway_minutes(line_id: String) -> float:
	var line := transit_line(line_id)
	var fleet := int(line.get("fleet_count", 0))
	if fleet <= 0:
		return INF
	return custom_line_cycle_minutes(line_id) / float(fleet)

func custom_line_waiting_passengers(line_id: String) -> float:
	var line := transit_line(line_id)
	var matrix: Array = line.get("waiting_by_stop", [])
	var stop_count := TransitNetwork.line_stop_ids(transit_network, line_id).size()
	var total := 0.0
	for origin in range(mini(matrix.size(), stop_count)):
		var row: Array = matrix[origin]
		for destination in range(mini(row.size(), stop_count)):
			total += maxf(0.0, float(row[destination]))
	return total

func custom_stop_waiting_passengers(stop_id: String) -> float:
	var total := 0.0
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
		var index := stop_ids.find(stop_id)
		if index < 0:
			continue
		var line := transit_line(line_id)
		var matrix: Array = line.get("waiting_by_stop", [])
		if index >= matrix.size():
			continue
		var row: Array = matrix[index]
		for value in row:
			total += maxf(0.0, float(value))
	return total

func transit_journey(from_stop_id: String, to_stop_id: String) -> Dictionary:
	return TransitPlanner.find_journey(transit_network, from_stop_id, to_stop_id)

func custom_stop_catchment(stop_id: String) -> Dictionary:
	return _cached_custom_stop_catchment(stop_id).duplicate(true)

func _cached_custom_stop_catchment(stop_id: String) -> Dictionary:
	var now := float(city.get("time_seconds", 0.0))
	var cached: Dictionary = _custom_catchment_cache.get(stop_id, {})
	if (
		not cached.is_empty()
		and now - float(cached.get("time_seconds", -INF)) <= 2.0
	):
		return cached.get("stats", {})

	var stats := TransitNetwork.catchment_stats(
		transit_network,
		city,
		stop_id
	)
	_custom_catchment_cache[stop_id] = {
		"time_seconds": now,
		"stats": stats,
	}
	return stats

func _invalidate_custom_catchment_cache() -> void:
	_custom_catchment_cache.clear()

func custom_stop_upgrade_cost(stop_id: String) -> int:
	var stop := transit_stop(stop_id)
	var level := clampi(int(stop.get("level", 0)), 0, int(Data.STATION_UPGRADE["max_level"]))
	return roundi(
		float(Data.STATION_UPGRADE["base_cost"])
		* pow(float(Data.STATION_UPGRADE["cost_growth"]), level)
	)

func upgrade_custom_stop(stop_id: String) -> bool:
	var stops: Dictionary = transit_network.get("stops", {})
	if not stops.has(stop_id):
		return false
	var stop: Dictionary = stops[stop_id]
	if str(stop.get("source", "")) != "custom":
		return false
	var level := int(stop.get("level", 0))
	if level >= int(Data.STATION_UPGRADE["max_level"]):
		_request_toast("This stop is already a Hub.")
		return false
	var cost := custom_stop_upgrade_cost(stop_id)
	if money < float(cost):
		_request_toast("Not enough money.")
		return false
	money -= float(cost)
	stop["level"] = level + 1
	stops[stop_id] = stop
	transit_network["stops"] = stops
	_request_toast("%s upgraded." % str(stop.get("name", "Stop")))
	_commit_change()
	return true

func next_stop_cost(line_key: String) -> int:
	var line: Dictionary = lines[line_key]
	var base_cost: float = 0.0
	var growth: float = 1.0
	var included_stops: int = 1

	match line_key:
		"line1":
			base_cost = float(Data.ECONOMY["line1_stop_base_cost"])
			growth = float(Data.ECONOMY["line1_stop_cost_growth"])
			included_stops = 1
		"line2":
			base_cost = float(Data.ECONOMY["line2_stop_base_cost"])
			growth = float(Data.ECONOMY["line2_stop_cost_growth"])
			included_stops = 2
		"line3":
			base_cost = float(Data.ECONOMY["line3_stop_base_cost"])
			growth = float(Data.ECONOMY["line3_stop_cost_growth"])
			included_stops = 2
		"line4":
			base_cost = float(Data.ECONOMY["line4_stop_base_cost"])
			growth = float(Data.ECONOMY["line4_stop_cost_growth"])
			included_stops = 2
		_:
			return 0

	var purchased: int = maxi(
		0,
		int(line["stop_count"]) - included_stops
	)
	return roundi(base_cost * pow(growth, purchased))

func can_build_depot() -> bool:
	if is_sandbox():
		return not bool(depot.get("built", false)) and _has_completed_road()
	return (
		not bool(depot["built"])
		and bool(lines["line1"].get("built", false))
		and int(lines["line1"]["stop_count"]) >= 2
	)

func _has_free_garage_slot() -> bool:
	return garage_used() < int(depot["garage_slots"])

func can_unlock_line(line_key: String) -> bool:
	if is_sandbox():
		return false
	if line_key == "line1":
		return true
	var previous_index := Data.LINE_KEYS.find(line_key) - 1
	if previous_index < 0:
		return false
	var previous_key: String = Data.LINE_KEYS[previous_index]
	var previous_line: Dictionary = lines[previous_key]
	return (
		not bool(lines[line_key]["built"])
		and bool(depot["built"])
		and int(previous_line["stop_count"]) >= int(Data.LINE_CONFIG[previous_key]["max_stops"])
		and line_is_stable(previous_key)
		and _has_free_garage_slot()
	)

func line_build_cost(line_key: String) -> int:
	match line_key:
		"line2":
			return int(Data.ECONOMY["line2_build_cost"])
		"line3":
			return int(Data.ECONOMY["line3_build_cost"])
		"line4":
			return int(Data.ECONOMY["line4_build_cost"])
		_:
			return 0

func _create_vehicle(line_key: String) -> Dictionary:
	var line: Dictionary = lines[line_key]
	var max_stops := int(Data.LINE_CONFIG[line_key]["max_stops"])
	var vehicle_id := int(line["next_vehicle_id"])
	line["next_vehicle_id"] = vehicle_id + 1

	var onboard: Array = []
	onboard.resize(max_stops)
	onboard.fill(0.0)

	var dwell := _stop_dwell_minutes(line_key, 0)
	return {
		"id": vehicle_id,
		"current_stop_index": 0,
		"next_stop_index": mini(1, int(line["stop_count"]) - 1),
		"direction": 1,
		"phase": "dwell",
		"phase_minutes_remaining": dwell,
		"phase_duration_minutes": dwell,
		"onboard_by_destination": onboard,
		"onboard_passengers": 0.0,
	}

func _initialize_line_service(line_key: String, fleet_count: int = 1) -> void:
	var line: Dictionary = lines[line_key]
	line["built"] = true
	line["vehicles"] = []
	line["fleet_count"] = 0
	line["next_vehicle_id"] = 1
	lines[line_key] = line

	for _index in range(fleet_count):
		_add_vehicle_to_line_state(line_key)

func _add_vehicle_to_line_state(line_key: String) -> Dictionary:
	var line: Dictionary = lines[line_key]
	var vehicle := _create_vehicle(line_key)
	var vehicles: Array = line["vehicles"]
	vehicles.append(vehicle)
	line["vehicles"] = vehicles
	line["fleet_count"] = vehicles.size()
	lines[line_key] = line
	return vehicle

func _ensure_line_runtime(line_key: String) -> void:
	var line: Dictionary = lines[line_key]
	var max_stops := int(Data.LINE_CONFIG[line_key]["max_stops"])

	if not line.has("waiting_by_stop"):
		line["waiting_by_stop"] = _create_waiting_matrix(max_stops)

	var matrix: Array = line["waiting_by_stop"]
	while matrix.size() < max_stops:
		var row: Array = []
		row.resize(max_stops)
		row.fill(0.0)
		matrix.append(row)

	for row_index in range(max_stops):
		var source_row: Array = matrix[row_index] if row_index < matrix.size() else []
		var next_row: Array = []
		next_row.resize(max_stops)
		next_row.fill(0.0)
		for column in range(mini(max_stops, source_row.size())):
			next_row[column] = max(0.0, float(source_row[column]))
		matrix[row_index] = next_row

	line["waiting_by_stop"] = matrix
	if not line.has("vehicles"):
		line["vehicles"] = []
	if not line.has("next_vehicle_id"):
		line["next_vehicle_id"] = 1
	if not line.has("event_serial"):
		line["event_serial"] = 0
	if not line.has("passenger_events"):
		line["passenger_events"] = []
	if not line.has("last_passenger_event"):
		line["last_passenger_event"] = null
	if not line.has("current_abandonment_ppm"):
		line["current_abandonment_ppm"] = 0.0
	if not line.has("crowding_ratio"):
		line["crowding_ratio"] = 0.0
	if not line.has("total_abandoned_passengers"):
		line["total_abandoned_passengers"] = 0.0
	if not line.has("last_delivered_ppm"):
		line["last_delivered_ppm"] = 0.0

	var vehicles: Array = line["vehicles"]
	if bool(line["built"]) and vehicles.is_empty():
		var target_fleet := maxi(1, int(line.get("fleet_count", 1)))
		line["fleet_count"] = 0
		lines[line_key] = line
		for _index in range(target_fleet):
			_add_vehicle_to_line_state(line_key)
		line = lines[line_key]
	else:
		line["fleet_count"] = vehicles.size()

	lines[line_key] = line
	line["queue_passengers"] = line_waiting_passengers(line_key)

func _ensure_custom_line_runtime(line_id: String) -> void:
	var network_lines: Dictionary = transit_network.get("lines", {})
	if not network_lines.has(line_id):
		return
	var line: Dictionary = network_lines[line_id]
	if str(line.get("source", "")) != "custom":
		return

	var stop_count := TransitNetwork.line_stop_ids(transit_network, line_id).size()
	var old_matrix: Array = line.get("waiting_by_stop", [])
	var matrix := _create_waiting_matrix(stop_count)
	var old_fare_weights: Array = line.get("waiting_fare_weights_by_stop", [])
	var fare_weights := _create_fare_weight_matrix(stop_count)
	var old_transfer_groups: Array = line.get("resident_transfer_groups_by_stop", [])
	var transfer_groups := _create_resident_transfer_matrix(stop_count)
	for row_index in range(mini(stop_count, old_matrix.size())):
		var source_row: Array = old_matrix[row_index]
		var target_row: Array = matrix[row_index]
		var source_fare_row: Array = old_fare_weights[row_index] if row_index < old_fare_weights.size() else []
		var target_fare_row: Array = fare_weights[row_index]
		var source_transfer_row: Array = old_transfer_groups[row_index] if row_index < old_transfer_groups.size() else []
		var target_transfer_row: Array = transfer_groups[row_index]
		for column in range(mini(stop_count, source_row.size())):
			var waiting := maxf(0.0, float(source_row[column]))
			target_row[column] = waiting
			var existing_weight := maxf(0.0, float(source_fare_row[column])) if column < source_fare_row.size() else waiting
			target_fare_row[column] = minf(waiting, existing_weight)
			var source_groups: Variant = source_transfer_row[column] if column < source_transfer_row.size() else []
			target_transfer_row[column] = _normalize_resident_transfer_groups(source_groups, waiting)
		matrix[row_index] = target_row
		fare_weights[row_index] = target_fare_row
		transfer_groups[row_index] = target_transfer_row
	line["waiting_by_stop"] = matrix
	line["waiting_fare_weights_by_stop"] = fare_weights
	line["resident_transfer_groups_by_stop"] = transfer_groups

	if not line.has("vehicles"):
		line["vehicles"] = []
	if not line.has("next_vehicle_id"):
		line["next_vehicle_id"] = 1
	if not line.has("event_serial"):
		line["event_serial"] = 0
	if not line.has("passenger_events"):
		line["passenger_events"] = []
	if not line.has("last_passenger_event"):
		line["last_passenger_event"] = null
	if not line.has("current_abandonment_ppm"):
		line["current_abandonment_ppm"] = 0.0
	if not line.has("crowding_ratio"):
		line["crowding_ratio"] = 0.0
	if not line.has("total_abandoned_passengers"):
		line["total_abandoned_passengers"] = 0.0
	if not line.has("last_delivered_ppm"):
		line["last_delivered_ppm"] = 0.0
	if not line.has("queue_passengers"):
		line["queue_passengers"] = 0.0

	var vehicles: Array = line["vehicles"]
	for vehicle_index in range(vehicles.size()):
		var vehicle: Dictionary = vehicles[vehicle_index]
		var old_onboard: Array = vehicle.get("onboard_by_destination", [])
		var old_onboard_fare_weights: Array = vehicle.get("onboard_fare_weights_by_destination", [])
		var old_onboard_transfer_groups: Array = vehicle.get("resident_transfer_groups_by_destination", [])
		var next_onboard: Array = []
		var next_onboard_fare_weights: Array = []
		var next_onboard_transfer_groups: Array = []
		next_onboard.resize(stop_count)
		next_onboard_fare_weights.resize(stop_count)
		next_onboard_transfer_groups.resize(stop_count)
		next_onboard.fill(0.0)
		next_onboard_fare_weights.fill(0.0)
		for destination in range(stop_count):
			next_onboard_transfer_groups[destination] = []
		for destination in range(mini(stop_count, old_onboard.size())):
			next_onboard[destination] = maxf(0.0, float(old_onboard[destination]))
			next_onboard_fare_weights[destination] = (
				maxf(0.0, float(old_onboard_fare_weights[destination]))
				if destination < old_onboard_fare_weights.size()
				else next_onboard[destination]
			)
			var old_groups: Variant = old_onboard_transfer_groups[destination] if destination < old_onboard_transfer_groups.size() else []
			next_onboard_transfer_groups[destination] = _normalize_resident_transfer_groups(
				old_groups,
				next_onboard[destination]
			)
		vehicle["onboard_by_destination"] = next_onboard
		vehicle["onboard_fare_weights_by_destination"] = next_onboard_fare_weights
		vehicle["resident_transfer_groups_by_destination"] = next_onboard_transfer_groups
		var current := clampi(
			int(vehicle.get("current_stop_index", 0)),
			0,
			maxi(0, stop_count - 1)
		)
		var next := clampi(
			int(vehicle.get("next_stop_index", mini(1, stop_count - 1))),
			0,
			maxi(0, stop_count - 1)
		)
		vehicle["current_stop_index"] = current
		vehicle["next_stop_index"] = next
		var onboard_total := 0.0
		for value in next_onboard:
			onboard_total += maxf(0.0, float(value))
		vehicle["onboard_passengers"] = onboard_total
		vehicles[vehicle_index] = vehicle

	var target_fleet := maxi(0, int(line.get("fleet_count", 0)))
	if stop_count >= 2 and target_fleet <= 0:
		target_fleet = 1
	line["vehicles"] = vehicles
	line["fleet_count"] = vehicles.size()
	network_lines[line_id] = line
	transit_network["lines"] = network_lines

	while vehicles.size() < target_fleet:
		_add_custom_vehicle_to_line(line_id)
		network_lines = transit_network.get("lines", {})
		line = network_lines[line_id]
		vehicles = line.get("vehicles", [])
	while vehicles.size() > target_fleet and not vehicles.is_empty():
		vehicles.pop_back()
	line["vehicles"] = vehicles
	line["fleet_count"] = vehicles.size()
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	_update_custom_queue(line_id)

func _create_custom_vehicle(line_id: String) -> Dictionary:
	var network_lines: Dictionary = transit_network.get("lines", {})
	var line: Dictionary = network_lines[line_id]
	var stop_count := TransitNetwork.line_stop_ids(transit_network, line_id).size()
	var vehicle_id := int(line.get("next_vehicle_id", 1))
	line["next_vehicle_id"] = vehicle_id + 1
	network_lines[line_id] = line
	transit_network["lines"] = network_lines

	var onboard: Array = []
	onboard.resize(stop_count)
	onboard.fill(0.0)
	var onboard_fare_weights: Array = []
	onboard_fare_weights.resize(stop_count)
	onboard_fare_weights.fill(0.0)
	var onboard_transfer_groups: Array = []
	for _destination_index in range(stop_count):
		onboard_transfer_groups.append([])
	var dwell := _custom_stop_dwell_minutes(line_id, 0, true)
	return {
		"id": vehicle_id,
		"current_stop_index": 0,
		"next_stop_index": mini(1, stop_count - 1),
		"direction": 1,
		"phase": "dwell",
		"phase_minutes_remaining": dwell,
		"phase_duration_minutes": dwell,
		"onboard_by_destination": onboard,
		"onboard_fare_weights_by_destination": onboard_fare_weights,
		"resident_transfer_groups_by_destination": onboard_transfer_groups,
		"onboard_passengers": 0.0,
	}

func _add_custom_vehicle_to_line(line_id: String) -> Dictionary:
	var network_lines: Dictionary = transit_network.get("lines", {})
	if not network_lines.has(line_id):
		return {}
	var line: Dictionary = network_lines[line_id]
	var vehicle := _create_custom_vehicle(line_id)
	network_lines = transit_network.get("lines", {})
	line = network_lines[line_id]
	var vehicles: Array = line.get("vehicles", [])
	vehicles.append(vehicle)
	line["vehicles"] = vehicles
	line["fleet_count"] = vehicles.size()
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	return vehicle

func add_bus_to_transit_line(line_id: String) -> bool:
	return add_vehicle_to_transit_line(line_id)


func transit_vehicle_name(line_id: String, plural: bool = false) -> String:
	var mode := str(transit_line(line_id).get("mode", "bus"))
	match mode:
		"tram":
			return "trams" if plural else "tram"
		"metro":
			return "trains" if plural else "train"
		_:
			return "buses" if plural else "bus"


func transit_vehicle_purchase_cost(line_id: String) -> int:
	var mode := str(transit_line(line_id).get("mode", "bus"))
	var multiplier := float(TransitModes.profile(mode).get("construction_cost_multiplier", 1.0))
	return roundi(float(vehicle_purchase_cost()) * multiplier)


func add_vehicle_to_transit_line(line_id: String) -> bool:
	var line := transit_line(line_id)
	if line.is_empty() or str(line.get("source", "")) != "custom":
		return false
	if not bool(depot.get("built", false)):
		return false
	if garage_used() >= int(depot.get("garage_slots", 0)):
		_request_toast("Garage is full.")
		return false
	if int(line.get("fleet_count", 0)) >= int(Data.ECONOMY["max_vehicles_per_line"]):
		return false
	var cost := transit_vehicle_purchase_cost(line_id)
	if money < float(cost):
		_request_toast("Not enough money.")
		return false

	money -= float(cost)
	_add_custom_vehicle_to_line(line_id)
	_request_toast("%s added to %s." % [transit_vehicle_name(line_id).capitalize(), str(line.get("name", "line"))])
	_commit_change()
	return true

func delete_custom_line(line_id: String) -> bool:
	var line := transit_line(line_id)
	if line.is_empty() or str(line.get("source", "")) != "custom":
		return false
	if not TransitNetwork.remove_custom_line(transit_network, line_id):
		return false
	_request_toast("Line removed.")
	_commit_change()
	set_selection("")
	return true

func _custom_stop_dwell_minutes(
	line_id: String,
	stop_index: int,
	include_turnaround: bool
) -> float:
	var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
	if stop_index < 0 or stop_index >= stop_ids.size():
		return float(Data.BUS["dwell_minutes"])
	var stop := transit_stop(stop_ids[stop_index])
	var level := clampi(int(stop.get("level", 0)), 0, int(Data.STATION_UPGRADE["max_level"]))
	var reduction := float(Data.STATION_UPGRADE["dwell_reduction"][level])
	var result := maxf(0.12, float(Data.BUS["dwell_minutes"]) - reduction)
	if include_turnaround and (stop_index == 0 or stop_index == stop_ids.size() - 1):
		result += float(Data.BUS["turnaround_minutes"]) / 2.0
	return result

func _custom_segment_travel_minutes(
	line_id: String,
	from_stop: int,
	to_stop: int
) -> float:
	var line := transit_line(line_id)
	var segments: Array = line.get("route_segments", [])
	var segment_index := mini(from_stop, to_stop)
	if segment_index < 0 or segment_index >= segments.size():
		return 0.1
	var segment: Dictionary = segments[segment_index]
	var length_km := float(segment.get("length_world", 0.0)) / float(Data.WORLD_UNITS_PER_KM)
	var speed_kph := maxf(1.0, float(TransitModes.profile(str(line.get("mode", "bus"))).get("speed_kph", Data.BUS["speed_kph"])))
	return maxf(0.05, length_km / speed_kph * 60.0)

func _custom_generate_passengers(line_id: String, delta_minutes: float) -> void:
	if is_sandbox():
		return
	var network_lines: Dictionary = transit_network.get("lines", {})
	var line: Dictionary = network_lines.get(line_id, {})
	var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
	var stop_count := stop_ids.size()
	if stop_count < 2:
		return

	var matrix: Array = line.get("waiting_by_stop", [])
	var fare_weight_matrix: Array = line.get("waiting_fare_weights_by_stop", _create_fare_weight_matrix(stop_count))
	var abandoned := 0.0
	for origin in range(stop_count):
		var stats := _cached_custom_stop_catchment(stop_ids[origin])
		var stop := transit_stop(stop_ids[origin])
		var interchange_bonus := 1.0 + maxf(
			0.0,
			float(stop.get("served_line_ids", []).size() - 1) * 0.10
		)
		var demand := float(stats.get("demand_ppm", 0.0)) * interchange_bonus
		var per_destination := demand / float(maxi(1, stop_count - 1))
		var row: Array = matrix[origin]
		var fare_weight_row: Array = fare_weight_matrix[origin]
		for destination in range(stop_count):
			if destination == origin:
				continue
			row[destination] = float(row[destination]) + per_destination * delta_minutes
			fare_weight_row[destination] = float(fare_weight_row[destination]) + per_destination * delta_minutes

		var level := clampi(int(stop.get("level", 0)), 0, int(Data.STATION_UPGRADE["max_level"]))
		var capacity := float(Data.STATION_UPGRADE["waiting_capacity"][level])
		var waiting := 0.0
		for value in row:
			waiting += maxf(0.0, float(value))
		if waiting > capacity:
			var keep_ratio := capacity / waiting
			abandoned += waiting - capacity
			for destination in range(row.size()):
				row[destination] = float(row[destination]) * keep_ratio
				fare_weight_row[destination] = float(fare_weight_row[destination]) * keep_ratio
		matrix[origin] = row
		fare_weight_matrix[origin] = fare_weight_row

	line["waiting_by_stop"] = matrix
	line["waiting_fare_weights_by_stop"] = fare_weight_matrix
	line["current_abandonment_ppm"] = (
		abandoned / delta_minutes if delta_minutes > 0.0 else 0.0
	)
	line["total_abandoned_passengers"] = float(
		line.get("total_abandoned_passengers", 0.0)
	) + abandoned
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	_update_custom_queue(line_id)

func _custom_emit_passenger_event(
	line_id: String,
	event_type: String,
	stop_index: int,
	vehicle_id: int,
	count: float,
	fare: float = 0.0
) -> void:
	if count <= 0.0:
		return
	var network_lines: Dictionary = transit_network.get("lines", {})
	var line: Dictionary = network_lines[line_id]
	line["event_serial"] = int(line.get("event_serial", 0)) + 1
	var event := {
		"serial": int(line["event_serial"]),
		"type": event_type,
		"stop_index": stop_index,
		"vehicle_id": vehicle_id,
		"count": count,
		"fare": fare,
	}
	line["last_passenger_event"] = event
	var events: Array = line.get("passenger_events", [])
	events.append(event)
	while events.size() > 24:
		events.pop_front()
	line["passenger_events"] = events
	network_lines[line_id] = line
	transit_network["lines"] = network_lines

func _custom_unload_at_stop(
	line_id: String,
	vehicle: Dictionary,
	stop_index: int,
	delta_minutes: float = 0.0
) -> float:
	var onboard: Array = vehicle.get("onboard_by_destination", [])
	var onboard_fare_weights: Array = vehicle.get("onboard_fare_weights_by_destination", [])
	var onboard_transfer_groups: Array = vehicle.get("resident_transfer_groups_by_destination", [])
	if stop_index < 0 or stop_index >= onboard.size():
		return 0.0
	var alighting := float(onboard[stop_index])
	if alighting <= 0.0:
		return 0.0
	var fare_weight := (
		maxf(0.0, float(onboard_fare_weights[stop_index]))
		if stop_index < onboard_fare_weights.size()
		else alighting
	)
	var transfer_groups := _normalize_resident_transfer_groups(
		onboard_transfer_groups[stop_index] if stop_index < onboard_transfer_groups.size() else [],
		alighting
	)
	onboard[stop_index] = 0.0
	if stop_index < onboard_fare_weights.size():
		onboard_fare_weights[stop_index] = 0.0
	if stop_index < onboard_transfer_groups.size():
		onboard_transfer_groups[stop_index] = []
	vehicle["onboard_by_destination"] = onboard
	vehicle["onboard_fare_weights_by_destination"] = onboard_fare_weights
	vehicle["resident_transfer_groups_by_destination"] = onboard_transfer_groups
	vehicle["onboard_passengers"] = maxf(
		0.0,
		float(vehicle.get("onboard_passengers", 0.0)) - alighting
	)

	var fare := fare_weight * float(Data.ECONOMY["fare_per_passenger"])
	money += fare
	stats["lifetime_revenue"] = float(stats["lifetime_revenue"]) + fare
	stats["operator_net_operating"] = float(stats.get("lifetime_revenue", 0.0)) - float(stats.get("lifetime_operating_costs", 0.0))
	stats["lifetime_passengers"] = float(stats["lifetime_passengers"]) + alighting
	stats["last_fare_event_value"] = fare
	stats["last_fare_event_serial"] = int(stats["last_fare_event_serial"]) + 1
	stats["last_fare_line"] = line_id
	stats["last_fare_stop_index"] = stop_index

	var network_lines: Dictionary = transit_network.get("lines", {})
	var line: Dictionary = network_lines[line_id]
	line["last_delivered_ppm"] = float(line.get("last_delivered_ppm", 0.0)) + (
		alighting / float(Data.DELIVERY_RATE_WINDOW_MINUTES)
	)
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	_custom_emit_passenger_event(
		line_id,
		"alight",
		stop_index,
		int(vehicle.get("id", 0)),
		alighting,
		fare
	)
	var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
	if is_sandbox():
		for group_value in transfer_groups:
			_enqueue_resident_transfer_group(group_value, delta_minutes)
	elif stop_index >= 0 and stop_index < stop_ids.size():
		_inject_transfer_passengers(stop_ids[stop_index], line_id, alighting)
	_fare_changed_this_frame = true
	return alighting


func _advance_pending_resident_transfers(delta_minutes: float) -> void:
	if delta_minutes <= 0.0:
		return
	var pending := _normalize_pending_resident_transfers(
		transit_network.get("pending_resident_transfers", [])
	)
	var still_walking: Array = []
	for pending_value in pending:
		var transfer: Dictionary = pending_value
		var remaining_walk_minutes := maxf(
			0.0,
			float(transfer.get("remaining_walk_minutes", 0.0))
		)
		if remaining_walk_minutes <= delta_minutes + 0.000001:
			_queue_resident_transfer_group(transfer, delta_minutes)
		else:
			transfer["remaining_walk_minutes"] = remaining_walk_minutes - delta_minutes
			still_walking.append(transfer)
	transit_network["pending_resident_transfers"] = still_walking


func _enqueue_resident_transfer_group(group_value: Variant, delta_minutes: float) -> void:
	if typeof(group_value) != TYPE_DICTIONARY:
		return
	var group: Dictionary = group_value
	var passengers := maxf(0.0, float(group.get("passengers", 0.0)))
	var fare_weighted_passengers := clampf(
		maxf(0.0, float(group.get("fare_weighted_passengers", passengers))),
		0.0,
		passengers
	)
	var remaining_ride_legs := _resident_ride_legs(group.get("remaining_ride_legs", []))
	if passengers <= 0.000001 or remaining_ride_legs.is_empty():
		return
	var next_leg: Dictionary = remaining_ride_legs[0]
	var walk_minutes := maxf(0.0, float(next_leg.get("transfer_walk_minutes_before", 0.0)))
	if not is_finite(walk_minutes):
		walk_minutes = 0.0
	var normalized_group := {
		"passengers": passengers,
		"fare_weighted_passengers": fare_weighted_passengers,
		"remaining_ride_legs": remaining_ride_legs,
	}
	if walk_minutes > 0.000001:
		var pending := _normalize_pending_resident_transfers(
			transit_network.get("pending_resident_transfers", [])
		)
		pending.append({
			"remaining_walk_minutes": walk_minutes,
			"passengers": passengers,
			"fare_weighted_passengers": fare_weighted_passengers,
			"remaining_ride_legs": remaining_ride_legs,
		})
		transit_network["pending_resident_transfers"] = pending
		return
	_queue_resident_transfer_group(normalized_group, delta_minutes)


func _queue_resident_transfer_group(group_value: Variant, delta_minutes: float) -> void:
	if typeof(group_value) != TYPE_DICTIONARY:
		return
	var group: Dictionary = group_value
	var passengers := maxf(0.0, float(group.get("passengers", 0.0)))
	var fare_weighted_passengers := clampf(
		maxf(0.0, float(group.get("fare_weighted_passengers", passengers))),
		0.0,
		passengers
	)
	var remaining_ride_legs := _resident_ride_legs(group.get("remaining_ride_legs", []))
	if passengers <= 0.000001 or remaining_ride_legs.is_empty():
		return
	var next_leg: Dictionary = remaining_ride_legs[0]
	var line_id := str(next_leg.get("line_id", ""))
	if not _resident_line_operational(line_id):
		return
	var network_lines: Dictionary = transit_network.get("lines", {})
	var line: Dictionary = network_lines.get(line_id, {})
	if str(line.get("source", "")) != "custom":
		return
	_ensure_custom_line_runtime(line_id)
	network_lines = transit_network.get("lines", {})
	line = network_lines.get(line_id, {})
	var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
	var origin_index := stop_ids.find(str(next_leg.get("from_stop_id", "")))
	var destination_index := stop_ids.find(str(next_leg.get("to_stop_id", "")))
	if origin_index < 0 or destination_index < 0 or origin_index == destination_index:
		return

	var matrix: Array = line.get("waiting_by_stop", _create_waiting_matrix(stop_ids.size()))
	var fare_weight_matrix: Array = line.get(
		"waiting_fare_weights_by_stop",
		_create_fare_weight_matrix(stop_ids.size())
	)
	var transfer_groups_matrix: Array = line.get(
		"resident_transfer_groups_by_stop",
		_create_resident_transfer_matrix(stop_ids.size())
	)
	if origin_index >= matrix.size() or origin_index >= fare_weight_matrix.size() or origin_index >= transfer_groups_matrix.size():
		return
	var row: Array = matrix[origin_index]
	var fare_weight_row: Array = fare_weight_matrix[origin_index]
	var transfer_groups_row: Array = transfer_groups_matrix[origin_index]
	if destination_index >= row.size() or destination_index >= fare_weight_row.size() or destination_index >= transfer_groups_row.size():
		return
	row[destination_index] = maxf(0.0, float(row[destination_index])) + passengers
	fare_weight_row[destination_index] = maxf(0.0, float(fare_weight_row[destination_index])) + fare_weighted_passengers
	var continued_ride_legs := remaining_ride_legs.slice(1)
	if not continued_ride_legs.is_empty():
		var destination_groups: Array = transfer_groups_row[destination_index]
		destination_groups.append({
			"passengers": passengers,
			"fare_weighted_passengers": fare_weighted_passengers,
			"remaining_ride_legs": continued_ride_legs,
		})
		transfer_groups_row[destination_index] = destination_groups

	var stop := transit_stop(stop_ids[origin_index])
	var level := clampi(
		int(stop.get("level", 0)),
		0,
		int(Data.STATION_UPGRADE["max_level"])
	)
	var capacity := float(Data.STATION_UPGRADE["waiting_capacity"][level])
	var waiting := 0.0
	for value in row:
		waiting += maxf(0.0, float(value))
	var abandoned := 0.0
	var maximum_queue_utilization := clampf(waiting / capacity, 0.0, 1.0) if capacity > 0.0 else 1.0
	if waiting > capacity:
		var keep_ratio := capacity / waiting
		abandoned = waiting - capacity
		for queue_destination in range(row.size()):
			var cell_waiting := maxf(0.0, float(row[queue_destination]))
			row[queue_destination] = cell_waiting * keep_ratio
			fare_weight_row[queue_destination] = maxf(0.0, float(fare_weight_row[queue_destination])) * keep_ratio
			var destination_groups := _normalize_resident_transfer_groups(
				transfer_groups_row[queue_destination],
				cell_waiting
			)
			for group_index in range(destination_groups.size()):
				var destination_group: Dictionary = destination_groups[group_index]
				destination_group["passengers"] = float(destination_group["passengers"]) * keep_ratio
				destination_group["fare_weighted_passengers"] = float(destination_group["fare_weighted_passengers"]) * keep_ratio
				destination_groups[group_index] = destination_group
			transfer_groups_row[queue_destination] = destination_groups
		maximum_queue_utilization = 1.0
		line["total_abandoned_passengers"] = float(line.get("total_abandoned_passengers", 0.0)) + abandoned
		line["current_abandonment_ppm"] = float(line.get("current_abandonment_ppm", 0.0)) + abandoned / maxf(delta_minutes, 0.000001)

	matrix[origin_index] = row
	fare_weight_row[destination_index] = maxf(0.0, float(fare_weight_row[destination_index]))
	fare_weight_matrix[origin_index] = fare_weight_row
	transfer_groups_matrix[origin_index] = transfer_groups_row
	line["waiting_by_stop"] = matrix
	line["waiting_fare_weights_by_stop"] = fare_weight_matrix
	line["resident_transfer_groups_by_stop"] = transfer_groups_matrix
	line["crowding_ratio"] = maxf(
		clampf(float(line.get("crowding_ratio", 0.0)), 0.0, 1.0),
		maximum_queue_utilization
	)
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	_update_custom_queue(line_id)

func _inject_transfer_passengers(
	stop_id: String,
	from_line_id: String,
	alighting: float
) -> void:
	if is_sandbox() or alighting <= 0.0:
		return

	var origin := TransitNetwork.stop_position(transit_network, stop_id)
	var candidates_by_line: Dictionary = {}
	var stops: Dictionary = transit_network.get("stops", {})
	for candidate_stop_id_value in stops.keys():
		var candidate_stop_id := str(candidate_stop_id_value)
		var candidate_stop: Dictionary = stops[candidate_stop_id]
		if str(candidate_stop.get("status", "")) != "built":
			continue
		var distance := origin.distance_to(
			TransitNetwork.stop_position(transit_network, candidate_stop_id)
		)
		if distance > TransitNetwork.TRANSFER_WALK_RADIUS:
			continue
		for line_id_value in candidate_stop.get("served_line_ids", []):
			var line_id := str(line_id_value)
			if line_id == from_line_id:
				continue
			if candidates_by_line.has(line_id):
				var existing: Dictionary = candidates_by_line[line_id]
				if distance >= float(existing.get("distance", INF)):
					continue
			candidates_by_line[line_id] = {
				"line_id": line_id,
				"stop_id": candidate_stop_id,
				"distance": distance,
			}

	if candidates_by_line.is_empty():
		return

	var transfer_total := alighting * 0.18
	var per_line := transfer_total / float(candidates_by_line.size())
	for candidate_value in candidates_by_line.values():
		var candidate: Dictionary = candidate_value
		var target_line_id := str(candidate.get("line_id", ""))
		var target_stop_id := str(candidate.get("stop_id", ""))
		if target_line_id in Data.LINE_KEYS:
			var target_line: Dictionary = lines[target_line_id]
			if not bool(target_line.get("built", false)):
				continue
			var stop_index: int = Data.STATION_IDS[target_line_id].find(target_stop_id)
			var stop_count := int(target_line.get("stop_count", 0))
			if stop_index < 0 or stop_index >= stop_count or stop_count < 2:
				continue
			var destination := stop_count - 1 if stop_index < stop_count - 1 else 0
			if destination == stop_index:
				continue
			var matrix: Array = target_line.get("waiting_by_stop", [])
			if stop_index >= matrix.size():
				continue
			var row: Array = matrix[stop_index]
			if destination >= row.size():
				continue
			row[destination] = float(row[destination]) + per_line
			matrix[stop_index] = row
			target_line["waiting_by_stop"] = matrix
			lines[target_line_id] = target_line
			continue

		var network_lines: Dictionary = transit_network.get("lines", {})
		if not network_lines.has(target_line_id):
			continue
		var target_line: Dictionary = network_lines[target_line_id]
		if str(target_line.get("source", "")) != "custom":
			continue
		var stop_ids := TransitNetwork.line_stop_ids(transit_network, target_line_id)
		var stop_index := stop_ids.find(target_stop_id)
		if stop_index < 0 or stop_ids.size() < 2:
			continue
		var destination := stop_ids.size() - 1 if stop_index < stop_ids.size() - 1 else 0
		if destination == stop_index:
			continue
		var matrix: Array = target_line.get("waiting_by_stop", [])
		if stop_index >= matrix.size():
			continue
		var row: Array = matrix[stop_index]
		if destination >= row.size():
			continue
		row[destination] = float(row[destination]) + per_line
		matrix[stop_index] = row
		target_line["waiting_by_stop"] = matrix
		network_lines[target_line_id] = target_line
		transit_network["lines"] = network_lines
		_update_custom_queue(target_line_id)

func _custom_board_at_stop(line_id: String, vehicle: Dictionary) -> float:
	var network_lines: Dictionary = transit_network.get("lines", {})
	var line: Dictionary = network_lines[line_id]
	var vehicle_capacity := float(TransitModes.profile(str(line.get("mode", "bus"))).get("vehicle_capacity", Data.BUS["capacity"]))
	var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
	var stop_count := stop_ids.size()
	var stop_index := int(vehicle.get("current_stop_index", 0))
	var available := vehicle_capacity - float(vehicle.get("onboard_passengers", 0.0))
	if available <= 0.0 or stop_index < 0 or stop_index >= stop_count:
		return 0.0

	var destinations: Array[int] = []
	if int(vehicle.get("direction", 1)) > 0:
		for destination in range(stop_index + 1, stop_count):
			destinations.append(destination)
	else:
		for destination in range(stop_index - 1, -1, -1):
			destinations.append(destination)

	var matrix: Array = line.get("waiting_by_stop", [])
	var row: Array = matrix[stop_index]
	var fare_weight_matrix: Array = line.get("waiting_fare_weights_by_stop", _create_fare_weight_matrix(stop_count))
	var fare_weight_row: Array = fare_weight_matrix[stop_index]
	var transfer_groups_matrix: Array = line.get("resident_transfer_groups_by_stop", _create_resident_transfer_matrix(stop_count))
	var transfer_groups_row: Array = transfer_groups_matrix[stop_index]
	var onboard: Array = vehicle.get("onboard_by_destination", [])
	var onboard_fare_weights: Array = vehicle.get("onboard_fare_weights_by_destination", [])
	var onboard_transfer_groups: Array = vehicle.get("resident_transfer_groups_by_destination", [])
	var boarded := 0.0
	for destination in destinations:
		if available <= 0.0:
			break
		var waiting := float(row[destination])
		if waiting <= 0.0:
			continue
		var take := minf(waiting, available)
		var waiting_fare_weight := (
			maxf(0.0, float(fare_weight_row[destination]))
			if destination < fare_weight_row.size()
			else waiting
		)
		var take_fare_weight := waiting_fare_weight * take / waiting
		var waiting_transfer_groups := _normalize_resident_transfer_groups(
			transfer_groups_row[destination] if destination < transfer_groups_row.size() else [],
			waiting
		)
		var group_board_ratio := take / waiting
		var remaining_transfer_groups: Array = []
		var boarded_transfer_groups: Array = (
			onboard_transfer_groups[destination]
			if destination < onboard_transfer_groups.size()
			else []
		)
		for group_value in waiting_transfer_groups:
			var group: Dictionary = group_value
			var group_passengers := float(group.get("passengers", 0.0))
			var group_fare_weight := float(group.get("fare_weighted_passengers", group_passengers))
			var group_boarded := group_passengers * group_board_ratio
			if group_boarded > 0.000001:
				var boarded_group := group.duplicate(true)
				boarded_group["passengers"] = group_boarded
				boarded_group["fare_weighted_passengers"] = group_fare_weight * group_board_ratio
				boarded_transfer_groups.append(boarded_group)
			var group_remaining := group_passengers - group_boarded
			if group_remaining > 0.000001:
				var remaining_group := group.duplicate(true)
				remaining_group["passengers"] = group_remaining
				remaining_group["fare_weighted_passengers"] = group_fare_weight * (1.0 - group_board_ratio)
				remaining_transfer_groups.append(remaining_group)
		row[destination] = waiting - take
		if destination < fare_weight_row.size():
			fare_weight_row[destination] = maxf(0.0, waiting_fare_weight - take_fare_weight)
		if destination < transfer_groups_row.size():
			transfer_groups_row[destination] = remaining_transfer_groups
		onboard[destination] = float(onboard[destination]) + take
		if destination < onboard_fare_weights.size():
			onboard_fare_weights[destination] = float(onboard_fare_weights[destination]) + take_fare_weight
		if destination < onboard_transfer_groups.size():
			onboard_transfer_groups[destination] = boarded_transfer_groups
		vehicle["onboard_passengers"] = float(vehicle.get("onboard_passengers", 0.0)) + take
		boarded += take
		available -= take

	matrix[stop_index] = row
	fare_weight_matrix[stop_index] = fare_weight_row
	transfer_groups_matrix[stop_index] = transfer_groups_row
	line["waiting_by_stop"] = matrix
	line["waiting_fare_weights_by_stop"] = fare_weight_matrix
	line["resident_transfer_groups_by_stop"] = transfer_groups_matrix
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	vehicle["onboard_by_destination"] = onboard
	vehicle["onboard_fare_weights_by_destination"] = onboard_fare_weights
	vehicle["resident_transfer_groups_by_destination"] = onboard_transfer_groups
	_update_custom_queue(line_id)
	_custom_emit_passenger_event(
		line_id,
		"board",
		stop_index,
		int(vehicle.get("id", 0)),
		boarded
	)
	return boarded

func _custom_start_travel(line_id: String, vehicle: Dictionary) -> void:
	var stop_count := TransitNetwork.line_stop_ids(transit_network, line_id).size()
	var current := int(vehicle.get("current_stop_index", 0))
	var direction := int(vehicle.get("direction", 1))
	if current == 0 and direction < 0:
		direction = 1
	if current == stop_count - 1 and direction > 0:
		direction = -1
	vehicle["direction"] = direction
	var next_stop := current + direction
	if next_stop < 0 or next_stop >= stop_count:
		return
	vehicle["next_stop_index"] = next_stop
	vehicle["phase"] = "travel"
	var travel := _custom_segment_travel_minutes(line_id, current, next_stop)
	vehicle["phase_duration_minutes"] = travel
	vehicle["phase_minutes_remaining"] = travel

func _custom_arrive(line_id: String, vehicle: Dictionary, delta_minutes: float) -> void:
	vehicle["current_stop_index"] = int(vehicle.get("next_stop_index", 0))
	var current := int(vehicle["current_stop_index"])
	_custom_unload_at_stop(line_id, vehicle, current, delta_minutes)
	var stop_count := TransitNetwork.line_stop_ids(transit_network, line_id).size()
	if current == 0:
		vehicle["direction"] = 1
	elif current == stop_count - 1:
		vehicle["direction"] = -1
	vehicle["phase"] = "dwell"
	var dwell := _custom_stop_dwell_minutes(line_id, current, true)
	vehicle["phase_duration_minutes"] = dwell
	vehicle["phase_minutes_remaining"] = dwell

func _custom_begin_boarding(line_id: String, vehicle: Dictionary) -> void:
	_custom_board_at_stop(line_id, vehicle)
	vehicle["phase"] = "boarding"
	vehicle["phase_duration_minutes"] = float(Data.BOARDING_HOLD_MINUTES)
	vehicle["phase_minutes_remaining"] = float(Data.BOARDING_HOLD_MINUTES)

func _advance_custom_vehicle(
	line_id: String,
	vehicle: Dictionary,
	delta_minutes: float
) -> void:
	var remaining := delta_minutes
	var guard := 0
	while remaining > 0.0 and guard < 8:
		guard += 1
		var phase_remaining := maxf(
			0.0,
			float(vehicle.get("phase_minutes_remaining", 0.0))
		)
		var step := minf(remaining, phase_remaining)
		vehicle["phase_minutes_remaining"] = phase_remaining - step
		remaining -= step
		if float(vehicle["phase_minutes_remaining"]) > 0.000000001:
			break
		match str(vehicle.get("phase", "")):
			"travel":
				_custom_arrive(line_id, vehicle, delta_minutes)
			"dwell":
				_custom_begin_boarding(line_id, vehicle)
			_:
				_custom_start_travel(line_id, vehicle)
		if float(vehicle.get("phase_minutes_remaining", 0.0)) <= 0.0 and remaining <= 0.0:
			break

func _simulate_custom_line(line_id: String, delta_minutes: float) -> void:
	_ensure_custom_line_runtime(line_id)
	var network_lines: Dictionary = transit_network.get("lines", {})
	if not network_lines.has(line_id):
		return
	var line: Dictionary = network_lines[line_id]
	if str(line.get("status", "")) != "active":
		return

	var decay := exp(-delta_minutes / float(Data.DELIVERY_RATE_WINDOW_MINUTES))
	line["last_delivered_ppm"] = float(line.get("last_delivered_ppm", 0.0)) * decay
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	_custom_generate_passengers(line_id, delta_minutes)

	network_lines = transit_network.get("lines", {})
	line = network_lines[line_id]
	var vehicles: Array = line.get("vehicles", [])
	for vehicle in vehicles:
		_advance_custom_vehicle(line_id, vehicle, delta_minutes)
	line["vehicles"] = vehicles
	line["fleet_count"] = vehicles.size()
	network_lines[line_id] = line
	transit_network["lines"] = network_lines
	_update_custom_queue(line_id)
	network_lines = transit_network.get("lines", {})
	line = network_lines.get(line_id, {})
	line["crowding_ratio"] = maxf(
		clampf(float(line.get("crowding_ratio", 0.0)), 0.0, 1.0),
		_custom_line_vehicle_occupancy_ratio(line)
	)
	network_lines[line_id] = line
	transit_network["lines"] = network_lines


func _generate_resident_transport_demand(delta_minutes: float) -> void:
	if not is_sandbox() or delta_minutes <= 0.0:
		return
	_advance_pending_resident_transfers(delta_minutes)
	var existing_lines: Dictionary = transit_network.get("lines", {})
	for line_id_value in TransitNetwork.custom_line_ids(transit_network):
		var line_id := str(line_id_value)
		if not existing_lines.has(line_id):
			continue
		var line: Dictionary = existing_lines[line_id]
		line["crowding_ratio"] = maxf(
			0.0,
			clampf(float(line.get("crowding_ratio", 0.0)), 0.0, 1.0)
				- delta_minutes / RESIDENT_CAPACITY_PRESSURE_RECOVERY_MINUTES
		)
		line["crowding_ratio"] = maxf(
			float(line["crowding_ratio"]),
			_custom_line_vehicle_occupancy_ratio(line)
		)
		existing_lines[line_id] = line
	transit_network["lines"] = existing_lines
	var snapshot := _resident_transport_snapshot()
	var choice: Dictionary = snapshot.get("choice", {})
	var routes_by_od: Dictionary = snapshot.get("routes_by_od", {})
	var daily_flows: Array = choice.get("flows", [])
	var demand_by_line: Dictionary = {}
	var prepared_lines: Dictionary = {}
	for flow_value in daily_flows:
		var flow: Dictionary = flow_value
		var trip_flows: Dictionary = flow.get("flows", {})
		var trips_per_day := maxf(0.0, float(trip_flows.get("transit", 0.0)))
		if trips_per_day <= 0.0:
			continue
		var od_id := str(flow.get("od_id", ""))
		var age_group := str(flow.get("age_group", "adults"))
		var fare_multiplier := float(_resident_age_profile(age_group).get("fare_multiplier", 1.0))
		var route: Dictionary = snapshot.get("routes_by_od_age", {}).get(
			_resident_age_route_key(od_id, age_group),
			routes_by_od.get(od_id, {})
		)
		if not bool(route.get("reachable", false)):
			continue
		var ride_legs := _resident_ride_legs(route.get("legs", []))
		if ride_legs.is_empty():
			continue
		var passengers_this_step := trips_per_day * delta_minutes / 1440.0
		if passengers_this_step <= 0.0:
			continue
		var leg: Dictionary = ride_legs[0]
		var line_id := str(leg.get("line_id", ""))
		if not _resident_line_operational(line_id):
			continue
		if not prepared_lines.has(line_id):
			_ensure_custom_line_runtime(line_id)
			prepared_lines[line_id] = true
		var network_lines: Dictionary = transit_network.get("lines", {})
		var line: Dictionary = network_lines.get(line_id, {})
		var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
		var origin_index := stop_ids.find(str(leg.get("from_stop_id", "")))
		var destination_index := stop_ids.find(str(leg.get("to_stop_id", "")))
		if origin_index < 0 or destination_index < 0 or origin_index == destination_index:
			continue
		var line_demand: Array = demand_by_line.get(line_id, [])
		line_demand.append({
			"origin_index": origin_index,
			"destination_index": destination_index,
			"passengers": passengers_this_step,
			"fare_weighted_passengers": passengers_this_step * fare_multiplier,
			"remaining_ride_legs": ride_legs.slice(1),
		})
		demand_by_line[line_id] = line_demand

	for line_id_value in demand_by_line.keys():
		var line_id := str(line_id_value)
		var network_lines: Dictionary = transit_network.get("lines", {})
		if not network_lines.has(line_id):
			continue
		var line: Dictionary = network_lines[line_id]
		if not _resident_line_operational(line_id):
			continue
		var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
		var matrix: Array = line.get("waiting_by_stop", _create_waiting_matrix(stop_ids.size()))
		var fare_weight_matrix: Array = line.get(
			"waiting_fare_weights_by_stop",
			_create_fare_weight_matrix(stop_ids.size())
		)
		var transfer_groups_matrix: Array = line.get(
			"resident_transfer_groups_by_stop",
			_create_resident_transfer_matrix(stop_ids.size())
		)
		for addition_value in demand_by_line[line_id]:
			var addition: Dictionary = addition_value
			var origin_index := int(addition["origin_index"])
			var destination_index := int(addition["destination_index"])
			if origin_index < 0 or origin_index >= matrix.size():
				continue
			var row: Array = matrix[origin_index]
			var fare_weight_row: Array = fare_weight_matrix[origin_index]
			var transfer_groups_row: Array = transfer_groups_matrix[origin_index]
			if destination_index < 0 or destination_index >= row.size():
				continue
			row[destination_index] = maxf(0.0, float(row[destination_index])) + float(addition["passengers"])
			fare_weight_row[destination_index] = maxf(0.0, float(fare_weight_row[destination_index])) + float(addition["fare_weighted_passengers"])
			var remaining_ride_legs := _resident_ride_legs(addition.get("remaining_ride_legs", []))
			if not remaining_ride_legs.is_empty():
				var groups: Array = transfer_groups_row[destination_index]
				groups.append({
					"passengers": maxf(0.0, float(addition["passengers"])),
					"fare_weighted_passengers": maxf(0.0, float(addition["fare_weighted_passengers"])),
					"remaining_ride_legs": remaining_ride_legs,
				})
				transfer_groups_row[destination_index] = groups
			matrix[origin_index] = row
			fare_weight_matrix[origin_index] = fare_weight_row
			transfer_groups_matrix[origin_index] = transfer_groups_row

		var abandoned := 0.0
		var maximum_queue_utilization := 0.0
		for origin_index in range(stop_ids.size()):
			if origin_index < 0 or origin_index >= matrix.size():
				continue
			var row: Array = matrix[origin_index]
			var fare_weight_row: Array = fare_weight_matrix[origin_index]
			var transfer_groups_row: Array = transfer_groups_matrix[origin_index]
			var waiting := 0.0
			for value in row:
				waiting += maxf(0.0, float(value))
			var stop := transit_stop(stop_ids[origin_index])
			var level := clampi(
				int(stop.get("level", 0)),
				0,
				int(Data.STATION_UPGRADE["max_level"])
			)
			var capacity := float(Data.STATION_UPGRADE["waiting_capacity"][level])
			if capacity > 0.0:
				maximum_queue_utilization = maxf(
					maximum_queue_utilization,
					clampf(waiting / capacity, 0.0, 1.0)
				)
			if waiting > capacity:
				var keep_ratio := capacity / waiting
				abandoned += waiting - capacity
				for destination_index in range(row.size()):
					row[destination_index] = maxf(0.0, float(row[destination_index])) * keep_ratio
					fare_weight_row[destination_index] = maxf(0.0, float(fare_weight_row[destination_index])) * keep_ratio
					var groups := _normalize_resident_transfer_groups(
						transfer_groups_row[destination_index],
						waiting
					)
					for group_index in range(groups.size()):
						var group: Dictionary = groups[group_index]
						group["passengers"] = float(group["passengers"]) * keep_ratio
						group["fare_weighted_passengers"] = float(group["fare_weighted_passengers"]) * keep_ratio
						groups[group_index] = group
					transfer_groups_row[destination_index] = groups
				matrix[origin_index] = row
				fare_weight_matrix[origin_index] = fare_weight_row
				transfer_groups_matrix[origin_index] = transfer_groups_row
		line["waiting_by_stop"] = matrix
		line["waiting_fare_weights_by_stop"] = fare_weight_matrix
		line["resident_transfer_groups_by_stop"] = transfer_groups_matrix
		line["current_abandonment_ppm"] = abandoned / delta_minutes
		line["total_abandoned_passengers"] = float(line.get("total_abandoned_passengers", 0.0)) + abandoned
		line["crowding_ratio"] = maxf(
			clampf(float(line.get("crowding_ratio", 0.0)), 0.0, 1.0),
			maximum_queue_utilization
		)
		network_lines[line_id] = line
		transit_network["lines"] = network_lines
		_update_custom_queue(line_id)

func _update_custom_queue(line_id: String) -> void:
	var network_lines: Dictionary = transit_network.get("lines", {})
	if not network_lines.has(line_id):
		return
	var line: Dictionary = network_lines[line_id]
	line["queue_passengers"] = custom_line_waiting_passengers(line_id)
	network_lines[line_id] = line
	transit_network["lines"] = network_lines


func _custom_line_vehicle_occupancy_ratio(line: Dictionary) -> float:
	var mode_profile := TransitModes.profile(str(line.get("mode", "bus")))
	var vehicle_capacity := maxf(
		1.0,
		float(mode_profile.get("vehicle_capacity", Data.BUS["capacity"]))
	)
	var maximum_occupancy := 0.0
	for vehicle_value in line.get("vehicles", []):
		if not (vehicle_value is Dictionary):
			continue
		var vehicle: Dictionary = vehicle_value
		var onboard_passengers := maxf(0.0, float(vehicle.get("onboard_passengers", 0.0)))
		maximum_occupancy = maxf(maximum_occupancy, onboard_passengers / vehicle_capacity)
	return clampf(maximum_occupancy, 0.0, 1.0)

func build_next_stop(line_key: String) -> bool:
	if is_sandbox():
		return false
	if not lines.has(line_key):
		return false

	var line: Dictionary = lines[line_key]
	if line_key != "line1" and not bool(line["built"]):
		return false

	var max_stops := int(Data.LINE_CONFIG[line_key]["max_stops"])
	if int(line["stop_count"]) >= max_stops:
		return false

	var cost := next_stop_cost(line_key)
	if money < cost:
		_request_toast("Not enough money.")
		return false

	money -= cost
	line["stop_count"] = int(line["stop_count"]) + 1
	lines[line_key] = line

	if line_key == "line1" and int(line["stop_count"]) == 2:
		_initialize_line_service("line1", 1)
		_request_toast("Bus Line 1 opened with one starter bus.")

	_commit_change()
	return true

func build_line(line_key: String) -> bool:
	if is_sandbox():
		return false
	if line_key == "line1" or not can_unlock_line(line_key):
		return false

	var cost := line_build_cost(line_key)
	if money < cost:
		_request_toast("Not enough money.")
		return false

	money -= cost
	var line: Dictionary = lines[line_key]
	line["stop_count"] = 2
	lines[line_key] = line
	_initialize_line_service(line_key, 1)

	_request_toast("Bus Line %d opened." % Data.line_number(line_key))
	_commit_change()
	return true

func build_depot() -> bool:
	if is_sandbox():
		return begin_depot_placement()
	if not can_build_depot():
		return false
	if money < float(Data.ECONOMY["depot_build_cost"]):
		_request_toast("Not enough money.")
		return false

	money -= float(Data.ECONOMY["depot_build_cost"])
	depot["built"] = true
	_request_toast("Bus Depot opened.")
	_commit_change()
	return true

func add_bus(line_key: String) -> bool:
	if is_sandbox():
		return false
	if not bool(depot["built"]) or not bool(lines[line_key]["built"]):
		return false
	if garage_used() >= int(depot["garage_slots"]):
		_request_toast("Garage is full.")
		return false
	if int(lines[line_key]["fleet_count"]) >= int(Data.ECONOMY["max_vehicles_per_line"]):
		return false

	var cost := vehicle_purchase_cost()
	if money < cost:
		_request_toast("Not enough money.")
		return false

	money -= cost
	_add_vehicle_to_line_state(line_key)
	_request_toast("Bus added to Line %d." % Data.line_number(line_key))
	_commit_change()
	return true

func upgrade_depot() -> bool:
	if not bool(depot["built"]):
		return false

	var cost := roundi(
		float(Data.ECONOMY["depot_upgrade_base_cost"])
		* pow(float(Data.ECONOMY["depot_upgrade_cost_growth"]), int(depot["level"]))
	)
	if money < cost:
		_request_toast("Not enough money.")
		return false

	money -= cost
	depot["level"] = int(depot["level"]) + 1
	depot["garage_slots"] = int(depot["garage_slots"]) + int(Data.ECONOMY["depot_upgrade_slots"])
	_commit_change()
	return true

func upgrade_station(station_id: String) -> bool:
	if not station_is_built(station_id):
		return false

	var level := station_level(station_id)
	if level >= int(Data.STATION_UPGRADE["max_level"]):
		_request_toast("This station is already a Hub.")
		return false

	var cost := station_upgrade_cost(station_id)
	if money < cost:
		_request_toast("Not enough money.")
		return false

	money -= cost
	stations[station_id]["level"] = level + 1
	_request_toast("%s upgraded to %s." % [Data.station_name(station_id), station_tier(station_id)])
	_commit_change()
	return true

func _generate_passengers(line_key: String, delta_minutes: float) -> void:
	var line: Dictionary = lines[line_key]
	if not bool(line["built"]) or int(line["stop_count"]) < 2:
		line["current_abandonment_ppm"] = 0.0
		return

	var abandoned := 0.0
	var matrix: Array = line["waiting_by_stop"]
	var stop_count := int(line["stop_count"])

	for origin in range(stop_count):
		var per_destination_rate := stop_demand(line_key, origin) / float(maxi(1, stop_count - 1))
		var row: Array = matrix[origin]

		for destination in range(stop_count):
			if origin == destination:
				continue
			row[destination] = float(row[destination]) + per_destination_rate * delta_minutes

		matrix[origin] = row
		var waiting := stop_waiting_passengers(line_key, origin)
		var station_id: String = Data.STATION_IDS[line_key][origin]
		var waiting_capacity := float(station_capacity(station_id))

		if waiting > waiting_capacity:
			var keep_ratio := waiting_capacity / waiting
			var excess := waiting - waiting_capacity
			abandoned += excess

			row = matrix[origin]
			for destination in range(stop_count):
				row[destination] = float(row[destination]) * keep_ratio
			matrix[origin] = row

	line["waiting_by_stop"] = matrix
	line["current_abandonment_ppm"] = abandoned / delta_minutes if delta_minutes > 0.0 else 0.0
	line["total_abandoned_passengers"] = float(line["total_abandoned_passengers"]) + abandoned
	lines[line_key] = line
	line["queue_passengers"] = line_waiting_passengers(line_key)

func _emit_passenger_event(
	line_key: String,
	event_type: String,
	stop_index: int,
	vehicle_id: int,
	count: float,
	fare: float = 0.0
) -> void:
	if count <= 0.0:
		return

	var line: Dictionary = lines[line_key]
	line["event_serial"] = int(line["event_serial"]) + 1
	var event := {
		"serial": int(line["event_serial"]),
		"type": event_type,
		"stop_index": stop_index,
		"vehicle_id": vehicle_id,
		"count": count,
		"fare": fare,
	}
	line["last_passenger_event"] = event

	var events: Array = line["passenger_events"]
	events.append(event)
	while events.size() > 24:
		events.pop_front()
	line["passenger_events"] = events
	lines[line_key] = line

func _unload_at_stop(line_key: String, vehicle: Dictionary, stop_index: int) -> float:
	var onboard: Array = vehicle["onboard_by_destination"]
	var alighting := float(onboard[stop_index])
	if alighting <= 0.0:
		return 0.0

	onboard[stop_index] = 0.0
	vehicle["onboard_by_destination"] = onboard
	vehicle["onboard_passengers"] = max(0.0, float(vehicle["onboard_passengers"]) - alighting)

	var fare := alighting * float(Data.ECONOMY["fare_per_passenger"])
	money += fare
	stats["lifetime_revenue"] = float(stats["lifetime_revenue"]) + fare
	stats["lifetime_passengers"] = float(stats["lifetime_passengers"]) + alighting
	stats["last_fare_event_value"] = fare
	stats["last_fare_event_serial"] = int(stats["last_fare_event_serial"]) + 1
	stats["last_fare_line"] = line_key
	stats["last_fare_stop_index"] = stop_index

	var line: Dictionary = lines[line_key]
	line["last_delivered_ppm"] = float(line["last_delivered_ppm"]) + alighting / float(Data.DELIVERY_RATE_WINDOW_MINUTES)
	lines[line_key] = line

	_emit_passenger_event(line_key, "alight", stop_index, int(vehicle["id"]), alighting, fare)
	var transfer_stop_id: String = Data.STATION_IDS[line_key][stop_index]
	_inject_transfer_passengers(transfer_stop_id, line_key, alighting)
	_fare_changed_this_frame = true
	return alighting

func _board_at_stop(line_key: String, vehicle: Dictionary) -> float:
	var line: Dictionary = lines[line_key]
	var stop_index := int(vehicle["current_stop_index"])
	var available_space := float(Data.BUS["capacity"]) - float(vehicle["onboard_passengers"])
	if available_space <= 0.0:
		return 0.0

	var destinations: Array[int] = []
	if int(vehicle["direction"]) > 0:
		for destination in range(stop_index + 1, int(line["stop_count"])):
			destinations.append(destination)
	else:
		for destination in range(stop_index - 1, -1, -1):
			destinations.append(destination)

	var boarded := 0.0
	var matrix: Array = line["waiting_by_stop"]
	var onboard: Array = vehicle["onboard_by_destination"]
	var row: Array = matrix[stop_index]

	for destination in destinations:
		if available_space <= 0.0:
			break

		var waiting := float(row[destination])
		if waiting <= 0.0:
			continue

		var take: float = minf(waiting, available_space)
		row[destination] = waiting - take
		onboard[destination] = float(onboard[destination]) + take
		vehicle["onboard_passengers"] = float(vehicle["onboard_passengers"]) + take
		boarded += take
		available_space -= take

	matrix[stop_index] = row
	line["waiting_by_stop"] = matrix
	lines[line_key] = line
	vehicle["onboard_by_destination"] = onboard
	line["queue_passengers"] = line_waiting_passengers(line_key)

	_emit_passenger_event(line_key, "board", stop_index, int(vehicle["id"]), boarded, 0.0)
	return boarded

func _begin_boarding(line_key: String, vehicle: Dictionary) -> void:
	_board_at_stop(line_key, vehicle)
	vehicle["phase"] = "boarding"
	vehicle["phase_duration_minutes"] = float(Data.BOARDING_HOLD_MINUTES)
	vehicle["phase_minutes_remaining"] = float(Data.BOARDING_HOLD_MINUTES)

func _start_travel(line_key: String, vehicle: Dictionary) -> void:
	var line: Dictionary = lines[line_key]
	var current := int(vehicle["current_stop_index"])
	var direction := int(vehicle["direction"])

	if current == 0 and direction < 0:
		direction = 1
	if current == int(line["stop_count"]) - 1 and direction > 0:
		direction = -1
	vehicle["direction"] = direction

	var next_stop := current + direction
	if next_stop < 0 or next_stop >= int(line["stop_count"]):
		return

	vehicle["next_stop_index"] = next_stop
	vehicle["phase"] = "travel"
	var travel := _segment_travel_minutes(line_key, current, next_stop)
	vehicle["phase_duration_minutes"] = travel
	vehicle["phase_minutes_remaining"] = travel

func _arrive_at_stop(line_key: String, vehicle: Dictionary) -> void:
	vehicle["current_stop_index"] = int(vehicle["next_stop_index"])
	_unload_at_stop(line_key, vehicle, int(vehicle["current_stop_index"]))

	var line: Dictionary = lines[line_key]
	if int(vehicle["current_stop_index"]) == 0:
		vehicle["direction"] = 1
	elif int(vehicle["current_stop_index"]) == int(line["stop_count"]) - 1:
		vehicle["direction"] = -1

	vehicle["phase"] = "dwell"
	var dwell := _stop_dwell_minutes(line_key, int(vehicle["current_stop_index"]))
	vehicle["phase_duration_minutes"] = dwell
	vehicle["phase_minutes_remaining"] = dwell

func _advance_vehicle(line_key: String, vehicle: Dictionary, delta_minutes: float) -> void:
	var remaining := delta_minutes
	var guard := 0

	while remaining > 0.0 and guard < 8:
		guard += 1
		var phase_remaining: float = maxf(0.0, float(vehicle["phase_minutes_remaining"]))
		var step: float = minf(remaining, phase_remaining)
		vehicle["phase_minutes_remaining"] = float(vehicle["phase_minutes_remaining"]) - step
		remaining -= step

		if float(vehicle["phase_minutes_remaining"]) > 0.000000001:
			break

		match str(vehicle["phase"]):
			"travel":
				_arrive_at_stop(line_key, vehicle)
			"dwell":
				_begin_boarding(line_key, vehicle)
			_:
				_start_travel(line_key, vehicle)

		if float(vehicle["phase_minutes_remaining"]) <= 0.0 and remaining <= 0.0:
			break

func _simulate_line(line_key: String, delta_minutes: float) -> void:
	_ensure_line_runtime(line_key)
	var line: Dictionary = lines[line_key]

	if not bool(line["built"]):
		line["queue_passengers"] = 0.0
		line["current_abandonment_ppm"] = 0.0
		line["last_delivered_ppm"] = 0.0
		lines[line_key] = line
		return

	var decay := exp(-delta_minutes / float(Data.DELIVERY_RATE_WINDOW_MINUTES))
	line["last_delivered_ppm"] = float(line["last_delivered_ppm"]) * decay
	lines[line_key] = line

	_generate_passengers(line_key, delta_minutes)

	line = lines[line_key]
	var vehicles: Array = line["vehicles"]
	for vehicle in vehicles:
		_advance_vehicle(line_key, vehicle, delta_minutes)
	line["vehicles"] = vehicles
	lines[line_key] = line
	line["queue_passengers"] = line_waiting_passengers(line_key)

func _advance_simulation(real_delta_seconds: float) -> bool:
	if real_delta_seconds <= 0.0 or simulation_speed <= 0:
		return false

	var delta_seconds: float = minf(real_delta_seconds, 0.25) * float(simulation_speed)
	var delta_minutes: float = delta_seconds * float(Data.GAME_MINUTES_PER_REAL_SECOND)
	elapsed_seconds += delta_seconds
	if is_sandbox():
		_generate_resident_transport_demand(delta_minutes)

	for line_key in Data.LINE_KEYS:
		_simulate_line(line_key, delta_minutes)
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		_simulate_custom_line(line_id, delta_minutes)
	if is_sandbox():
		_accrue_sandbox_operating_costs(delta_minutes)

	var city_did_change := CityRuntime.advance(self, delta_seconds)
	var health_did_change := _advance_resident_health(delta_seconds)
	if health_did_change:
		_fare_changed_this_frame = true
	return city_did_change or health_did_change

func _accrue_sandbox_operating_costs(delta_minutes: float) -> void:
	if delta_minutes <= 0.0:
		return
	var operating_units := 0.0
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		var line := transit_line(line_id)
		if str(line.get("status", "")) == "active":
			var profile := TransitModes.profile(str(line.get("mode", "bus")))
			operating_units += float(line.get("fleet_count", 0)) * float(profile.get("operating_cost_multiplier", 1.0))
	var transit_cost := (
		operating_units
		* delta_minutes
		* float(Data.ECONOMY["sandbox_operating_cost_per_bus_minute"])
	)
	var service_cost := 0.0
	for facility_value in city.get("service_buildings", []):
		if typeof(facility_value) != TYPE_DICTIONARY:
			continue
		var facility: Dictionary = facility_value
		if str(facility.get("source", "")) != "player" or str(facility.get("status", "")) != "operational":
			continue
		service_cost += maxf(0.0, float(facility.get("operatingCostPerMinute", 0.0))) * delta_minutes
	var cost := transit_cost + service_cost
	if cost <= 0.0:
		return
	money -= cost
	stats["lifetime_operating_costs"] = float(stats.get("lifetime_operating_costs", 0.0)) + cost
	stats["last_operating_cost"] = cost
	stats["operator_net_operating"] = float(stats.get("lifetime_revenue", 0.0)) - float(stats.get("lifetime_operating_costs", 0.0))
	_fare_changed_this_frame = true

func bus_visuals() -> Array[Dictionary]:
	var result: Array[Dictionary] = []

	for line_key in Data.LINE_KEYS:
		var line: Dictionary = lines[line_key]
		if not bool(line["built"]):
			continue

		for vehicle in line["vehicles"]:
			var current_stop := int(vehicle["current_stop_index"])
			var point := Layout.stop_position(line_key, current_stop)
			var tangent := Vector2.RIGHT

			if str(vehicle["phase"]) == "travel":
				var next_stop := int(vehicle["next_stop_index"])
				var segment_index := mini(current_stop, next_stop)
				var route := Layout.segment_points(line_key, segment_index)
				if current_stop > next_stop:
					route.reverse()

				var duration: float = maxf(0.000001, float(vehicle["phase_duration_minutes"]))
				var progress: float = clampf(
					1.0 - float(vehicle["phase_minutes_remaining"]) / duration,
					0.0,
					1.0
				)
				var route_point := Layout.point_on_route(route, Layout.route_length(route) * progress)
				point = route_point["position"]
				tangent = route_point["tangent"]
			else:
				var candidate_next := current_stop + (1 if int(vehicle["direction"]) >= 0 else -1)
				if candidate_next >= 0 and candidate_next < int(line["stop_count"]):
					var segment_index := mini(current_stop, candidate_next)
					var segment := Layout.segment_points(line_key, segment_index)
					if current_stop > candidate_next:
						segment.reverse()
					if segment.size() >= 2:
						tangent = (segment[1] - segment[0]).normalized()

			result.append({
				"key": "%s:%d" % [line_key, int(vehicle["id"])],
				"line_key": line_key,
				"mode": "bus",
				"position": point,
				"tangent": tangent,
				"onboard": float(vehicle["onboard_passengers"]),
			})

	for line_id in TransitNetwork.custom_line_ids(transit_network):
		var custom_line := transit_line(line_id)
		if str(custom_line.get("status", "")) != "active":
			continue
		var stop_ids := TransitNetwork.line_stop_ids(transit_network, line_id)
		var segments: Array = custom_line.get("route_segments", [])
		for vehicle_value in custom_line.get("vehicles", []):
			var vehicle: Dictionary = vehicle_value
			var current_stop := int(vehicle.get("current_stop_index", 0))
			if current_stop < 0 or current_stop >= stop_ids.size():
				continue
			var point := TransitNetwork.stop_position(
				transit_network,
				stop_ids[current_stop]
			)
			var tangent := Vector2.RIGHT

			if str(vehicle.get("phase", "")) == "travel":
				var next_stop := int(vehicle.get("next_stop_index", current_stop))
				var segment_index := mini(current_stop, next_stop)
				if segment_index >= 0 and segment_index < segments.size():
					var segment: Dictionary = segments[segment_index]
					var route: Array[Vector2] = []
					for raw_value in segment.get("points", []):
						if typeof(raw_value) != TYPE_DICTIONARY:
							continue
						var raw: Dictionary = raw_value
						route.append(Vector2(
							float(raw.get("x", 0.0)),
							float(raw.get("y", 0.0))
						))
					if current_stop > next_stop:
						route.reverse()
					if route.size() >= 2:
						var duration := maxf(
							0.000001,
							float(vehicle.get("phase_duration_minutes", 0.0))
						)
						var progress := clampf(
							1.0 - float(vehicle.get("phase_minutes_remaining", 0.0)) / duration,
							0.0,
							1.0
						)
						var route_point := Layout.point_on_route(
							route,
							Layout.route_length(route) * progress
						)
						point = route_point["position"]
						tangent = route_point["tangent"]
			else:
				var candidate_next := current_stop + (
					1 if int(vehicle.get("direction", 1)) >= 0 else -1
				)
				var segment_index := mini(current_stop, candidate_next)
				if (
					candidate_next >= 0
					and candidate_next < stop_ids.size()
					and segment_index >= 0
					and segment_index < segments.size()
				):
					var segment: Dictionary = segments[segment_index]
					var route: Array[Vector2] = []
					for raw_value in segment.get("points", []):
						if typeof(raw_value) != TYPE_DICTIONARY:
							continue
						var raw: Dictionary = raw_value
						route.append(Vector2(
							float(raw.get("x", 0.0)),
							float(raw.get("y", 0.0))
						))
					if current_stop > candidate_next:
						route.reverse()
					if route.size() >= 2:
						tangent = (route[1] - route[0]).normalized()

			result.append({
				"key": "%s:%d" % [line_id, int(vehicle.get("id", 0))],
				"line_key": line_id,
				"mode": str(custom_line.get("mode", "bus")),
				"position": point,
				"tangent": tangent,
				"onboard": float(vehicle.get("onboard_passengers", 0.0)),
			})

	return result

func _commit_change() -> void:
	_invalidate_custom_catchment_cache()
	_resident_transport_snapshot_cache.clear()
	_resident_health_snapshot_cache.clear()
	var city_did_change := CityRuntime.sync_with_transport(self)
	_sync_transit_network_bridge()
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		_ensure_custom_line_runtime(line_id)
	if not suppress_persistence:
		save_game()
	state_changed.emit()
	if city_did_change:
		city_changed.emit()

func _request_toast(message: String) -> void:
	toast_requested.emit(message)

func save_game() -> void:
	if suppress_persistence:
		return
	_write_save_payload_atomically(SAVE_PATH, _current_save_payload())

func _current_save_payload() -> Dictionary:
	return {
		"version": Data.GAME_VERSION,
		"money": money,
		"elapsed_seconds": elapsed_seconds,
		"simulation_speed": simulation_speed,
		"city_seed": city_seed,
		"world_map": world_map,
		"lines": lines,
		"stations": stations,
		"depot": depot,
		"stats": stats,
		"city": city,
		"transit_network": transit_network,
	}

func export_save_copy(path: String) -> bool:
	var target_path := path.strip_edges()
	if target_path.is_empty():
		return false
	if not target_path.to_lower().ends_with(".json"):
		target_path += ".json"
	var absolute_target := ProjectSettings.globalize_path(target_path).simplify_path()
	for reserved_path in [SAVE_PATH, SAVE_PATH + ".bak", SAVE_PATH + ".tmp", SAVE_PATH + ".corrupt"]:
		if absolute_target == ProjectSettings.globalize_path(str(reserved_path)).simplify_path():
			push_warning("A save copy cannot overwrite an active autosave or recovery file.")
			return false
	return _write_save_payload_atomically(target_path, _current_save_payload())

static func _write_save_payload_atomically(save_path: String, payload: Dictionary) -> bool:
	var temporary_path := save_path + ".tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if not file:
		push_error("Could not open temporary save file: %s" % temporary_path)
		return false
	file.store_string(JSON.stringify(payload))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path))
		push_error("Could not write temporary save file: %s" % temporary_path)
		return false

	var final_absolute := ProjectSettings.globalize_path(save_path)
	var temporary_absolute := ProjectSettings.globalize_path(temporary_path)
	var backup_path := save_path + ".bak"
	var corrupt_path := save_path + ".corrupt"
	var backup_absolute := ProjectSettings.globalize_path(backup_path)
	var corrupt_absolute := ProjectSettings.globalize_path(corrupt_path)
	var had_previous := FileAccess.file_exists(save_path)
	var previous_is_valid := not _read_supported_save(save_path).is_empty() if had_previous else false
	var backup_is_valid := _read_supported_save(backup_path).size() > 0
	var previous_destination := backup_absolute
	if had_previous:
		# If the current file is corrupt but the retained backup is usable, keep
		# that last good save and quarantine the broken primary before replacing it.
		if not previous_is_valid and backup_is_valid:
			previous_destination = corrupt_absolute
			if FileAccess.file_exists(corrupt_path):
				DirAccess.remove_absolute(corrupt_absolute)
		else:
			if FileAccess.file_exists(backup_path):
				DirAccess.remove_absolute(backup_absolute)
		var backup_error := DirAccess.rename_absolute(final_absolute, previous_destination)
		if backup_error != OK:
			DirAccess.remove_absolute(temporary_absolute)
			push_error("Could not preserve the previous save (error %d)." % backup_error)
			return false
	var replace_error := DirAccess.rename_absolute(temporary_absolute, final_absolute)
	if replace_error != OK:
		if had_previous:
			DirAccess.rename_absolute(previous_destination, final_absolute)
		DirAccess.remove_absolute(temporary_absolute)
		push_error("Could not replace the save file (error %d)." % replace_error)
		return false
	return true

static func _read_supported_save(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var json := JSON.new()
	var parse_error := json.parse(file.get_as_text())
	file.close()
	if parse_error != OK:
		return {}
	var parsed: Variant = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var payload: Dictionary = parsed
	var version := int(payload.get("version", 0))
	if version < 2 or version > Data.GAME_VERSION:
		return {}
	for key in ["lines", "stations", "depot", "stats", "city", "transit_network", "world_map"]:
		if payload.has(key) and typeof(payload[key]) != TYPE_DICTIONARY:
			return {}
	for key in ["money", "elapsed_seconds", "simulation_speed", "city_seed"]:
		if payload.has(key) and typeof(payload[key]) not in [TYPE_INT, TYPE_FLOAT]:
			return {}
	if payload.has("money") and not is_finite(float(payload["money"])):
		return {}
	if payload.has("elapsed_seconds") and not is_finite(float(payload["elapsed_seconds"])):
		return {}
	return payload

static func _load_supported_save(primary_path: String, backup_path: String, temporary_path: String) -> Dictionary:
	var candidates := [primary_path, backup_path, temporary_path]
	for index in range(candidates.size()):
		var candidate_path := str(candidates[index])
		var payload := _read_supported_save(candidate_path)
		if not payload.is_empty():
			return {
				"payload": payload,
				"source_path": candidate_path,
				"recovered": index > 0,
			}
	return {}

func load_game() -> void:
	var selection := _load_supported_save(SAVE_PATH, SAVE_PATH + ".bak", SAVE_PATH + ".tmp")
	var parsed: Dictionary = selection.get("payload", {})
	if parsed.is_empty():
		if FileAccess.file_exists(SAVE_PATH) or FileAccess.file_exists(SAVE_PATH + ".bak") or FileAccess.file_exists(SAVE_PATH + ".tmp"):
			push_warning("No supported save could be recovered; existing save files were left untouched.")
		state_changed.emit()
		return
	if bool(selection.get("recovered", false)):
		push_warning("Recovered the latest supported game save from %s." % str(selection.get("source_path", "backup")))
	var save_version := int(parsed.get("version", 0))
	if save_version < Data.GAME_VERSION and not parsed.has("world_map"):
		parsed["world_map"] = WorldMapDefinition.create(WorldMapDefinition.LEGACY_CITY_MAP_ID, int(parsed.get("city_seed", Data.DEFAULT_CITY_SEED)))

	_apply_payload(parsed)

func import_browser_save(path: String) -> bool:
	var native_payload := _read_supported_save(path)
	if not native_payload.is_empty():
		_apply_payload(native_payload)
		if not suppress_persistence:
			save_game()
		_request_toast("Game save loaded.")
		return true

	var payload := BrowserSaveImporter.import_file(path)
	if payload.is_empty():
		_request_toast("Save could not be read. Choose a supported I Like Transit or browser save.")
		return false

	_apply_payload(payload)
	if not suppress_persistence:
		save_game()

	_request_toast("Browser save imported into Godot.")
	return true

func _apply_payload(parsed: Dictionary) -> void:
	money = float(parsed.get("money", money))
	elapsed_seconds = float(parsed.get("elapsed_seconds", 0.0))
	simulation_speed = int(parsed.get("simulation_speed", 1))
	city_seed = int(parsed.get("city_seed", Data.DEFAULT_CITY_SEED))
	world_map = WorldMapDefinition.normalize(
		parsed.get("world_map", {}),
		city_seed,
		true
	)
	WorldMapDefinition.set_active(world_map)
	TerrainSurface.set_terrain_edit_payload(world_map.get("terrain_edits", {}))
	lines = parsed.get("lines", lines)
	stations = parsed.get("stations", stations)
	depot = parsed.get("depot", depot)
	stats = parsed.get("stats", stats)
	city = parsed.get("city", CityRuntime.create_initial_city(
		city_seed,
		str(world_map.get("id", WorldMapDefinition.LEGACY_CITY_MAP_ID))
	))
	city["world_map_id"] = str(world_map.get("id", WorldMapDefinition.LEGACY_CITY_MAP_ID))
	city["world_seed"] = int(world_map.get("seed", city_seed))
	city["generator_version"] = int(world_map.get("generator_version", WorldMapDefinition.GENERATOR_VERSION))
	transit_network = parsed.get("transit_network", {})
	transit_network["pending_resident_transfers"] = _normalize_pending_resident_transfers(
		transit_network.get("pending_resident_transfers", [])
	)
	CityRuntime.ensure_city(self)

	for line_key in Data.LINE_KEYS:
		if not lines.has(line_key):
			lines[line_key] = _new_line_state(line_key)
		_ensure_line_runtime(line_key)

	for station_id in Data.all_station_ids():
		if not stations.has(station_id):
			stations[station_id] = {"level": 0}

	CityRuntime.sync_with_transport(self)
	_sync_transit_network_bridge()
	_invalidate_custom_catchment_cache()
	_resident_transport_snapshot_cache.clear()
	_resident_health_snapshot_cache.clear()
	for line_id in TransitNetwork.custom_line_ids(transit_network):
		_ensure_custom_line_runtime(line_id)
	route_editor = _empty_route_editor()
	road_builder = _empty_road_builder()
	depot_placement_mode = false
	state_changed.emit()
	city_changed.emit()
	selection_changed.emit(selected)
	route_editor_changed.emit()

func clear_save_and_reset(new_city_seed: int = -1) -> void:
	var resolved_seed := new_city_seed
	if resolved_seed < 0:
		var seed_generator := RandomNumberGenerator.new()
		seed_generator.randomize()
		resolved_seed = seed_generator.randi_range(1, 2147483647)
	reset_state(true, resolved_seed)
	CityRuntime.sync_with_transport(self)
	city_changed.emit()
	save_game()
