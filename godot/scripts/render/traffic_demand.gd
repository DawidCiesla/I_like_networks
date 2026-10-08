extends RefCounted
class_name TrafficDemand

const RESIDENT_TRIPS_PER_PERSON_PER_DAY := 0.55
const VISUAL_DENSITY_SCALE := 4.0


static func visible_vehicle_target(
	metrics: Dictionary,
	max_vehicles: int,
	density_scale: float = VISUAL_DENSITY_SCALE
) -> int:
	var capacity := maxi(0, max_vehicles)
	if capacity == 0:
		return 0
	var residents := maxf(0.0, float(metrics.get("resident_count", 0.0)))
	var car_share := clampf(float(metrics.get("car_share", 0.0)), 0.0, 1.0)
	if residents <= 0.0 or car_share <= 0.0:
		return 0
	var commute_minutes := clampf(float(metrics.get("average_commute_minutes", 0.0)), 0.0, 180.0)
	var trips_per_hour := residents * RESIDENT_TRIPS_PER_PERSON_PER_DAY * car_share / 24.0
	var average_cars_in_motion := trips_per_hour * commute_minutes / 60.0
	return clampi(roundi(average_cars_in_motion * maxf(0.0, density_scale)), 0, capacity)
