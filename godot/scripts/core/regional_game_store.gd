extends "res://scripts/core/game_store.gd"

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
	var cost := maxf(0.0, float(status.get("cost", 0.0)))
	var balance_after := money - cost
	var allowed := balance_after >= REGIONAL_SOFT_CREDIT_LIMIT
	status["available"] = allowed
	status["reason"] = "" if allowed else "credit_limit"
	status["funding_mode"] = "cash" if money >= cost else "soft_credit"
	status["balance_after"] = balance_after
	status["soft_credit_limit"] = REGIONAL_SOFT_CREDIT_LIMIT
	return status


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
