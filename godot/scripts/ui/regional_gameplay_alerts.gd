extends CanvasLayer
class_name RegionalGameplayAlerts

const MAX_VISIBLE_ALERTS := 4
const REFRESH_SECONDS := 0.75

var _panel: PanelContainer
var _list: VBoxContainer
var _refresh_remaining := 0.0
var _signature := ""


func _ready() -> void:
	layer = 35
	_build_ui()
	_refresh(true)


func _process(delta: float) -> void:
	_refresh_remaining -= delta
	if _refresh_remaining <= 0.0:
		_refresh_remaining = REFRESH_SECONDS
		_refresh(false)


static func collect_alerts(city: Dictionary, transit_network: Dictionary) -> Array[Dictionary]:
	var alerts: Array[Dictionary] = []
	var worst_road: Dictionary = {}
	var worst_vc := 0.0
	for road_value in city.get("roads", []):
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		var traffic_value: Variant = road.get("traffic", {})
		if typeof(traffic_value) != TYPE_DICTIONARY:
			continue
		var traffic: Dictionary = traffic_value
		var vc := maxf(0.0, float(traffic.get("vc_ratio", 0.0)))
		if vc > worst_vc:
			worst_vc = vc
			worst_road = road
	if not worst_road.is_empty() and worst_vc >= 0.85:
		var traffic: Dictionary = worst_road.get("traffic", {})
		var severe := worst_vc >= 1.0
		alerts.append({
			"id": "road:%s" % str(worst_road.get("id", "")),
			"priority": 4 if severe else 2,
			"label": "%s · V/C %.2f · +%.1f min" % [
				"SEVERE ROAD CONGESTION" if severe else "ROAD CONGESTION",
				worst_vc,
				float(traffic.get("delay_minutes", 0.0)),
			],
			"selection": "regional_road:%s" % str(worst_road.get("id", "")),
			"tooltip": "Flow %.0f veh/h · capacity %.0f veh/h" % [
				float(traffic.get("flow_vph", 0.0)),
				float(traffic.get("capacity_vph", 0.0)),
			],
		})

	var lines_value: Variant = transit_network.get("lines", {})
	if typeof(lines_value) == TYPE_DICTIONARY:
		var lines: Dictionary = lines_value
		for line_id_value in lines.keys():
			var line_id := str(line_id_value)
			var line_value: Variant = lines[line_id]
			if typeof(line_value) != TYPE_DICTIONARY:
				continue
			var line: Dictionary = line_value
			var health_value: Variant = line.get("operations_health", {})
			if typeof(health_value) != TYPE_DICTIONARY:
				continue
			var health: Dictionary = health_value
			var severity := int(health.get("severity", 0))
			if severity < 2:
				continue
			var status := str(health.get("status", "warning"))
			alerts.append({
				"id": "line:%s" % line_id,
				"priority": severity,
				"label": "%s · %s" % [
					str(line.get("name", line_id)).to_upper(),
					_status_label(status),
				],
				"selection": "free_line:%s" % line_id,
				"tooltip": _line_tooltip(health),
			})

	alerts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_priority := int(a.get("priority", 0))
		var b_priority := int(b.get("priority", 0))
		if a_priority == b_priority:
			return str(a.get("id", "")) < str(b.get("id", ""))
		return a_priority > b_priority
	)
	return alerts


static func _status_label(status: String) -> String:
	match status:
		"overloaded":
			return "OVERLOADED"
		"capacity_warning":
			return "NEAR CAPACITY"
		"congestion_limited":
			return "DELAYED BY TRAFFIC"
		"under_served":
			return "LOW FREQUENCY"
		"no_service":
			return "NO SERVICE"
		_:
			return status.replace("_", " ").to_upper()


static func _line_tooltip(health: Dictionary) -> String:
	var headway := float(health.get("headway_minutes", INF))
	var headway_text := "—" if not is_finite(headway) else "%.1f min" % headway
	return "Headway %s · load %.0f%% · traffic ×%.2f · suggested: %s" % [
		headway_text,
		float(health.get("effective_load_ratio", 0.0)) * 100.0,
		float(health.get("traffic_delay_factor", 1.0)),
		str(health.get("recommended_action", "monitor")).replace("_", " "),
	]


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.name = "NetworkAlerts"
	_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel.offset_left = -360.0
	_panel.offset_right = -18.0
	_panel.offset_top = 92.0
	_panel.offset_bottom = 292.0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	margin.add_child(outer)

	var title := Label.new()
	title.text = "NETWORK ALERTS"
	title.add_theme_font_size_override("font_size", 12)
	outer.add_child(title)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	outer.add_child(_list)
	_panel.visible = false


func _refresh(force: bool) -> void:
	var store := get_node_or_null("/root/GameStore")
	if not is_instance_valid(store) or not store.has_method("is_sandbox") or not bool(store.call("is_sandbox")):
		if is_instance_valid(_panel):
			_panel.visible = false
		return
	var alerts := collect_alerts(store.city, store.transit_network)
	var signature := _alert_signature(alerts)
	if not force and signature == _signature:
		return
	_signature = signature
	for child in _list.get_children():
		child.queue_free()
	_panel.visible = not alerts.is_empty()
	for index in range(mini(MAX_VISIBLE_ALERTS, alerts.size())):
		var alert: Dictionary = alerts[index]
		var button := Button.new()
		button.text = str(alert.get("label", "NETWORK ISSUE"))
		button.tooltip_text = str(alert.get("tooltip", ""))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size.y = 32.0
		var selection := str(alert.get("selection", ""))
		if not selection.is_empty():
			button.pressed.connect(_select_alert_target.bind(selection))
		else:
			button.disabled = true
		_list.add_child(button)


func _select_alert_target(selection: String) -> void:
	var store := get_node_or_null("/root/GameStore")
	if is_instance_valid(store) and store.has_method("set_selection"):
		store.call("set_selection", selection)


func _alert_signature(alerts: Array[Dictionary]) -> String:
	var parts: Array[String] = []
	for alert in alerts:
		parts.append("%s|%d|%s" % [
			str(alert.get("id", "")),
			int(alert.get("priority", 0)),
			str(alert.get("label", "")),
		])
	return ";".join(parts)
