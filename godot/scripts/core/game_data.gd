extends RefCounted
class_name GameData

const GAME_VERSION := 2
const DEFAULT_CITY_SEED := 284731

const LINE_KEYS := [
	"line1",
	"line2",
	"line3",
	"line4",
]

const LINE_COLORS := {
	"line1": Color("#0797ec"),
	"line2": Color("#f4ca00"),
	"line3": Color("#08b91c"),
	"line4": Color("#d02be3"),
}

const ECONOMY := {
	"starting_money": 100.0,
	"fare_per_passenger": 12.0,
	"bus_base_cost": 70.0,
	"bus_cost_growth": 1.32,
	"depot_build_cost": 130.0,
	"depot_upgrade_base_cost": 160.0,
	"depot_upgrade_cost_growth": 1.65,
	"depot_upgrade_slots": 4,
	"line1_stop_base_cost": 40.0,
	"line1_stop_cost_growth": 1.5,
	"line2_build_cost": 220.0,
	"line2_stop_base_cost": 75.0,
	"line2_stop_cost_growth": 1.55,
	"line3_build_cost": 520.0,
	"line3_stop_base_cost": 135.0,
	"line3_stop_cost_growth": 1.58,
	"line4_build_cost": 950.0,
	"line4_stop_base_cost": 210.0,
	"line4_stop_cost_growth": 1.6,
	"max_vehicles_per_line": 8,
}

const STATION_UPGRADE := {
	"max_level": 3,
	"base_cost": 55.0,
	"cost_growth": 1.85,
	"waiting_capacity": [45, 70, 105, 150],
	"demand_bonus": [0.0, 0.2, 0.45, 0.75],
	"dwell_reduction": [0.0, 0.025, 0.055, 0.085],
	"tier_names": ["Stop", "Shelter", "Station", "Hub"],
}

const STOP_NAMES := {
	"line1": ["Old Town", "Market Square", "City Park", "University", "Central"],
	"line2": ["City Park", "Riverside", "Museum", "Harbor"],
	"line3": ["University", "North Quarter", "Hillcrest", "Northgate", "Meadow End"],
	"line4": ["Harbor", "Docklands", "Eastgate", "Stadium", "Central"],
}

const STATION_IDS := {
	"line1": ["old-town", "market-square", "city-park", "university", "central"],
	"line2": ["city-park", "riverside", "museum", "harbor"],
	"line3": ["university", "north-quarter", "hillcrest", "northgate", "meadow-end"],
	"line4": ["harbor", "docklands", "eastgate", "stadium", "central"],
}

const LINE_CONFIG := {
	"line1": {
		"segment_lengths_km": [0.368, 0.6748566883, 0.7548566883, 0.8348566883],
		"demand_per_stop_ppm": 3.2,
		"max_stops": 5,
	},
	"line2": {
		"segment_lengths_km": [0.7068566883, 0.6908566883, 0.8028566883],
		"demand_per_stop_ppm": 2.8,
		"max_stops": 4,
	},
	"line3": {
		"segment_lengths_km": [0.7708566883, 0.7388566883, 0.6588566883, 0.5948566883],
		"demand_per_stop_ppm": 3.1,
		"max_stops": 5,
	},
	"line4": {
		"segment_lengths_km": [0.7388566883, 0.6748566883, 0.6588566883, 1.2028566883],
		"demand_per_stop_ppm": 3.4,
		"max_stops": 5,
	},
}

const BUS := {
	"capacity": 40.0,
	"speed_kph": 18.0,
	"dwell_minutes": 0.25,
	"turnaround_minutes": 1.0,
}

const GAME_MINUTES_PER_REAL_SECOND := 0.25
const DELIVERY_RATE_WINDOW_MINUTES := 0.5
const BOARDING_HOLD_MINUTES := 0.18

static func all_station_ids() -> Array[String]:
	var result: Array[String] = []
	for line_key in LINE_KEYS:
		for station_id in STATION_IDS[line_key]:
			if not result.has(station_id):
				result.append(station_id)
	return result

static func station_name(station_id: String) -> String:
	for line_key in LINE_KEYS:
		var ids: Array = STATION_IDS[line_key]
		var index := ids.find(station_id)
		if index >= 0:
			return STOP_NAMES[line_key][index]
	return station_id.capitalize()

static func line_number(line_key: String) -> int:
	return int(line_key.trim_prefix("line"))
