extends CanvasLayer
class_name RegionalSettlementMobilityWidget

const REFRESH_SECONDS := 0.5

var _panel: PanelContainer
var _title: Label
var _metrics: Label
var _why: Label
var _refresh_remaining := 0.0


func _ready() -> void:
	layer = 36
	_build_ui()
	_refresh()


func _process(delta: float) -> void:
	_refresh_remaining -= delta
	if _refresh_remaining <= 0.0:
		_refresh_remaining = REFRESH_SECONDS
		_refresh()


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.name = "RegionalSettlementMobility"
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_panel.offset_left = -382.0
	_panel.offset_right = -18.0
	_panel.offset_top = -218.0
	_panel.offset_bottom = -18.0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 7)
	margin.add_child(stack)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 13)
	stack.add_child(_title)

	_metrics = Label.new()
	_metrics.add_theme_font_size_override("font_size", 11)
	_metrics.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_metrics)

	_why = Label.new()
	_why.add_theme_font_size_override("font_size", 10)
	_why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_why)

	_panel.visible = false


func _refresh() -> void:
	var store := get_node_or_null("/root/GameStore")
	if not is_instance_valid(store) or not store.has_method("is_sandbox") or not bool(store.call("is_sandbox")):
		_panel.visible = false
		return
	var selection := str(store.get("selected"))
	if not selection.begins_with("settlement:"):
		_panel.visible = false
		return
	var settlement_id := selection.trim_prefix("settlement:")
	var settlement := _settlement_by_id(store.city, settlement_id)
	if settlement.is_empty():
		_panel.visible = false
		return
	_panel.visible = true
	var name := str(settlement.get("name", settlement_id)).to_upper()
	var available := bool(settlement.get("mobilityAccessibilityAvailable", false))
	var access := clampf(float(settlement.get("mobilityAccessibility", 0.0)), 0.0, 1.0)
	var commute := maxf(0.0, float(settlement.get("mobilityAverageCommuteMinutes", 0.0)))
	var unserved := clampf(float(settlement.get("mobilityUnservedShare", 0.0)), 0.0, 1.0)
	var transit := clampf(float(settlement.get("mobilityTransitShare", 0.0)), 0.0, 1.0)
	var max_vc := maxf(0.0, float(settlement.get("mobilityLocalMaxVcRatio", 0.0)))
	var growth_pressure := maxf(0.0, float(settlement.get("growthPressure", 0.0)))
	var growth_source := str(settlement.get("growthMobilitySource", "legacy_proxy"))
	var development_available := bool(settlement.get("developmentPressureAvailable", false))
	var development_pressure := clampf(float(settlement.get("developmentPressure", 0.0)), 0.0, 1.0)
	var development_peak := clampf(float(settlement.get("developmentPressurePeak", 0.0)), 0.0, 1.0)

	_title.text = "MOBILITY & GROWTH · %s" % name
	if not available:
		_metrics.text = "Accessibility data is not available yet. The growth model is using its compatibility proxy."
		_why.text = "WHY · Wait for the next traffic snapshot or establish a connected travel network."
		return
	var development_text := "n/a"
	if development_available:
		development_text = "%d/%d" % [roundi(development_pressure * 100.0), roundi(development_peak * 100.0)]
	_metrics.text = "Access %d/100 · commute %.1f min · transit %.0f%% · unserved %.0f%%\nRoad V/C max %.2f · growth pressure %.2f · parcel avg/peak %s" % [
		roundi(access * 100.0),
		commute,
		transit * 100.0,
		unserved * 100.0,
		max_vc,
		growth_pressure,
		development_text,
	]
	_why.text = "WHY · %s · source: %s" % [
		_explanation(access, commute, unserved, transit, max_vc, growth_pressure, development_pressure, development_available),
		growth_source.replace("_", " "),
	]


static func _explanation(
	access: float,
	commute: float,
	unserved: float,
	transit: float,
	max_vc: float,
	growth_pressure: float,
	development_pressure: float,
	development_available: bool
) -> String:
	var reasons: Array[String] = []
	if access >= 0.75:
		reasons.append("strong regional access supports development")
	elif access <= 0.45:
		reasons.append("weak regional access is limiting development")
	if max_vc >= 1.0:
		reasons.append("road congestion is reducing reliability")
	elif max_vc >= 0.85:
		reasons.append("road capacity is becoming constrained")
	if unserved >= 0.15:
		reasons.append("many trips remain unserved")
	if commute >= 40.0:
		reasons.append("commutes are long")
	elif commute <= 22.0:
		reasons.append("commutes are short")
	if transit >= 0.25:
		reasons.append("transit provides a meaningful alternative")
	if growth_pressure >= 0.58:
		reasons.append("current pressure supports outward expansion")
	elif growth_pressure < 0.35:
		reasons.append("current pressure favors slow or no expansion")
	if development_available:
		if development_pressure >= 0.70:
			reasons.append("many vacant parcels are attractive to develop")
		elif development_pressure < 0.35:
			reasons.append("vacant parcels have weak development pressure")
	if reasons.is_empty():
		return "mobility conditions are broadly neutral"
	return "; ".join(reasons)


static func _settlement_by_id(city: Dictionary, settlement_id: String) -> Dictionary:
	for settlement_value in city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var settlement: Dictionary = settlement_value
		if str(settlement.get("id", "")) == settlement_id:
			return settlement
	return {}
