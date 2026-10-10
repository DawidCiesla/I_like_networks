extends RefCounted
class_name RegionalHighwayProposalRuntime

const RegionalHighwayAnalysis = preload("res://scripts/city/regional_highway_analysis.gd")


## Enriches planner proposals with measured traffic composition, counterfactual
## relief benefit and project lifecycle costs. The planner remains responsible
## for geometry/status; this adapter owns diagnostics derived from Traffic Core.
static func apply(city: Dictionary) -> bool:
	var roads := _road_lookup(city.get("roads", []))
	var before := _signature(city.get("infrastructure_proposals", []))
	for proposal_value in city.get("infrastructure_proposals", []):
		if typeof(proposal_value) != TYPE_DICTIONARY:
			continue
		var proposal: Dictionary = proposal_value
		_sync_construction_state(city, proposal, roads)
		var project_class := str(proposal.get("projectClass", "bypass"))
		var cost := RegionalHighwayAnalysis.estimate_project_cost(
			proposal.get("points", []),
			project_class
		)
		proposal["estimatedLengthKm"] = float(cost.get("length_km", 0.0))
		proposal["estimatedConstructionCost"] = float(cost.get("construction_cost", 0.0))
		proposal["estimatedMaintenancePerMinute"] = float(cost.get("maintenance_per_minute", 0.0))
		proposal["estimatedCostMultiplier"] = float(cost.get("cost_multiplier", 1.0))

		if str(proposal.get("type", "")) != "regional_relief_corridor":
			continue
		var source_road_value: Variant = roads.get(str(proposal.get("sourceCorridorRoadId", "")), {})
		if typeof(source_road_value) != TYPE_DICTIONARY or (source_road_value as Dictionary).is_empty():
			continue
		var source_road: Dictionary = source_road_value
		var endpoints_value: Variant = proposal.get("betweenSettlementIds", [])
		var endpoints: Array = endpoints_value if typeof(endpoints_value) == TYPE_ARRAY else []
		if endpoints.size() < 2:
			continue
		var composition := RegionalHighwayAnalysis.corridor_flow_composition(
			city,
			source_road,
			str(endpoints[0]),
			str(endpoints[1])
		)
		var benefit := RegionalHighwayAnalysis.estimate_relief_benefit(
			source_road,
			composition,
			project_class
		)
		var multiplier := RegionalHighwayAnalysis.strategic_pressure_multiplier(composition)
		var planner_pressure := float(proposal.get("pressure", 0.0))
		var base_pressure := float(proposal.get(
			"basePressure",
			planner_pressure / maxf(0.01, float(proposal.get("strategicPressureMultiplier", multiplier)))
		))
		proposal["basePressure"] = base_pressure
		proposal["trafficCompositionAvailable"] = bool(composition.get("available", false))
		proposal["trafficLocalVph"] = float(composition.get("local_vph", 0.0))
		proposal["trafficRegionalVph"] = float(composition.get("regional_vph", 0.0))
		proposal["trafficThroughVph"] = float(composition.get("through_vph", 0.0))
		proposal["trafficLocalShare"] = float(composition.get("local_share", 0.0))
		proposal["trafficRegionalShare"] = float(composition.get("regional_share", 0.0))
		proposal["trafficThroughShare"] = float(composition.get("through_share", 0.0))
		proposal["strategicPressureMultiplier"] = multiplier
		proposal["strategicPressure"] = base_pressure * multiplier
		proposal["strategicFit"] = _strategic_fit(composition)
		proposal["estimatedBenefitAvailable"] = bool(benefit.get("available", false))
		proposal["estimatedDiversionFraction"] = float(benefit.get("diversion_fraction", 0.0))
		proposal["estimatedTrafficDivertedVph"] = float(benefit.get("diverted_vph", 0.0))
		proposal["estimatedVcRatioAfter"] = float(benefit.get("vc_ratio_after", 0.0))
		proposal["estimatedDelayMinutesAfter"] = float(benefit.get("delay_minutes_after", 0.0))
		proposal["estimatedDelayReductionMinutes"] = float(benefit.get("delay_reduction_minutes", 0.0))
		proposal["estimatedVehicleHoursSavedPerHour"] = float(benefit.get("vehicle_hours_saved_per_hour", 0.0))
		proposal["estimatedBenefitScore"] = float(benefit.get("benefit_score", 0.0))
		proposal["strategicRecommendation"] = _recommendation(proposal)

	return before != _signature(city.get("infrastructure_proposals", []))


static func _sync_construction_state(city: Dictionary, proposal: Dictionary, roads: Dictionary) -> void:
	var road_id := str(proposal.get("constructedRoadId", ""))
	if road_id.is_empty():
		return
	var road_value: Variant = roads.get(road_id, {})
	if typeof(road_value) != TYPE_DICTIONARY or (road_value as Dictionary).is_empty():
		return
	var road: Dictionary = road_value
	if str(road.get("status", "")) == "built":
		proposal["status"] = "completed"
		proposal["activeNeed"] = false
		proposal["constructionCompletedAt"] = float(city.get("time_seconds", 0.0))
		return
	for project_value in city.get("projects", []):
		if typeof(project_value) != TYPE_DICTIONARY:
			continue
		var project: Dictionary = project_value
		if str(project.get("type", "")) != "road" or str(project.get("targetId", "")) != road_id:
			continue
		if str(project.get("status", "")) in ["queued", "active"]:
			proposal["status"] = "under-construction"
			proposal["constructionProgress"] = clampf(float(project.get("progress", 0.0)), 0.0, 1.0)
			return


static func _strategic_fit(composition: Dictionary) -> String:
	if not bool(composition.get("available", false)):
		return "unknown"
	var through := float(composition.get("through_share", 0.0))
	var regional := float(composition.get("regional_share", 0.0))
	if through >= 0.35:
		return "strong_through_traffic"
	if through + regional >= 0.45:
		return "regional_relief"
	return "local_traffic_dominated"


static func _recommendation(proposal: Dictionary) -> String:
	var fit := str(proposal.get("strategicFit", "unknown"))
	var benefit := float(proposal.get("estimatedBenefitScore", 0.0))
	if fit == "local_traffic_dominated":
		return "improve_local_network_first"
	if benefit >= 0.55:
		return "high_value_relief"
	if benefit >= 0.30:
		return "study_relief_corridor"
	return "monitor"


static func _road_lookup(roads: Array) -> Dictionary:
	var result: Dictionary = {}
	for road_value in roads:
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		var road_id := str(road.get("id", ""))
		if not road_id.is_empty():
			result[road_id] = road
	return result


static func _signature(proposals_value: Variant) -> String:
	if typeof(proposals_value) != TYPE_ARRAY:
		return ""
	var parts: Array[String] = []
	for proposal_value in proposals_value:
		if typeof(proposal_value) != TYPE_DICTIONARY:
			continue
		var proposal: Dictionary = proposal_value
		parts.append("%s:%s:%.3f:%.3f:%.3f:%.2f:%s" % [
			str(proposal.get("id", "")),
			str(proposal.get("status", "")),
			float(proposal.get("trafficThroughShare", 0.0)),
			float(proposal.get("estimatedVcRatioAfter", 0.0)),
			float(proposal.get("estimatedDelayReductionMinutes", 0.0)),
			float(proposal.get("estimatedConstructionCost", 0.0)),
			str(proposal.get("strategicRecommendation", "")),
		])
	parts.sort()
	return "|".join(parts)
