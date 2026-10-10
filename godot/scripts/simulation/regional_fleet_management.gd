extends RefCounted
class_name RegionalFleetManagement

const TransitNetwork = preload("res://scripts/transport/transit_network.gd")
const EPSILON := 0.000001


static func retirement_status(store: Node, line_id: String) -> Dictionary:
	var line := _line(store, line_id)
	if line.is_empty() or str(line.get("source", "")) != "custom":
		return {"available": false, "reason": "line_not_found"}
	if str(line.get("status", "")) != "active":
		return {"available": false, "reason": "line_not_active"}
	var fleet := int(line.get("fleet_count", 0))
	var pending := pending_retirements(line)
	if fleet - pending <= 1:
		return {
			"available": false,
			"reason": "minimum_service_fleet",
			"fleet_count": fleet,
			"pending_retirements": pending,
		}
	var candidate := _retirement_candidate(line)
	return {
		"available": not candidate.is_empty(),
		"reason": "" if not candidate.is_empty() else "no_vehicle_available",
		"fleet_count": fleet,
		"pending_retirements": pending,
		"vehicle_id": int(candidate.get("id", -1)),
	}


static func schedule_retirement(store: Node, line_id: String) -> bool:
	var status := retirement_status(store, line_id)
	if not bool(status.get("available", false)):
		return false
	var lines: Dictionary = store.transit_network.get("lines", {})
	if not lines.has(line_id):
		return false
	var line: Dictionary = lines[line_id]
	var target_id := int(status.get("vehicle_id", -1))
	var vehicles: Array = line.get("vehicles", [])
	for index in range(vehicles.size()):
		if typeof(vehicles[index]) != TYPE_DICTIONARY:
			continue
		var vehicle: Dictionary = vehicles[index]
		if int(vehicle.get("id", -1)) != target_id:
			continue
		vehicle["retire_at_terminal"] = true
		vehicles[index] = vehicle
		line["vehicles"] = vehicles
		line["pending_retirements"] = pending_retirements(line)
		lines[line_id] = line
		store.transit_network["lines"] = lines
		return true
	return false


static func cancel_retirements(store: Node, line_id: String) -> bool:
	var lines: Dictionary = store.transit_network.get("lines", {})
	if not lines.has(line_id):
		return false
	var line: Dictionary = lines[line_id]
	var vehicles: Array = line.get("vehicles", [])
	var changed := false
	for index in range(vehicles.size()):
		if typeof(vehicles[index]) != TYPE_DICTIONARY:
			continue
		var vehicle: Dictionary = vehicles[index]
		if bool(vehicle.get("retire_at_terminal", false)):
			vehicle.erase("retire_at_terminal")
			vehicles[index] = vehicle
			changed = true
	if not changed:
		return false
	line["vehicles"] = vehicles
	line["pending_retirements"] = 0
	lines[line_id] = line
	store.transit_network["lines"] = lines
	return true


## Removes scheduled vehicles only when they are empty and physically at a
## route endpoint outside the travel phase. This avoids dropping passengers or
## teleporting a vehicle out of the middle of a corridor.
static func process_retirements(store: Node) -> int:
	var lines_value: Variant = store.transit_network.get("lines", {})
	if typeof(lines_value) != TYPE_DICTIONARY:
		return 0
	var lines: Dictionary = lines_value
	var total_retired := 0
	for line_id_value in lines.keys():
		var line_id := str(line_id_value)
		var line_value: Variant = lines[line_id]
		if typeof(line_value) != TYPE_DICTIONARY:
			continue
		var line: Dictionary = line_value
		if str(line.get("source", "")) != "custom":
			continue
		var stop_count := TransitNetwork.line_stop_ids(store.transit_network, line_id).size()
		if stop_count < 2:
			continue
		var last_stop := stop_count - 1
		var vehicles: Array = line.get("vehicles", [])
		var kept: Array = []
		var line_retired := 0
		for vehicle_value in vehicles:
			if typeof(vehicle_value) != TYPE_DICTIONARY:
				kept.append(vehicle_value)
				continue
			var vehicle: Dictionary = vehicle_value
			var current := int(vehicle.get("current_stop_index", 0))
			var at_terminal := current == 0 or current == last_stop
			var can_retire := (
				bool(vehicle.get("retire_at_terminal", false))
				and str(vehicle.get("phase", "")) != "travel"
				and at_terminal
				and float(vehicle.get("onboard_passengers", 0.0)) <= EPSILON
				and vehicles.size() - line_retired > 1
			)
			if can_retire:
				line_retired += 1
				total_retired += 1
				continue
			kept.append(vehicle)
		line["vehicles"] = kept
		line["fleet_count"] = kept.size()
		line["pending_retirements"] = pending_retirements(line)
		lines[line_id] = line
	store.transit_network["lines"] = lines
	return total_retired


static func pending_retirements(line: Dictionary) -> int:
	var count := 0
	for vehicle_value in line.get("vehicles", []):
		if typeof(vehicle_value) == TYPE_DICTIONARY and bool(vehicle_value.get("retire_at_terminal", false)):
			count += 1
	return count


static func _retirement_candidate(line: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	var best_score := INF
	for vehicle_value in line.get("vehicles", []):
		if typeof(vehicle_value) != TYPE_DICTIONARY:
			continue
		var vehicle: Dictionary = vehicle_value
		if bool(vehicle.get("retire_at_terminal", false)):
			continue
		var score := maxf(0.0, float(vehicle.get("onboard_passengers", 0.0)))
		if str(vehicle.get("phase", "")) == "travel":
			score += 1000.0
		if score < best_score:
			best_score = score
			best = vehicle
	return best


static func _line(store: Node, line_id: String) -> Dictionary:
	var lines_value: Variant = store.transit_network.get("lines", {})
	if typeof(lines_value) != TYPE_DICTIONARY:
		return {}
	var lines: Dictionary = lines_value
	var value: Variant = lines.get(line_id, {})
	return value if typeof(value) == TYPE_DICTIONARY else {}
