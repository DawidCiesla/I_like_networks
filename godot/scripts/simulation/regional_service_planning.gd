extends RefCounted
class_name RegionalServicePlanning

const Data = preload("res://scripts/core/game_data.gd")
const RegionalFleetManagement = preload("res://scripts/simulation/regional_fleet_management.gd")

const EPSILON := 0.000001
const MIN_TARGET_HEADWAY_MINUTES := 4.0
const MAX_TARGET_HEADWAY_MINUTES := 30.0
const TARGET_HEADWAY_PRESETS := [5.0, 7.5, 10.0, 15.0, 20.0, 30.0]


static func default_target_headway(mode: String) -> float:
	match mode:
		"metro":
			return 7.5
		"tram":
			return 10.0
		_:
			return 15.0


static func target_headway(line: Dictionary) -> float:
	var stored := float(line.get("target_headway_minutes", 0.0))
	if stored >= MIN_TARGET_HEADWAY_MINUTES and stored <= MAX_TARGET_HEADWAY_MINUTES:
		return stored
	return default_target_headway(str(line.get("mode", "bus")))


static func set_target_headway(store: Node, line_id: String, minutes: float) -> bool:
	if minutes < MIN_TARGET_HEADWAY_MINUTES or minutes > MAX_TARGET_HEADWAY_MINUTES:
		return false
	var lines_value: Variant = store.transit_network.get("lines", {})
	if typeof(lines_value) != TYPE_DICTIONARY:
		return false
	var lines: Dictionary = lines_value
	var line_value: Variant = lines.get(line_id, {})
	if typeof(line_value) != TYPE_DICTIONARY:
		return false
	var line: Dictionary = line_value
	if str(line.get("source", "")) != "custom" or str(line.get("status", "")) != "active":
		return false
	line["target_headway_minutes"] = minutes
	lines[line_id] = line
	store.transit_network["lines"] = lines
	_persist_store_change(store)
	return true


static func service_plan(store: Node, line_id: String) -> Dictionary:
	var line := _line(store, line_id)
	if line.is_empty() or str(line.get("source", "")) != "custom":
		return {"available": false, "reason": "line_not_found"}
	if str(line.get("status", "")) != "active":
		return {"available": false, "reason": "line_not_active"}
	var cycle := _cycle_minutes(store, line_id, line)
	if cycle <= EPSILON or not is_finite(cycle):
		return {"available": false, "reason": "cycle_time_unavailable"}
	var target := target_headway(line)
	var uncapped_required := maxi(1, ceili(cycle / target))
	var max_fleet := maxi(1, int(Data.ECONOMY["max_vehicles_per_line"]))
	var required := mini(max_fleet, uncapped_required)
	var fleet := maxi(0, int(line.get("fleet_count", 0)))
	var pending := RegionalFleetManagement.pending_retirements(line)
	var planned_fleet := maxi(1, fleet - pending)
	var fleet_gap := required - planned_fleet
	var status := "on_target"
	if fleet_gap > 0:
		status = "increase_service"
	elif fleet_gap < 0:
		status = "reduce_service"
	var current_headway := cycle / float(fleet) if fleet > 0 else INF
	var planned_headway := cycle / float(planned_fleet)
	return {
		"available": true,
		"reason": "",
		"mode": str(line.get("mode", "bus")),
		"cycle_minutes": cycle,
		"target_headway_minutes": target,
		"current_headway_minutes": current_headway,
		"planned_headway_minutes": planned_headway,
		"required_fleet": required,
		"uncapped_required_fleet": uncapped_required,
		"target_feasible": uncapped_required <= max_fleet,
		"max_fleet": max_fleet,
		"fleet_count": fleet,
		"pending_retirements": pending,
		"planned_fleet": planned_fleet,
		"fleet_gap": fleet_gap,
		"status": status,
	}


## Moves one vehicle at a time toward the service target. Positive gaps buy a
## vehicle, except that an already-scheduled retirement is cancelled first.
## Negative gaps schedule one safe terminal retirement. There is deliberately
## no background automation that can spend money without a player action.
static func apply_one_step(store: Node, line_id: String) -> Dictionary:
	var plan := service_plan(store, line_id)
	if not bool(plan.get("available", false)):
		return {"changed": false, "action": "none", "reason": str(plan.get("reason", "unavailable"))}
	var gap := int(plan.get("fleet_gap", 0))
	if gap == 0:
		return {"changed": false, "action": "none", "reason": "target_met"}
	if gap > 0:
		if int(plan.get("pending_retirements", 0)) > 0:
			var cancelled := RegionalFleetManagement.cancel_retirements(store, line_id)
			if cancelled:
				_persist_store_change(store)
			return {
				"changed": cancelled,
				"action": "cancel_retirement" if cancelled else "none",
				"reason": "" if cancelled else "retirement_cancel_failed",
			}
		if not store.has_method("add_vehicle_to_transit_line"):
			return {"changed": false, "action": "none", "reason": "purchase_unavailable"}
		var purchased := bool(store.call("add_vehicle_to_transit_line", line_id))
		return {
			"changed": purchased,
			"action": "purchase_vehicle" if purchased else "none",
			"reason": "" if purchased else "purchase_failed",
		}
	var scheduled := RegionalFleetManagement.schedule_retirement(store, line_id)
	if scheduled:
		_persist_store_change(store)
	return {
		"changed": scheduled,
		"action": "schedule_retirement" if scheduled else "none",
		"reason": "" if scheduled else "retirement_unavailable",
	}


static func _cycle_minutes(store: Node, line_id: String, line: Dictionary) -> float:
	var traffic_cycle := float(line.get("traffic_effective_cycle_minutes", 0.0))
	if traffic_cycle > EPSILON and is_finite(traffic_cycle):
		return traffic_cycle
	if store.has_method("custom_line_cycle_minutes"):
		var fallback := float(store.call("custom_line_cycle_minutes", line_id))
		if fallback > EPSILON and is_finite(fallback):
			return fallback
	return 0.0


static func _line(store: Node, line_id: String) -> Dictionary:
	var lines_value: Variant = store.transit_network.get("lines", {})
	if typeof(lines_value) != TYPE_DICTIONARY:
		return {}
	var value: Variant = (lines_value as Dictionary).get(line_id, {})
	return value if typeof(value) == TYPE_DICTIONARY else {}


static func _persist_store_change(store: Node) -> void:
	if store.has_method("save_game"):
		store.call("save_game")
	if store.has_signal("state_changed"):
		store.emit_signal("state_changed")
