extends RefCounted
class_name BrowserSaveImporter

const Data = preload("res://scripts/core/game_data.gd")
const CityRuntime = preload("res://scripts/city/city_runtime.gd")

static func import_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}

	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}

	return convert(parsed)

static func convert(parsed: Dictionary) -> Dictionary:
	var source: Dictionary = parsed.get("state", parsed)
	var web_version := int(source.get("version", 0))
	if web_version < 6 or web_version > 12:
		return {}

	var city_seed := int(
		source.get(
			"city",
			{}
		).get(
			"seed",
			Data.DEFAULT_CITY_SEED
		)
	)

	var lines := {}
	for line_key in Data.LINE_KEYS:
		lines[line_key] = _convert_line(
			source.get(line_key, {}),
			line_key
		)

	var stations := {}
	for station_id in Data.all_station_ids():
		var raw_station: Dictionary = source.get("stations", {}).get(station_id, {})
		stations[station_id] = {
			"level": clampi(int(raw_station.get("level", 0)), 0, int(Data.STATION_UPGRADE["max_level"])),
		}

	var raw_depot: Dictionary = source.get("depot", {})
	var depot := {
		"built": bool(raw_depot.get("built", false)),
		"garage_slots": maxi(
			4,
			int(raw_depot.get("garageSlots", raw_depot.get("garage_slots", 4)))
		),
		"level": maxi(0, int(raw_depot.get("level", 0))),
	}

	var raw_stats: Dictionary = source.get("stats", {})
	var stats := {
		"lifetime_revenue": float(raw_stats.get("lifetimeRevenue", raw_stats.get("lifetime_revenue", 0.0))),
		"lifetime_passengers": float(raw_stats.get("lifetimePassengers", raw_stats.get("lifetime_passengers", 0.0))),
		"last_fare_event_value": float(raw_stats.get("lastFareEventValue", raw_stats.get("last_fare_event_value", 0.0))),
		"last_fare_event_serial": int(raw_stats.get("lastFareEventSerial", raw_stats.get("last_fare_event_serial", 0))),
		"last_fare_line": str(raw_stats.get("lastFareLine", raw_stats.get("last_fare_line", ""))),
		"last_fare_stop_index": int(raw_stats.get("lastFareStopIndex", raw_stats.get("last_fare_stop_index", -1))),
	}

	var city := _convert_city(source.get("city", {}), city_seed)

	return {
		"version": Data.GAME_VERSION,
		"migration_source": "browser-v%d" % web_version,
		"money": float(source.get("money", Data.ECONOMY["starting_money"])),
		"elapsed_seconds": float(source.get("elapsedSeconds", source.get("elapsed_seconds", 0.0))),
		"simulation_speed": int(source.get("simulationSpeed", source.get("simulation_speed", 1))),
		"city_seed": city_seed,
		"lines": lines,
		"stations": stations,
		"depot": depot,
		"stats": stats,
		"city": city,
	}

static func _convert_line(raw, line_key: String) -> Dictionary:
	var source: Dictionary = raw if typeof(raw) == TYPE_DICTIONARY else {}
	var max_stops := int(Data.LINE_CONFIG[line_key]["max_stops"])
	var waiting := _normalize_matrix(
		source.get("waitingByStop", source.get("waiting_by_stop", [])),
		max_stops
	)

	var vehicles: Array = []
	for raw_vehicle in source.get("vehicles", []):
		if typeof(raw_vehicle) != TYPE_DICTIONARY:
			continue
		vehicles.append(_convert_vehicle(raw_vehicle, max_stops))

	var events: Array = []
	for raw_event in source.get("passengerEvents", source.get("passenger_events", [])):
		if typeof(raw_event) == TYPE_DICTIONARY:
			events.append(_convert_event(raw_event))

	var last_event = source.get("lastPassengerEvent", source.get("last_passenger_event", null))
	if typeof(last_event) == TYPE_DICTIONARY:
		last_event = _convert_event(last_event)

	return {
		"built": bool(source.get("built", false)),
		"stop_count": clampi(
			int(source.get("stopCount", source.get("stop_count", 1 if line_key == "line1" else 0))),
			0 if line_key != "line1" else 1,
			max_stops
		),
		"fleet_count": maxi(0, int(source.get("fleetCount", source.get("fleet_count", vehicles.size())))),
		"demand_per_stop_ppm": float(source.get("demandPerStopPpm", source.get("demand_per_stop_ppm", Data.LINE_CONFIG[line_key]["demand_per_stop_ppm"]))),
		"waiting_by_stop": waiting,
		"queue_passengers": float(source.get("queuePassengers", source.get("queue_passengers", 0.0))),
		"current_abandonment_ppm": float(source.get("currentAbandonmentPpm", source.get("current_abandonment_ppm", 0.0))),
		"total_abandoned_passengers": float(source.get("totalAbandonedPassengers", source.get("total_abandoned_passengers", 0.0))),
		"last_delivered_ppm": float(source.get("lastDeliveredPpm", source.get("last_delivered_ppm", 0.0))),
		"vehicles": vehicles,
		"next_vehicle_id": maxi(1, int(source.get("nextVehicleId", source.get("next_vehicle_id", vehicles.size() + 1)))),
		"event_serial": maxi(0, int(source.get("eventSerial", source.get("event_serial", 0)))),
		"last_passenger_event": last_event,
		"passenger_events": events,
	}

static func _convert_vehicle(raw: Dictionary, max_stops: int) -> Dictionary:
	var onboard: Array = raw.get("onboardByDestination", raw.get("onboard_by_destination", []))
	var normalized: Array = []
	normalized.resize(max_stops)
	normalized.fill(0.0)
	for index in range(mini(max_stops, onboard.size())):
		normalized[index] = max(0.0, float(onboard[index]))

	return {
		"id": int(raw.get("id", 1)),
		"current_stop_index": int(raw.get("currentStopIndex", raw.get("current_stop_index", 0))),
		"next_stop_index": int(raw.get("nextStopIndex", raw.get("next_stop_index", 0))),
		"direction": int(raw.get("direction", 1)),
		"phase": str(raw.get("phase", "dwell")),
		"phase_minutes_remaining": float(raw.get("phaseMinutesRemaining", raw.get("phase_minutes_remaining", 0.0))),
		"phase_duration_minutes": float(raw.get("phaseDurationMinutes", raw.get("phase_duration_minutes", 0.0))),
		"onboard_by_destination": normalized,
		"onboard_passengers": max(0.0, float(raw.get("onboardPassengers", raw.get("onboard_passengers", 0.0)))),
	}

static func _convert_event(raw: Dictionary) -> Dictionary:
	return {
		"serial": int(raw.get("serial", 0)),
		"type": str(raw.get("type", "")),
		"stop_index": int(raw.get("stopIndex", raw.get("stop_index", 0))),
		"vehicle_id": int(raw.get("vehicleId", raw.get("vehicle_id", 0))),
		"count": float(raw.get("count", 0.0)),
		"fare": float(raw.get("fare", 0.0)),
	}

static func _normalize_matrix(raw, size: int) -> Array:
	var matrix: Array = []
	for row_index in range(size):
		var row: Array = []
		row.resize(size)
		row.fill(0.0)
		var source_row: Array = []
		if typeof(raw) == TYPE_ARRAY and row_index < raw.size() and typeof(raw[row_index]) == TYPE_ARRAY:
			source_row = raw[row_index]
		for column in range(mini(size, source_row.size())):
			row[column] = max(0.0, float(source_row[column]))
		matrix.append(row)
	return matrix

static func _convert_city(raw, seed: int) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY or raw.is_empty():
		return CityRuntime.create_initial_city(seed)

	var source: Dictionary = raw
	var generated := CityRuntime.create_initial_city(seed)

	return {
		"version": CityRuntime.CITY_VERSION,
		"seed": seed,
		"time_seconds": float(source.get("timeSeconds", source.get("time_seconds", 0.0))),
		"runtime_accumulator_seconds": float(source.get("runtimeAccumulatorSeconds", source.get("runtime_accumulator_seconds", 0.0))),
		"next_project_id": maxi(1, int(source.get("nextProjectId", source.get("next_project_id", 1)))),
		"nodes": source.get("nodes", generated.get("nodes", [])),
		"graph_edges": source.get("graphEdges", source.get("graph_edges", generated.get("graph_edges", []))),
		"junctions": source.get("junctions", generated.get("junctions", [])),
		"roads": source.get("roads", generated.get("roads", [])),
		"districts": source.get("districts", generated.get("districts", [])),
		"blocks": source.get("blocks", generated.get("blocks", [])),
		"parcels": source.get("parcels", generated.get("parcels", [])),
		"reservations": source.get("reservations", generated.get("reservations", [])),
		"buildings": source.get("buildings", []),
		"projects": source.get("projects", []),
	}
