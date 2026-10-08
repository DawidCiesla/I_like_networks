extends RefCounted
class_name RoadProfile

const ROAD_CLASSES := ["local", "collector", "arterial", "service"]
const DIRECTIONS := ["forward", "backward", "both"]
const LANE_TYPES := ["vehicle", "bus", "bike", "tram"]
const SIDES := ["left", "right", "center"]

const BASE_PROFILES := {
	"local": {
		"road_class": "local",
		"direction": "both",
		"speed_kph": 30.0,
		"lanes": [
			{"type": "vehicle", "direction": "forward", "width_m": 3.0},
			{"type": "vehicle", "direction": "backward", "width_m": 3.0},
		],
		"sidewalk": {"left": true, "right": true},
		"parking": {"left": true, "right": true},
		"bus_lane": {"left": false, "right": false},
		"bike_lane": {"left": false, "right": false},
		"tram_reservation": false,
	},
	"collector": {
		"road_class": "collector",
		"direction": "both",
		"speed_kph": 40.0,
		"lanes": [
			{"type": "vehicle", "direction": "forward", "width_m": 3.25},
			{"type": "vehicle", "direction": "backward", "width_m": 3.25},
		],
		"sidewalk": {"left": true, "right": true},
		"parking": {"left": false, "right": false},
		"bus_lane": {"left": false, "right": false},
		"bike_lane": {"left": false, "right": false},
		"tram_reservation": false,
	},
	"arterial": {
		"road_class": "arterial",
		"direction": "both",
		"speed_kph": 60.0,
		"lanes": [
			{"type": "vehicle", "direction": "forward", "width_m": 3.5},
			{"type": "vehicle", "direction": "forward", "width_m": 3.5},
			{"type": "vehicle", "direction": "backward", "width_m": 3.5},
			{"type": "vehicle", "direction": "backward", "width_m": 3.5},
		],
		"sidewalk": {"left": true, "right": true},
		"parking": {"left": false, "right": false},
		"bus_lane": {"left": false, "right": false},
		"bike_lane": {"left": false, "right": false},
		"tram_reservation": false,
	},
	"service": {
		"road_class": "service",
		"direction": "both",
		"speed_kph": 20.0,
		"lanes": [
			{"type": "vehicle", "direction": "both", "width_m": 3.0},
		],
		"sidewalk": {"left": true, "right": true},
		"parking": {"left": false, "right": false},
		"bus_lane": {"left": false, "right": false},
		"bike_lane": {"left": false, "right": false},
		"tram_reservation": false,
	},
}


static func base_profile(road_class: String) -> Dictionary:
	if not BASE_PROFILES.has(road_class):
		return {}
	return (BASE_PROFILES[road_class] as Dictionary).duplicate(true)


## Adds lanes and composes property overrides over a base profile. Dictionary
## properties merge per side so one layer can enable a right-side bus lane while
## retaining the base profile's other side settings.
static func compose(
	base: Dictionary,
	lane_additions: Array = [],
	overrides: Dictionary = {}
) -> Dictionary:
	var profile := base.duplicate(true)
	var composition_errors: Array[String] = []
	var lanes: Array = profile.get("lanes", []).duplicate(true)
	for lane in lane_additions:
		lanes.append(lane.duplicate(true) if lane is Dictionary else lane)
	profile["lanes"] = lanes

	var supported_overrides := ["direction", "speed_kph", "sidewalk", "parking", "bus_lane", "bike_lane", "tram_reservation"]
	for key in overrides:
		if key not in supported_overrides:
			composition_errors.append("unsupported profile override: %s" % str(key))
	for key in ["direction", "speed_kph", "sidewalk", "parking", "bus_lane", "bike_lane", "tram_reservation"]:
		if not overrides.has(key):
			continue
		var value = overrides[key]
		if value is Dictionary and profile.get(key) is Dictionary:
			var merged: Dictionary = profile[key].duplicate(true)
			for subkey in value:
				merged[subkey] = value[subkey]
			profile[key] = merged
		else:
			profile[key] = value.duplicate(true) if value is Dictionary or value is Array else value

	var validation := validate(profile)
	var errors: Array[String] = validation["errors"].duplicate()
	errors.append_array(composition_errors)
	return {
		"valid": bool(validation["valid"]) and composition_errors.is_empty(),
		"profile": profile,
		"errors": errors,
	}


static func validate(profile: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var road_class := str(profile.get("road_class", ""))
	if road_class not in ROAD_CLASSES:
		errors.append("road_class must be local, collector, arterial, or service")
	if str(profile.get("direction", "")) not in DIRECTIONS:
		errors.append("direction must be forward, backward, or both")
	var speed_value = profile.get("speed_kph", null)
	if not (speed_value is int or speed_value is float) or float(speed_value) <= 0.0 or float(speed_value) > 130.0:
		errors.append("speed_kph must be greater than 0 and at most 130")

	var lanes = profile.get("lanes", null)
	if not lanes is Array or lanes.is_empty():
		errors.append("lanes must be a non-empty array")
	else:
		var tram_lane_count := 0
		var bus_lane_sides: Dictionary = {}
		var bike_lane_sides: Dictionary = {}
		for lane_index in range(lanes.size()):
			var lane = lanes[lane_index]
			if not lane is Dictionary:
				errors.append("lane %d must be an object" % lane_index)
				continue
			var lane_type := str(lane.get("type", ""))
			if lane_type not in LANE_TYPES:
				errors.append("lane %d has an unsupported type" % lane_index)
			var lane_direction := str(lane.get("direction", ""))
			if lane_direction not in DIRECTIONS:
				errors.append("lane %d has an invalid direction" % lane_index)
			var width_value = lane.get("width_m", null)
			if not (width_value is int or width_value is float) or float(width_value) < 1.0 or float(width_value) > 8.0:
				errors.append("lane %d width_m must be between 1 and 8" % lane_index)
			var side := str(lane.get("side", ""))
			if lane.has("side") and side not in SIDES:
				errors.append("lane %d side must be left, right, or center" % lane_index)
			if lane_type == "tram":
				tram_lane_count += 1
			if lane_type == "bus" and side in ["left", "right"]:
				bus_lane_sides[side] = true
			if lane_type == "bike" and side in ["left", "right"]:
				bike_lane_sides[side] = true
		if bool(profile.get("tram_reservation", false)) != (tram_lane_count > 0):
			errors.append("tram_reservation must match whether tram lanes are present")
		_validate_sides(profile, "bus_lane", bus_lane_sides, errors)
		_validate_sides(profile, "bike_lane", bike_lane_sides, errors)

	for key in ["sidewalk", "parking", "bus_lane", "bike_lane"]:
		var sides = profile.get(key, null)
		if not sides is Dictionary:
			errors.append("%s must define left and right" % key)
			continue
		for side in ["left", "right"]:
			if not sides.has(side) or not (sides[side] is bool):
				errors.append("%s.%s must be boolean" % [key, side])
	if not (profile.get("tram_reservation", null) is bool):
		errors.append("tram_reservation must be boolean")

	return {"valid": errors.is_empty(), "errors": errors}


static func _validate_sides(
	profile: Dictionary,
	property_name: String,
	lane_sides: Dictionary,
	errors: Array[String]
) -> void:
	var side_profile = profile.get(property_name, {})
	if not side_profile is Dictionary:
		return
	for side in ["left", "right"]:
		if bool(side_profile.get(side, false)) != bool(lane_sides.get(side, false)):
			errors.append("%s.%s must match the composed lane layout" % [property_name, side])
