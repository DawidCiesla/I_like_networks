extends RefCounted
class_name RoadTrafficDemand

const DEFAULT_CAR_OCCUPANCY := 1.25
const EPSILON := 0.000001


## Converts aggregate ResidentTravelChoice flow rows into road-traffic OD demand.
## ResidentTravelChoice reports passenger trips over a modeled period, while the
## road assignment core works in vehicles per hour. Callers therefore provide
## the modeled period explicitly instead of relying on an implicit daily/hourly
## assumption.
##
## options:
## - period_hours (required, > 0)
## - average_car_occupancy (optional, default 1.25 persons / vehicle)
static func from_travel_choice(
	choice_result: Dictionary,
	options: Dictionary = {}
) -> Dictionary:
	var errors: Array[String] = []
	var period_hours := float(options.get("period_hours", 0.0))
	var occupancy := float(options.get("average_car_occupancy", DEFAULT_CAR_OCCUPANCY))
	if not is_finite(period_hours) or period_hours <= EPSILON:
		errors.append("period_hours must be finite and greater than zero")
	if not is_finite(occupancy) or occupancy <= EPSILON:
		errors.append("average_car_occupancy must be finite and greater than zero")
	if not errors.is_empty():
		return {
			"valid": false,
			"errors": errors,
			"demands": [],
			"totals": _empty_totals(),
		}

	var grouped: Dictionary = {}
	var passenger_car_trips := 0.0
	var input_rows := 0
	var flows_value: Variant = choice_result.get("flows", [])
	if typeof(flows_value) == TYPE_ARRAY:
		for row_value in flows_value:
			if typeof(row_value) != TYPE_DICTIONARY:
				continue
			input_rows += 1
			var row: Dictionary = row_value
			var origin := str(row.get("origin_id", "")).strip_edges()
			var destination := str(row.get("destination_id", "")).strip_edges()
			if origin.is_empty() or destination.is_empty() or origin == destination:
				continue
			var row_flows_value: Variant = row.get("flows", {})
			if typeof(row_flows_value) != TYPE_DICTIONARY:
				continue
			var row_flows: Dictionary = row_flows_value
			var car_trips := maxf(0.0, _finite_number(row_flows.get("car", 0.0)))
			if car_trips <= EPSILON:
				continue
			passenger_car_trips += car_trips
			var key := "%s\u001f%s" % [origin, destination]
			if not grouped.has(key):
				grouped[key] = {
					"origin_node": origin,
					"destination_node": destination,
					"passenger_car_trips": 0.0,
					"source_rows": 0,
				}
			var group: Dictionary = grouped[key]
			group["passenger_car_trips"] = float(group["passenger_car_trips"]) + car_trips
			group["source_rows"] = int(group["source_rows"]) + 1
			grouped[key] = group

	var keys: Array = grouped.keys()
	keys.sort()
	var demands: Array[Dictionary] = []
	var vehicle_vph := 0.0
	for key_value in keys:
		var group: Dictionary = grouped[key_value]
		var group_passenger_trips := float(group["passenger_car_trips"])
		var flow_vph := group_passenger_trips / occupancy / period_hours
		vehicle_vph += flow_vph
		demands.append({
			"id": "car:%s:%s" % [str(group["origin_node"]), str(group["destination_node"])],
			"origin_node": str(group["origin_node"]),
			"destination_node": str(group["destination_node"]),
			"vehicle_trips_per_hour": flow_vph,
			"passenger_car_trips": group_passenger_trips,
			"source_rows": int(group["source_rows"]),
		})

	return {
		"valid": true,
		"errors": [],
		"demands": demands,
		"totals": {
			"input_flow_rows": input_rows,
			"od_pairs": demands.size(),
			"passenger_car_trips": passenger_car_trips,
			"period_hours": period_hours,
			"average_car_occupancy": occupancy,
			"vehicle_trips_per_hour": vehicle_vph,
		},
	}


static func _finite_number(value: Variant) -> float:
	if typeof(value) not in [TYPE_FLOAT, TYPE_INT]:
		return 0.0
	var number := float(value)
	return number if is_finite(number) else 0.0


static func _empty_totals() -> Dictionary:
	return {
		"input_flow_rows": 0,
		"od_pairs": 0,
		"passenger_car_trips": 0.0,
		"period_hours": 0.0,
		"average_car_occupancy": 0.0,
		"vehicle_trips_per_hour": 0.0,
	}
