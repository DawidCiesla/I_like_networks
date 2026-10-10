extends CanvasLayer
class_name RegionalSelectionDiagnosticsWidget

const REFRESH_SECONDS := 0.4

var _panel: PanelContainer
var _title: Label
var _metrics: Label
var _why: Label
var _refresh_remaining := 0.0


func _ready() -> void:
	layer = 35
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
	_panel.name = "RegionalSelectionDiagnostics"
	_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel.offset_left = -382.0
	_panel.offset_right = -18.0
	_panel.offset_top = 86.0
	_panel.offset_bottom = 226.0
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 9)
	margin.add_theme_constant_override("margin_bottom", 9)
	_panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 5)
	margin.add_child(stack)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 12)
	stack.add_child(_title)
	_metrics = Label.new()
	_metrics.add_theme_font_size_override("font_size", 10)
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
	if selection.begins_with("regional_road:"):
		_show_road(store, selection.trim_prefix("regional_road:"))
	elif selection.begins_with("free_line:"):
		_show_line(store, selection.trim_prefix("free_line:"))
	else:
		_panel.visible = false


func _show_road(store: Node, road_id: String) -> void:
	var road := _road_by_id(store.city, road_id)
	if road.is_empty():
		_panel.visible = false
		return
	_panel.visible = true
	var traffic_value: Variant = road.get("traffic", {})
	var traffic: Dictionary = traffic_value if typeof(traffic_value) == TYPE_DICTIONARY else {}
	var flow := maxf(0.0, float(traffic.get("flow_vph", 0.0)))
	var capacity := maxf(0.0, float(traffic.get("capacity_vph", 0.0)))
	var vc := maxf(0.0, float(traffic.get("vc_ratio", 0.0)))
	var delay := maxf(0.0, float(traffic.get("delay_minutes", 0.0)))
	var speed := maxf(0.0, float(traffic.get("operational_speed_kph", 0.0)))
	var free_speed := maxf(0.0, float(traffic.get("free_flow_speed_kph", road.get("traffic_free_flow_speed_kph", 0.0))))
	var upkeep_text := "n/a"
	if road.has("maintenanceCostPerMinute"):
		upkeep_text = "$%.2f/min" % maxf(0.0, float(road.get("maintenanceCostPerMinute", 0.0)))
	_title.text = "WHY · ROAD · %s" % road_id.to_upper()
	_metrics.text = "Flow %.0f veh/h · cap %.0f · V/C %.2f · delay %.2f min\nSpeed %.0f/%.0f km/h · %s / %s · upkeep %s" % [flow, capacity, vc, delay, speed, free_speed, str(road.get("source", "unknown")), str(road.get("status", "unknown")), upkeep_text]
	_why.text = _road_explanation(vc, delay, speed, free_speed)


func _show_line(store: Node, line_id: String) -> void:
	var lines_value: Variant = store.transit_network.get("lines", {})
	if typeof(lines_value) != TYPE_DICTIONARY:
		_panel.visible = false
		return
	var line_value: Variant = (lines_value as Dictionary).get(line_id, {})
	if typeof(line_value) != TYPE_DICTIONARY:
		_panel.visible = false
		return
	var line: Dictionary = line_value
	_panel.visible = true
	var health_value: Variant = line.get("operations_health", {})
	var health: Dictionary = health_value if typeof(health_value) == TYPE_DICTIONARY else {}
	var fleet := maxi(0, int(line.get("fleet_count", 0)))
	var delivered := maxf(0.0, float(line.get("last_delivered_ppm", 0.0)))
	var delay_factor := maxf(1.0, float(line.get("traffic_delay_factor", 1.0)))
	var headway := float(line.get("traffic_effective_headway_minutes", INF))
	var load := maxf(0.0, float(health.get("effective_load_ratio", line.get("crowding_ratio", 0.0))))
	var status := str(health.get("status", "monitor")).replace("_", " ")
	var action := str(health.get("recommended_action", "monitor")).replace("_", " ")
	_title.text = "WHY · LINE · %s" % str(line.get("name", line_id)).to_upper()
	_metrics.text = "Delivered %.1f pax/min · fleet %d · headway %s\nLoad %.0f%% · traffic ×%.2f · ops %s" % [delivered, fleet, "—" if not is_finite(headway) else "%.1f min" % headway, load * 100.0, delay_factor, status.to_upper()]
	_why.text = _line_explanation(delivered, fleet, load, delay_factor, action)


static func _road_explanation(vc: float, delay: float, speed: float, free_speed: float) -> String:
	var reasons: Array[String] = []
	if vc >= 1.15:
		reasons.append("demand materially exceeds practical capacity")
	elif vc >= 0.90:
		reasons.append("the corridor is close to capacity")
	else:
		reasons.append("capacity currently covers assigned traffic")
	if delay >= 2.0:
		reasons.append("traffic adds significant travel-time delay")
	if free_speed > 0.0 and speed < free_speed * 0.75:
		reasons.append("operational speed is well below free flow")
	return "; ".join(reasons)


static func _line_explanation(delivered: float, fleet: int, load: float, delay_factor: float, action: String) -> String:
	var reasons: Array[String] = []
	if fleet <= 0:
		reasons.append("no vehicle is available")
	elif load >= 1.0:
		reasons.append("passenger load is above effective capacity")
	elif load >= 0.75:
		reasons.append("the line is carrying a high load")
	if delay_factor >= 1.25:
		reasons.append("road congestion is materially slowing service")
	if delivered <= 0.1:
		reasons.append("very little passenger demand is being delivered")
	if action != "monitor":
		reasons.append("recommended action: %s" % action)
	if reasons.is_empty():
		return "service conditions are broadly stable"
	return "; ".join(reasons)


static func _road_by_id(city: Dictionary, road_id: String) -> Dictionary:
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		if str(road.get("id", "")) == road_id:
			return road
	return {}
