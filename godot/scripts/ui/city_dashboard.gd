extends Control
class_name CityDashboard

signal closed

const Data = preload("res://scripts/core/game_data.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")

const TABS := ["Overview", "Transport", "Economy", "Residents"]
const ACCENT := Color("#52c9e8")
const POSITIVE := Color("#83df8f")
const NEGATIVE := Color("#ed846e")
const MUTED := Color("#a7b8c7")
const SURFACE := Color(0.075, 0.11, 0.16, 0.96)
const CARD_SURFACE := Color(0.105, 0.15, 0.21, 0.96)

var _panel: PanelContainer
var _title_label: Label
var _subtitle_label: Label
var _close_button: Button
var _tab_buttons: Dictionary = {}
var _scroll: ScrollContainer
var _page: VBoxContainer
var _active_tab := "Overview"
var _refresh_remaining := 0.0
var _store_dirty := true


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_shell()
	visible = false
	if not _game_store().state_changed.is_connected(_on_store_changed):
		_game_store().state_changed.connect(_on_store_changed)
	if not _game_store().city_changed.is_connected(_on_store_changed):
		_game_store().city_changed.connect(_on_store_changed)
	_layout_panel()


func _exit_tree() -> void:
	if is_instance_valid(_game_store()):
		if _game_store().state_changed.is_connected(_on_store_changed):
			_game_store().state_changed.disconnect(_on_store_changed)
		if _game_store().city_changed.is_connected(_on_store_changed):
			_game_store().city_changed.disconnect(_on_store_changed)


func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_remaining -= delta
	if _store_dirty and _refresh_remaining <= 0.0:
		_store_dirty = false
		_refresh_remaining = 1.0
		_render_active_page()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_instance_valid(_panel):
		_layout_panel()


func open_tab(tab_name: String = "Overview") -> void:
	var normalized := tab_name.strip_edges().to_lower()
	for tab in TABS:
		if tab.to_lower() == normalized:
			_active_tab = tab
			break
	visible = true
	_store_dirty = false
	_refresh_remaining = 1.0
	_scroll.scroll_vertical = 0
	_render_active_page()
	_layout_panel()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func get_active_tab_name() -> String:
	return _active_tab


func _game_store():
	return get_node_or_null("/root/GameStore")


func _build_shell() -> void:
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0.015, 0.03, 0.05, 0.48)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	_panel = PanelContainer.new()
	_panel.name = "DashboardPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", _flat_box(SURFACE, Color(0.30, 0.43, 0.54, 0.85), 10, 1))
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "PanelMargin"
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	_panel.add_child(margin)

	var layout := VBoxContainer.new()
	layout.name = "DashboardLayout"
	layout.add_theme_constant_override("separation", 12)
	margin.add_child(layout)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	layout.add_child(header)

	var heading_stack := VBoxContainer.new()
	heading_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading_stack.add_theme_constant_override("separation", 2)
	header.add_child(heading_stack)

	_title_label = Label.new()
	_title_label.text = "CITY MANAGEMENT"
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.add_theme_color_override("font_color", Color("#edf5fb"))
	heading_stack.add_child(_title_label)

	_subtitle_label = Label.new()
	_subtitle_label.text = "LIVE CITY OVERVIEW"
	_subtitle_label.add_theme_font_size_override("font_size", 11)
	_subtitle_label.add_theme_color_override("font_color", ACCENT)
	heading_stack.add_child(_subtitle_label)

	_close_button = Button.new()
	_close_button.name = "CloseButton"
	_close_button.text = "×"
	_close_button.custom_minimum_size = Vector2(38, 38)
	_close_button.add_theme_font_size_override("font_size", 22)
	_close_button.pressed.connect(close)
	header.add_child(_close_button)

	var tabs := HBoxContainer.new()
	tabs.name = "Tabs"
	tabs.add_theme_constant_override("separation", 5)
	layout.add_child(tabs)
	for tab in TABS:
		var button := Button.new()
		button.name = "%sTab" % tab
		button.text = tab.to_upper()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.custom_minimum_size.y = 38
		button.add_theme_font_size_override("font_size", 12)
		button.pressed.connect(_on_tab_pressed.bind(tab))
		tabs.add_child(button)
		_tab_buttons[tab] = button

	var separator := HSeparator.new()
	separator.add_theme_color_override("color", Color(0.36, 0.49, 0.59, 0.62))
	layout.add_child(separator)

	_scroll = ScrollContainer.new()
	_scroll.name = "DashboardScroll"
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(_scroll)

	_page = VBoxContainer.new()
	_page.name = "DashboardPage"
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.add_theme_constant_override("separation", 14)
	_scroll.add_child(_page)


func _layout_panel() -> void:
	if not is_instance_valid(_panel):
		return
	var viewport_size := size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var panel_width := minf(900.0, viewport_size.x - 28.0)
	var panel_height := minf(680.0, viewport_size.y - 28.0)
	_panel.offset_left = -panel_width * 0.5
	_panel.offset_right = panel_width * 0.5
	_panel.offset_top = -panel_height * 0.5
	_panel.offset_bottom = panel_height * 0.5


func _on_tab_pressed(tab: String) -> void:
	open_tab(tab)


func _on_store_changed() -> void:
	_store_dirty = true


func _render_active_page() -> void:
	if not is_instance_valid(_page):
		return
	var scroll_position := _scroll.scroll_vertical
	for child in _page.get_children():
		_page.remove_child(child)
		child.queue_free()
	for tab in TABS:
		var button: Button = _tab_buttons.get(tab)
		if is_instance_valid(button):
			button.add_theme_stylebox_override(
				"normal",
				_flat_box(Color(0.12, 0.19, 0.25, 0.96) if tab == _active_tab else Color(0.09, 0.14, 0.19, 0.84), Color(0.25, 0.36, 0.44, 0.9), 5, 1)
			)
			button.add_theme_stylebox_override("hover", _flat_box(Color(0.16, 0.25, 0.32, 1.0), ACCENT, 5, 1))
			button.add_theme_stylebox_override("pressed", _flat_box(Color(0.08, 0.24, 0.31, 1.0), ACCENT, 5, 1))
			button.add_theme_color_override("font_color", ACCENT if tab == _active_tab else MUTED)
			button.add_theme_color_override("font_hover_color", Color("#f2fbff"))

	_subtitle_label.text = "%s · LIVE CITY DATA" % _active_tab.to_upper()
	match _active_tab:
		"Transport":
			_build_transport_page()
		"Economy":
			_build_economy_page()
		"Residents":
			_build_residents_page()
		_:
			_build_overview_page()
	_scroll.set_deferred("scroll_vertical", scroll_position)


func _build_overview_page() -> void:
	_add_page_heading("City overview", "A live snapshot of the network, treasury, and population.")
	var network := _network_summary()
	var population := _population_count()
	var cards: Array[Dictionary] = [
		{"label": "RESIDENTS", "value": _format_integer(population), "detail": "Current city population", "accent": ACCENT},
		{"label": "ACTIVE ROUTES", "value": str(network.active_routes), "detail": "Routes in service", "accent": POSITIVE},
		{"label": "PASSENGERS / MIN", "value": "%.1f" % network.delivered_ppm, "detail": "Currently carried", "accent": ACCENT},
		{"label": "CITY TREASURY", "value": _format_money(_game_store().money), "detail": "Available funds", "accent": POSITIVE},
	]
	_add_metric_cards(cards)
	_add_section_label("NETWORK AT A GLANCE")
	_add_metric_row("Route stops", _format_integer(network.route_stops), "Stops counted across active routes")
	_add_metric_row("Vehicles in fleet", _format_integer(_game_store().garage_used()), "Purchased vehicles across all routes")
	_add_metric_row("Passengers carried", _format_integer(float(_game_store().stats.get("lifetime_passengers", 0.0))), "Cumulative passengers recorded")


func _build_transport_page() -> void:
	_add_page_heading("Transport network", "Service levels reflect routes and vehicles currently held by the city.")
	var network := _network_summary()
	var cards: Array[Dictionary] = [
		{"label": "ACTIVE ROUTES", "value": str(network.active_routes), "detail": "Routes in service", "accent": POSITIVE},
		{"label": "ROUTE STOPS", "value": _format_integer(network.route_stops), "detail": "Across active routes", "accent": ACCENT},
		{"label": "VEHICLES", "value": str(_game_store().garage_used()), "detail": "Fleet size", "accent": ACCENT},
		{"label": "PASSENGERS / MIN", "value": "%.1f" % network.delivered_ppm, "detail": "Currently carried", "accent": POSITIVE},
	]
	_add_metric_cards(cards)
	_add_section_label("PASSENGER SERVICE")
	_add_metric_row("Waiting passengers", "%.1f" % _waiting_passengers(), "Passengers currently queued at served stops")
	_add_metric_row("Passengers carried", _format_integer(float(_game_store().stats.get("lifetime_passengers", 0.0))), "Cumulative passengers recorded")
	if _game_store().is_sandbox():
		var residents: Dictionary = _game_store().resident_transport_metrics()
		_add_metric_row("Transit mode share", _format_percent(float(residents.get("transit_share", 0.0))), "Resident travel model using current routes and fares")
		_add_metric_row("Expected transit trips / hour", "%.1f" % float(residents.get("expected_transit_trips_per_hour", 0.0)), "Modeled resident trips served per hour")
	else:
		_add_note("Resident mode-choice estimates are available on the Regional Sandbox map.")


func _build_economy_page() -> void:
	var revenue := float(_game_store().stats.get("lifetime_revenue", 0.0))
	var costs := float(_game_store().stats.get("lifetime_operating_costs", 0.0))
	var lifetime_net := revenue - costs
	var economy_value: Variant = _game_store().city.get("economy", {})
	var has_live_economy := (
		_game_store().is_sandbox()
		and typeof(economy_value) == TYPE_DICTIONARY
		and not (economy_value as Dictionary).is_empty()
	)

	if not has_live_economy:
		_add_page_heading("City economy", "Recorded fare revenue and operating costs from the current city state.")
		var legacy_cards: Array[Dictionary] = [
			{"label": "CITY TREASURY", "value": _format_money(_game_store().money), "detail": "Available funds", "accent": POSITIVE},
			{"label": "FARE REVENUE", "value": _format_money(revenue), "detail": "Lifetime recorded", "accent": ACCENT},
			{"label": "OPERATING COSTS", "value": _format_money(costs), "detail": "Lifetime recorded", "accent": NEGATIVE},
			{"label": "OPERATING BALANCE", "value": _format_signed_money(lifetime_net), "detail": "Revenue less recorded costs", "accent": POSITIVE if lifetime_net >= 0.0 else NEGATIVE},
		]
		_add_metric_cards(legacy_cards)
		_add_section_label("RECENT ACTIVITY")
		var latest_fare := float(_game_store().stats.get("last_fare_event_value", 0.0))
		_add_metric_row("Latest fare event", _format_money(latest_fare), "Most recently recorded fare income")
		_add_metric_row("Passengers carried", _format_integer(float(_game_store().stats.get("lifetime_passengers", 0.0))), "Cumulative passengers recorded")
		_add_note("Live Economy V1 forecasting is available on the Regional Sandbox map.")
		return

	var economy: Dictionary = economy_value
	var current_net := float(economy.get("net_per_minute", 0.0))
	var forecast_net := float(economy.get("forecast_net", 0.0))
	var forecast_minutes := float(economy.get("forecast_minutes", 60.0))
	var runway := float(economy.get("runway_minutes", INF))
	var status := str(economy.get("status", "surplus"))
	var runway_text := "∞"
	if is_finite(runway):
		runway_text = "%.0f min" % runway
	var runway_color := POSITIVE
	if status in ["critical", "stressed"]:
		runway_color = NEGATIVE
	elif status == "watch":
		runway_color = Color("#edcf74")

	_add_page_heading("City economy", "Current operating cashflow, cost drivers, forecast and treasury runway from Economy V1.")
	var live_cards: Array[Dictionary] = [
		{"label": "CITY TREASURY", "value": _format_money(_game_store().money), "detail": "Available funds", "accent": POSITIVE if _game_store().money >= 0.0 else NEGATIVE},
		{"label": "CURRENT CASHFLOW", "value": "%s$%.1f/min" % ["+" if current_net >= 0.0 else "−", absf(current_net)], "detail": status.replace("_", " ").to_upper(), "accent": POSITIVE if current_net >= 0.0 else NEGATIVE},
		{"label": "%d MIN FORECAST" % roundi(forecast_minutes), "value": "%s$%.0f" % ["+" if forecast_net >= 0.0 else "−", absf(forecast_net)], "detail": "At current revenue and OPEX rates", "accent": POSITIVE if forecast_net >= 0.0 else NEGATIVE},
		{"label": "TREASURY RUNWAY", "value": runway_text, "detail": "At current negative cashflow" if is_finite(runway) else "No depletion at current cashflow", "accent": runway_color},
	]
	_add_metric_cards(live_cards)

	_add_section_label("CURRENT OPERATING MODEL")
	_add_metric_row("Fare revenue", "$%.2f/min" % float(economy.get("fare_revenue_per_minute", 0.0)), "Current passenger fare income")
	_add_metric_row("Transit OPEX", "$%.2f/min" % float(economy.get("transit_opex_per_minute", 0.0)), "Active fleet operating cost")
	_add_metric_row("Service OPEX", "$%.2f/min" % float(economy.get("service_opex_per_minute", 0.0)), "Player-funded operational service buildings")
	_add_metric_row("Road maintenance", "$%.2f/min" % float(economy.get("road_maintenance_per_minute", 0.0)), "Only player-funded built roads are charged")
	_add_metric_row("Total OPEX", "$%.2f/min" % float(economy.get("total_opex_per_minute", 0.0)), "Transit + services + player-road maintenance")

	_add_section_label("LIFETIME ACCOUNTING")
	_add_metric_row("Fare revenue", _format_money(revenue), "Cumulative recorded fare income")
	_add_metric_row("Operating costs", _format_money(costs), "Cumulative recorded operating costs")
	_add_metric_row("Operating balance", _format_signed_money(lifetime_net), "Lifetime fare revenue less recorded OPEX")
	_add_note("Forecast values are a current-rate projection, not guaranteed future income. Construction CAPEX is paid immediately and is not part of per-minute OPEX.")


func _build_residents_page() -> void:
	_add_page_heading("Residents", "Population and wellbeing indicators from the live city model.")
	if not _game_store().is_sandbox():
		var population := _population_count()
		_add_metric_cards([{"label": "RESIDENTS", "value": _format_integer(population), "detail": "Current city population", "accent": ACCENT}])
		_add_note("Commute, wellbeing, and healthcare estimates are available on the Regional Sandbox map.")
		return

	var transport: Dictionary = _game_store().resident_transport_metrics()
	var health: Dictionary = _game_store().resident_health_metrics()
	var cards: Array[Dictionary] = [
		{"label": "RESIDENTS", "value": _format_integer(float(transport.get("resident_count", 0))), "detail": "Current resident population", "accent": ACCENT},
		{"label": "WELLBEING", "value": "%.0f / 100" % float(transport.get("average_wellbeing", 0.0)), "detail": "Aggregate travel outcome", "accent": _score_color(float(transport.get("average_wellbeing", 0.0)))},
		{"label": "AVERAGE COMMUTE", "value": "%.1f min" % float(transport.get("average_commute_minutes", 0.0)), "detail": "Modeled resident journeys", "accent": ACCENT},
		{"label": "TRANSIT SHARE", "value": _format_percent(float(transport.get("transit_share", 0.0))), "detail": "Modeled daily trips", "accent": POSITIVE},
	]
	_add_metric_cards(cards)
	_add_section_label("CITY HEALTH MODEL")
	_add_metric_row("Health index", "%.0f / 100" % float(health.get("health_index", 0.0)), "Aggregate planning indicator")
	_add_metric_row("Preventable burden", "%.0f / 100" % float(health.get("preventable_burden", 0.0)), "Modeled preventable health burden")
	if bool(health.get("healthcare_data_available", false)):
		var demand := float(health.get("healthcare_demand", 0.0))
		var served := float(health.get("healthcare_served", 0.0))
		var coverage := served / demand if demand > 0.0 else 0.0
		_add_metric_row("Healthcare coverage", _format_percent(coverage), "%s of %.1f modeled demand served" % ["%.1f" % served, demand])
	_add_note("Aggregate game-model estimates based on current transport and service coverage; these are not real-world measurements.")


func _add_page_heading(title: String, description: String) -> void:
	var heading := Label.new()
	heading.text = title
	heading.add_theme_font_size_override("font_size", 17)
	heading.add_theme_color_override("font_color", Color("#f0f6fb"))
	_page.add_child(heading)
	var detail := Label.new()
	detail.text = description
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_theme_color_override("font_color", MUTED)
	_page.add_child(detail)


func _add_metric_cards(cards: Array[Dictionary]) -> void:
	var flow := HFlowContainer.new()
	flow.name = "MetricCards"
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.add_theme_constant_override("h_separation", 9)
	flow.add_theme_constant_override("v_separation", 9)
	_page.add_child(flow)
	for card_value in cards:
		var card: Dictionary = card_value
		var frame := PanelContainer.new()
		frame.custom_minimum_size = Vector2(168, 92)
		frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		frame.add_theme_stylebox_override("panel", _flat_box(CARD_SURFACE, Color(0.27, 0.39, 0.47, 0.78), 6, 1))
		flow.add_child(frame)
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 11)
		margin.add_theme_constant_override("margin_right", 11)
		margin.add_theme_constant_override("margin_top", 9)
		margin.add_theme_constant_override("margin_bottom", 9)
		frame.add_child(margin)
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 3)
		margin.add_child(stack)
		var label := Label.new()
		label.text = str(card.get("label", ""))
		label.add_theme_font_size_override("font_size", 10)
		label.add_theme_color_override("font_color", MUTED)
		stack.add_child(label)
		var value := Label.new()
		value.text = str(card.get("value", "—"))
		value.add_theme_font_size_override("font_size", 20)
		value.add_theme_color_override("font_color", card.get("accent", ACCENT))
		value.clip_text = true
		stack.add_child(value)
		var detail := Label.new()
		detail.text = str(card.get("detail", ""))
		detail.add_theme_font_size_override("font_size", 10)
		detail.add_theme_color_override("font_color", MUTED)
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		stack.add_child(detail)


func _add_section_label(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", ACCENT)
	_page.add_child(label)


func _add_metric_row(label_text: String, value_text: String, detail_text: String = "") -> void:
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _flat_box(Color(0.085, 0.13, 0.18, 0.82), Color(0.24, 0.34, 0.41, 0.62), 5, 1))
	_page.add_child(row)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	row.add_child(margin)
	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	margin.add_child(content)
	var name_stack := VBoxContainer.new()
	name_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_stack.add_theme_constant_override("separation", 2)
	content.add_child(name_stack)
	var name := Label.new()
	name.text = label_text
	name.add_theme_color_override("font_color", Color("#e7eef4"))
	name_stack.add_child(name)
	if not detail_text.is_empty():
		var detail := Label.new()
		detail.text = detail_text
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		detail.add_theme_font_size_override("font_size", 10)
		detail.add_theme_color_override("font_color", MUTED)
		name_stack.add_child(detail)
	var value := Label.new()
	value.text = value_text
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.add_theme_color_override("font_color", Color("#f0f6fb"))
	content.add_child(value)


func _add_note(text: String) -> void:
	var note := Label.new()
	note.text = text
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 10)
	note.add_theme_color_override("font_color", MUTED)
	_page.add_child(note)


func _network_summary() -> Dictionary:
	var active_routes := 0
	var route_stops := 0
	var delivered_ppm := 0.0
	for line_key in Data.LINE_KEYS:
		var line: Dictionary = _game_store().lines.get(line_key, {})
		if not bool(line.get("built", false)):
			continue
		active_routes += 1
		route_stops += int(line.get("stop_count", 0))
		delivered_ppm += float(line.get("last_delivered_ppm", 0.0))
	for line_id in TransitNetwork.custom_line_ids(_game_store().transit_network):
		var line: Dictionary = _game_store().transit_line(line_id)
		if str(line.get("status", "")) != "active":
			continue
		active_routes += 1
		route_stops += _game_store().custom_line_stop_count(line_id)
		delivered_ppm += float(line.get("last_delivered_ppm", 0.0))
	return {
		"active_routes": active_routes,
		"route_stops": route_stops,
		"delivered_ppm": delivered_ppm,
	}


func _population_count() -> float:
	if _game_store().is_sandbox():
		return float(_game_store().resident_transport_metrics().get("resident_count", 0))
	var demographics: Dictionary = _game_store().city.get("demographics", {})
	return float(demographics.get("residents", 0))


func _waiting_passengers() -> float:
	var total := 0.0
	for station_id in Data.all_station_ids():
		total += _game_store().station_waiting_passengers(station_id)
	var custom_stop_ids: Dictionary = {}
	for line_id in TransitNetwork.custom_line_ids(_game_store().transit_network):
		var line: Dictionary = _game_store().transit_line(line_id)
		if str(line.get("status", "")) != "active":
			continue
		for stop_id in TransitNetwork.line_stop_ids(_game_store().transit_network, line_id):
			custom_stop_ids[stop_id] = true
	for stop_id in custom_stop_ids:
		total += _game_store().custom_stop_waiting_passengers(str(stop_id))
	return total


func _flat_box(fill: Color, border: Color, radius: int, border_width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	return style


func _score_color(score: float) -> Color:
	if score >= 70.0:
		return POSITIVE
	if score < 45.0:
		return NEGATIVE
	return Color("#edcf74")


func _format_integer(value: float) -> String:
	return str(roundi(value))


func _format_percent(value: float) -> String:
	return "%.0f%%" % (clampf(value, 0.0, 1.0) * 100.0)


func _format_money(value: float) -> String:
	var magnitude := absf(value)
	var formatted := "%.1fM" % (magnitude / 1000000.0) if magnitude >= 1000000.0 else ("%.1fK" % (magnitude / 1000.0) if magnitude >= 10000.0 else _format_integer(magnitude))
	return ("-$" if value < 0.0 else "$") + formatted


func _format_signed_money(value: float) -> String:
	return ("+" if value >= 0.0 else "−") + _format_money(absf(value))