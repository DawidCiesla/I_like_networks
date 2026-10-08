extends SceneTree

const RoadProfile = preload("res://scripts/city/road_profile.gd")
const Topology = preload("res://scripts/city/road_topology.gd")
const PlanGenerator = preload("res://scripts/city/city_plan_generator.gd")


func _initialize() -> void:
	var errors: Array[String] = []
	for road_class in RoadProfile.ROAD_CLASSES:
		var profile := RoadProfile.base_profile(road_class)
		var validation := RoadProfile.validate(profile)
		if profile.get("road_class") != road_class or not bool(validation["valid"]):
			errors.append("%s base profile is invalid: %s" % [road_class, str(validation["errors"])])
	if not RoadProfile.base_profile("unknown").is_empty():
		errors.append("unknown road classes must not produce a base profile")

	var collector := RoadProfile.base_profile("collector")
	var bus_lane := {
		"type": "bus",
		"direction": "forward",
		"width_m": 3.25,
		"side": "right",
	}
	var bike_lane := {
		"type": "bike",
		"direction": "forward",
		"width_m": 1.8,
		"side": "left",
	}
	var tram_lane := {
		"type": "tram",
		"direction": "both",
		"width_m": 6.0,
		"side": "center",
	}
	var composed := RoadProfile.compose(collector, [bus_lane, bike_lane, tram_lane], {
		"direction": "forward",
		"speed_kph": 45.0,
		"bus_lane": {"right": true},
		"bike_lane": {"left": true},
		"sidewalk": {"right": false},
		"parking": {"left": true},
		"tram_reservation": true,
	})
	if not bool(composed["valid"]):
		errors.append("valid bus lane composition was rejected: %s" % str(composed["errors"]))
	var composed_profile: Dictionary = composed["profile"]
	if float(composed_profile.get("speed_kph", 0.0)) != 45.0:
		errors.append("composition did not apply the speed override")
	if not composed_profile["bus_lane"]["right"] or not composed_profile["bike_lane"]["left"]:
		errors.append("composition did not enable its curbside transit and bicycle lanes")
	if composed_profile["sidewalk"]["right"] or not composed_profile["parking"]["left"]:
		errors.append("composition did not apply sidewalk and parking overrides")
	if str(composed_profile["direction"]) != "forward" or not bool(composed_profile["tram_reservation"]):
		errors.append("composition did not apply direction and tram reservation overrides")
	var invalid := collector.duplicate(true)
	invalid["speed_kph"] = 0.0
	if bool(RoadProfile.validate(invalid)["valid"]):
		errors.append("invalid speed limit was accepted")
	if bool(RoadProfile.compose(collector, [], {"unknown_option": true})["valid"]):
		errors.append("unknown profile composition options must be rejected")

	var level_zero := _road("surface", 0.0, [Vector2(-10, 0), Vector2(10, 0)])
	var level_one := _road("bridge", 1.0, [Vector2(0, -10), Vector2(0, 10)])
	var grade_graph := Topology.compile_graph([level_zero, level_one])
	if not (grade_graph["junctions"] as Array).is_empty():
		errors.append("roads crossing at different levels were merged into a junction")
	if (grade_graph["nodes"] as Array).size() != 4:
		errors.append("grade-separated crossing should retain four unsplit endpoints")
	var very_close_level := _road("close-bridge", 0.0001, [Vector2(0, -10), Vector2(0, 10)])
	var close_grade_graph := Topology.compile_graph([level_zero, very_close_level])
	if not (close_grade_graph["junctions"] as Array).is_empty():
		errors.append("distinct levels were merged after coordinate-key rounding")

	var same_grade := _road("same-grade", 0.0, [Vector2(0, -10), Vector2(0, 10)])
	var joined_graph := Topology.compile_graph([level_zero, same_grade])
	if (joined_graph["junctions"] as Array).size() != 1:
		errors.append("same-level crossing did not compile as a junction")
	var implicit_level := {"id": "implicit", "points": [{"x": -10.0, "y": 0.0}, {"x": 10.0, "y": 0.0}]}
	var default_graph := Topology.compile_graph([implicit_level, same_grade])
	if (default_graph["junctions"] as Array).size() != 1:
		errors.append("roads without an explicit level must retain level-zero connectivity")

	var plan := PlanGenerator.generate(731945)
	for road in plan.get("roads", []):
		if not road.has("level") or float(road["level"]) != 0.0:
			errors.append("generated road %s is missing its default level" % str(road.get("id", "?")))
			break
		var profile_check := RoadProfile.validate(road.get("profile", {}))
		if not bool(profile_check["valid"]):
			errors.append("generated road %s has an invalid profile" % str(road.get("id", "?")))
			break

	if not errors.is_empty():
		for error in errors:
			push_error(error)
		quit(1)
		return
	print("RoadProfile: PASS (4 profiles, composition, grade-separated topology)")
	quit(0)


func _road(road_id: String, level: float, points: Array[Vector2]) -> Dictionary:
	var serialized: Array = []
	for point in points:
		serialized.append({"x": point.x, "y": point.y})
	return {"id": road_id, "class": "local", "level": level, "points": serialized}
