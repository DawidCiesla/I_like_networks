extends "res://scripts/core/game_store.gd"

const RegionalHighwayAnalysis = preload("res://scripts/city/regional_highway_analysis.gd")

## Regional sandbox funding policy.
##
## Basic network operations keep using the existing GameStore validation and
## mutation code, but they may temporarily bridge the old cash-only guard. The
## bridge is invisible to persistence: after the inherited operation returns,
## the real treasury is restored as `original_balance - actual_spend` and one
## normal commit is flushed with that final balance.
##
## Strategic regional-road projects remain subject to a hard debt floor. Higher
## transit-tier unlock rules are intentionally left untouched in the base store.
const REGIONAL_SOFT_CREDIT_LIMIT := -50000.0

var _soft_credit_bridge_active := false
var _soft_credit_original_money := 0.0
var _soft_credit_funded_money := 0.0
var _soft_credit_commit_deferred := false
var _soft_credit_previous_suppress_persistence := false


func _commit_change() -> void:
	if _soft_credit_bridge_active:
		_soft_credit_commit_deferred = true
		return
	super._commit_change()


func commit_road_builder() -> bool:
	if not is_sandbox():
		return super.commit_road_builder()
	var preview := road_builder_preview()
	var required_cash := maxf(0.0, float(preview.get("cost", 0.0)))
	var bridged := _begin_basic_credit_bridge(required_cash)
	var success := super.commit_road_builder()
	return _finish_basic_credit_bridge(bridged, success)


func build_depot_at(point: Vector2) -> bool:
	if not is_sandbox():
		return super.build_depot_at(point)
	var required_cash := maxf(0.0, float(Data.ECONOMY["sandbox_depot_build_cost"]))
	var bridged := _begin_basic_credit_bridge(required_cash)
	var success := super.build_depot_at(point)
	return _finish_basic_credit_bridge(bridged, success)


func commit_route_editor() -> bool:
	if not is_sandbox():
		return super.commit_route_editor()
	# Preserve the existing higher-tier capital/unlock gate. Only an already
	# unlocked mode may use basic-operation soft credit for its route itself.
	var transit_mode := _route_editor_mode_for_credit()
	if not transit_mode.is_empty():
		var mode_status := transit_mode_status(transit_mode)
		if not bool(mode_status.get("unlocked", false)):
			return super.commit_route_editor()
	var required_cash := _route_editor_cost_for_credit(transit_mode)
	var bridged := _begin_basic_credit_bridge(required_cash)
	var success := super.commit_route_editor()
	return _finish_basic_credit_bridge(bridged, success)


func upgrade_custom_stop(stop_id: String) -> bool:
	if not is_sandbox():
		return super.upgrade_custom_stop(stop_id)
	var required_cash := maxf(0.0, float(custom_stop_upgrade_cost(stop_id)))
	var bridged := _begin_basic_credit_bridge(required_cash)
	var success := super.upgrade_custom_stop(stop_id)
	return _finish_basic_credit_bridge(bridged, success)


func add_vehicle_to_transit_line(line_id: String) -> bool:
	if not is_sandbox():
		return super.add_vehicle_to_transit_line(line_id)
	var required_cash := maxf(0.0, float(transit_vehicle_purchase_cost(line_id)))
	var bridged := _begin_basic_credit_bridge(required_cash)
	var success := super.add_vehicle_to_transit_line(line_id)
	return _finish_basic_credit_bridge(bridged, success)


func regional_service_build_status(settlement_id: String, service_type: String) -> Dictionary:
	var status := super.regional_service_build_status(settlement_id, service_type)
	if not is_sandbox():
		return status
	if str(status.get("reason", "")) == "insufficient_funds":
		# Local public services are treated as continuity/basic infrastructure.
		# Their operating costs still hit the live treasury after construction.
		status["available"] = true
		status["reason"] = ""
		status["funding_mode"] = "soft_credit"
		status["balance_after"] = money - maxf(0.0, float(status.get("cost", 0.0)))
	return status


func regional_road_build_status(road_id: String) -> Dictionary:
	var status := super.regional_road_build_status(road_id)
	if not is_sandbox():
		return status
	var reason := str(status.get("reason", ""))
	if reason not in ["", "insufficient_funds"]:
		return status
	var road := _road_ref(road_id)
	var cost := maxf(0.0, float(status.get("cost", 0.0)))
	# Player-approved strategic proposals carry their own project-class CAPEX
	# estimate. Reuse it as the actual construction cost so the inspector and
	# treasury cannot disagree after the player presses BUILD.
	if not road.is_empty() and road.has("proposalConstructionCost"):
		cost = maxf(0.0, float(road.get("proposalConstructionCost", cost)))
		status["cost"] = roundi(cost)
	var balance_after := money - cost
	var allowed := balance_after >= REGIONAL_SOFT_CREDIT_LIMIT
	status["available"] = allowed
	status["reason"] = "" if allowed else "credit_limit"
	status["funding_mode"] = "cash" if money >= cost else "soft_credit"
	status["balance_after"] = balance_after
	status["soft_credit_limit"] = REGIONAL_SOFT_CREDIT_LIMIT
	return status


func infrastructure_proposal_build_status(proposal_id: String) -> Dictionary:
	if not is_sandbox():
		return {"available": false, "reason": "sandbox_only"}
	var proposal := _infrastructure_proposal_ref(proposal_id)
	if proposal.is_empty():
		return {"available": false, "reason": "proposal_not_found"}
	if str(proposal.get("type", "")) != "regional_relief_corridor":
		return {"available": false, "reason": "project_type_not_buildable_yet"}
	var proposal_status := str(proposal.get("status", "suggested"))
	if proposal_status in ["under-construction", "completed"]:
		return {"available": false, "reason": "construction_pending" if proposal_status == "under-construction" else "already_built"}
	var points_value: Variant = proposal.get("points", [])
	if typeof(points_value) != TYPE_ARRAY or (points_value as Array).size() < 2:
		return {"available": false, "reason": "invalid_geometry"}
	var project_class := str(proposal.get("projectClass", "bypass"))
	var estimate := RegionalHighwayAnalysis.estimate_project_cost(points_value, project_class)
	var cost := maxf(0.0, float(proposal.get("estimatedConstructionCost", estimate.get("construction_cost", 0.0))))
	var maintenance := maxf(0.0, float(proposal.get("estimatedMaintenancePerMinute", estimate.get("maintenance_per_minute", 0.0))))
	var balance_after := money - cost
	return {
		"available": balance_after >= REGIONAL_SOFT_CREDIT_LIMIT,
		"reason": "" if balance_after >= REGIONAL_SOFT_CREDIT_LIMIT else "credit_limit",
		"cost": cost,
		"maintenance_per_minute": maintenance,
		"balance_after": balance_after,
		"funding_mode": "cash" if money >= cost else "soft_credit",
		"soft_credit_limit": REGIONAL_SOFT_CREDIT_LIMIT,
	}


func build_infrastructure_proposal(proposal_id: String) -> bool:
	var status := infrastructure_proposal_build_status(proposal_id)
	if not bool(status.get("available", false)):
		_request_toast("Project cannot be started: %s." % str(status.get("reason", "unavailable")).replace("_", " "))
		return false
	var proposal := _infrastructure_proposal_ref(proposal_id)
	if proposal.is_empty():
		return false
	var road_id := str(proposal.get("constructedRoadId", ""))
	var staged_new_road := false
	if road_id.is_empty():
		road_id = "proposal-road-%s" % proposal_id
		var road := _road_from_relief_proposal(proposal, road_id, status)
		if road.is_empty():
			_request_toast("Project geometry could not be converted to a road.")
			return false
		city["roads"].append(road)
		proposal["constructedRoadId"] = road_id
		staged_new_road = true

	var previous_status := str(proposal.get("status", "suggested"))
	proposal["status"] = "accepted"
	proposal["playerDecision"] = "build"
	proposal["constructionAuthorized"] = true
	if not build_regional_road(road_id):
		proposal["status"] = previous_status
		proposal.erase("playerDecision")
		proposal["constructionAuthorized"] = false
		if staged_new_road:
			_remove_road_by_id(road_id)
			proposal.erase("constructedRoadId")
		return false
	proposal["status"] = "under-construction"
	proposal["constructionStartedAt"] = float(city.get("time_seconds", 0.0))
	_commit_change()
	return true


func _road_from_relief_proposal(proposal: Dictionary, road_id: String, build_status: Dictionary) -> Dictionary:
	var endpoints_value: Variant = proposal.get("betweenSettlementIds", [])
	if typeof(endpoints_value) != TYPE_ARRAY or (endpoints_value as Array).size() < 2:
		return {}
	var endpoints: Array = endpoints_value
	var project_class := str(proposal.get("projectClass", "bypass"))
	var profile := RoadProfile.base_profile("arterial")
	match project_class:
		"motorway":
			profile["speed_kph"] = 110.0
			var lanes: Array = profile.get("lanes", []).duplicate(true)
			lanes.insert(2, {"type": "vehicle", "direction": "forward", "width_m": 3.5})
			lanes.append({"type": "vehicle", "direction": "backward", "width_m": 3.5})
			profile["lanes"] = lanes
		"expressway":
			profile["speed_kph"] = 90.0
		_:
			profile["speed_kph"] = 70.0
	profile["sidewalk"] = {"left": false, "right": false}
	profile["parking"] = {"left": false, "right": false}
	return {
		"id": road_id,
		"districtId": "regional-infrastructure",
		"class": "arterial",
		"points": (proposal.get("points", []) as Array).duplicate(true),
		"unlock": null,
		"buildOrder": 50000 + int(city.get("next_player_road_project_serial", 1)),
		"source": "player",
		"owner": "player",
		"parentRoadIds": [str(proposal.get("sourceCorridorRoadId", ""))],
		"status": "planned",
		"constructionProgress": 0.0,
		"level": 0.0,
		"profile": profile,
		"regionalRole": "player_relief_corridor",
		"projectClass": project_class,
		"proposalId": str(proposal.get("id", "")),
		"proposalConstructionCost": maxf(0.0, float(build_status.get("cost", 0.0))),
		"maintenanceCostPerMinute": maxf(0.0, float(build_status.get("maintenance_per_minute", 0.0))),
		"a": str(endpoints[0]),
		"b": str(endpoints[1]),
		"bridgeCrossings": [],
	}


func _begin_basic_credit_bridge(required_cash: float) -> bool:
	if not is_sandbox() or money >= required_cash:
		return false
	_soft_credit_bridge_active = true
	_soft_credit_commit_deferred = false
	_soft_credit_original_money = money
	_soft_credit_funded_money = maxf(0.0, required_cash)
	_soft_credit_previous_suppress_persistence = suppress_persistence
	# This also protects us if a future base implementation invokes its own
	# commit path non-virtually: a temporary bridge balance is never persisted.
	suppress_persistence = true
	money = _soft_credit_funded_money
	return true


func _finish_basic_credit_bridge(bridged: bool, success: bool) -> bool:
	if not bridged:
		return success
	var temporary_balance := money
	var actual_spend := maxf(0.0, _soft_credit_funded_money - temporary_balance)
	var original_balance := _soft_credit_original_money
	var deferred_commit := _soft_credit_commit_deferred
	money = original_balance - actual_spend if success else original_balance
	suppress_persistence = _soft_credit_previous_suppress_persistence
	_soft_credit_bridge_active = false
	_soft_credit_commit_deferred = false
	_soft_credit_original_money = 0.0
	_soft_credit_funded_money = 0.0
	if success or deferred_commit:
		# Flush once with the real post-credit treasury. This also refreshes all
		# inherited transport/city caches exactly as the original action does.
		super._commit_change()
	return success


func _route_editor_mode_for_credit() -> String:
	if not route_editor_active():
		return ""
	var editor_mode := str(route_editor.get("mode", ""))
	var transit_mode := str(route_editor.get("transit_mode", "bus"))
	if editor_mode == "edit":
		transit_mode = str(transit_line(str(route_editor.get("line_id", ""))).get("mode", "bus"))
	return transit_mode


func _route_editor_cost_for_credit(transit_mode: String) -> float:
	if not route_editor_active():
		return 0.0
	var points := route_editor_points()
	var waypoints := route_editor_waypoints()
	var editor_mode := str(route_editor.get("mode", ""))
	if editor_mode == "new":
		return maxf(0.0, float(free_line_build_cost(points, waypoints, transit_mode)))
	if editor_mode == "edit":
		return maxf(0.0, float(free_line_edit_cost(points, waypoints, transit_mode)))
	return 0.0


func _infrastructure_proposal_ref(proposal_id: String) -> Dictionary:
	for proposal_value in city.get("infrastructure_proposals", []):
		if typeof(proposal_value) != TYPE_DICTIONARY:
			continue
		var proposal: Dictionary = proposal_value
		if str(proposal.get("id", "")) == proposal_id:
			return proposal
	return {}


func _road_ref(road_id: String) -> Dictionary:
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("id", "")) == road_id:
			return road
	return {}


func _remove_road_by_id(road_id: String) -> void:
	var roads: Array = city.get("roads", [])
	for index in range(roads.size() - 1, -1, -1):
		var road_value: Variant = roads[index]
		if typeof(road_value) == TYPE_DICTIONARY and str((road_value as Dictionary).get("id", "")) == road_id:
			roads.remove_at(index)
	city["roads"] = roads
