extends CanvasLayer
class_name RegionalLineOperationsWidget

const Data = preload("res://scripts/core/game_data.gd")
const TransitModes = preload("res://scripts/transport/transit_modes.gd")
const RegionalFleetManagement = preload("res://scripts/simulation/regional_fleet_management.gd")

const REFRESH_SECONDS := 0.4

var _panel: PanelContainer
var _title: Label
var _summary: Label
var _health: Label
var _buy_button: Button
var _retire_button: Button
var _line_id := ""
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
	_panel.name = "RegionalLineOperations"
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_panel.offset_left = -382.0
	_panel.offset_right = -18.0
	_panel.offset_top = -184.0
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
	stack.add_theme_constant_override("separation", 6)
	margin.add_child(stack)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 13)
	stack.add_child(_title)

	_summary = Label.new()
	_summary.add_theme_font_size_override("font_size", 11)
	stack.add_child(_summary)

	_health = Label.new()
	_health.add_theme_font_size_override("font_size", 10)
	_health.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_health)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	stack.add_child(actions)

	_buy_button = Button.new()
	_buy_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_buy_button.custom_minimum_size.y = 34.0
	_buy_button.pressed.connect(_on_buy_pressed)
	actions.add_child(_buy_button)

	_retire_button = Button.new()
	_retire_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_retire_button.custom_minimum_size.y = 34.0
	_retire_button.pressed.connect(_on_retire_pressed)
	actions.add_child(_retire_button)

	_panel.visible = false


func _refresh() -> void:
	var store := get_node_or_null("/root/GameStore")
	if not is_instance_valid(store) or not store.has_method("is_sandbox") or not bool(store.call("is_sandbox")):
		_panel.visible = false
		_line_id = ""
		return
	var selection := str(store.get("selected"))
	if not selection.begins_with("free_line:"):
		_panel.visible = false
		_line_id = ""
		return
	var line_id := selection.trim_prefix("free_line:")
	var lines_value: Variant = store.transit_network.get("lines", {})
	if typeof(lines_value) != TYPE_DICTIONARY:
		_panel.visible = false
		return
	var lines: Dictionary = lines_value
	var line_value: Variant = lines.get(line_id, {})
	if typeof(line_value) != TYPE_DICTIONARY:
		_panel.visible = false
		return
	var line: Dictionary = line_value
	if str(line.get("source", "")) != "custom":
		_panel.visible = false
		return

	_line_id = line_id
	_panel.visible = true
	var mode := str(line.get("mode", "bus"))
	var fleet := int(line.get("fleet_count", 0))
	var pending := RegionalFleetManagement.pending_retirements(line)
	var headway := float(line.get("traffic_effective_headway_minutes", INF))
	if not is_finite(headway) and store.has_method("custom_line_headway_minutes"):
		headway = float(store.call("custom_line_headway_minutes", line_id))
	var delay_factor := maxf(1.0, float(line.get("traffic_delay_factor", 1.0)))
	var health_value: Variant = line.get("operations_health", {})
	var health: Dictionary = health_value if typeof(health_value) == TYPE_DICTIONARY else {}
	var load_ratio := float(health.get("effective_load_ratio", line.get("crowding_ratio", 0.0)))
	var profile := TransitModes.profile(mode)
	var fare_per_minute := (
		maxf(0.0, float(line.get("last_delivered_ppm", 0.0)))
		* float(Data.ECONOMY["fare_per_passenger"])
	)
	var opex_per_minute := (
		float(fleet)
		* maxf(0.0, float(profile.get("operating_cost_multiplier", 1.0)))
		* float(Data.ECONOMY["sandbox_operating_cost_per_bus_minute"])
	)
	var net_per_minute := fare_per_minute - opex_per_minute

	_title.text = "LINE OPERATIONS · %s" % str(line.get("name", line_id)).to_upper()
	_summary.text = "Fleet %d%s · headway %s · load %.0f%% · traffic ×%.2f" % [
		fleet,
		" (%d retiring)" % pending if pending > 0 else "",
		"—" if not is_finite(headway) else "%.1f min" % headway,
		load_ratio * 100.0,
		delay_factor,
	]
	var status := str(health.get("status", "monitor"))
	var recommendation := str(health.get("recommended_action", "monitor")).replace("_", " ")
	_health.text = "OPS %s$%.1f/min · fares $%.1f · cost $%.1f · %s · %s" % [
		"+" if net_per_minute >= 0.0 else "−",
		absf(net_per_minute),
		fare_per_minute,
		opex_per_minute,
		status.replace("_", " ").to_upper(),
		recommendation,
	]

	var vehicle_name := _vehicle_name(mode)
	var cost := 0
	if store.has_method("transit_vehicle_purchase_cost"):
		cost = int(store.call("transit_vehicle_purchase_cost", line_id))
	_buy_button.text = "BUY %s · $%d" % [vehicle_name.to_upper(), cost]
	_buy_button.disabled = (
		fleet >= int(Data.ECONOMY["max_vehicles_per_line"])
		or float(store.money) < float(cost)
		or int(store.call("garage_used")) >= int(store.depot.get("garage_slots", 0))
	)

	var retirement := RegionalFleetManagement.retirement_status(store, line_id)
	if pending > 0:
		_retire_button.text = "CANCEL RETIREMENT"
		_retire_button.disabled = false
		_retire_button.tooltip_text = "%d vehicle(s) will otherwise leave service empty at a terminus." % pending
	else:
		_retire_button.text = "RETIRE 1 %s" % vehicle_name.to_upper()
		_retire_button.disabled = not bool(retirement.get("available", false))
		_retire_button.tooltip_text = (
			"Vehicle retires only when empty at a route terminus. No resale refund in V1."
			if not _retire_button.disabled
			else str(retirement.get("reason", "unavailable")).replace("_", " ")
		)


func _on_buy_pressed() -> void:
	var store := get_node_or_null("/root/GameStore")
	if _line_id.is_empty() or not is_instance_valid(store) or not store.has_method("add_vehicle_to_transit_line"):
		return
	store.call("add_vehicle_to_transit_line", _line_id)
	_refresh_remaining = 0.0


func _on_retire_pressed() -> void:
	var store := get_node_or_null("/root/GameStore")
	if _line_id.is_empty() or not is_instance_valid(store):
		return
	var lines_value: Variant = store.transit_network.get("lines", {})
	if typeof(lines_value) != TYPE_DICTIONARY:
		return
	var line_value: Variant = (lines_value as Dictionary).get(_line_id, {})
	if typeof(line_value) != TYPE_DICTIONARY:
		return
	var line: Dictionary = line_value
	var changed := false
	if RegionalFleetManagement.pending_retirements(line) > 0:
		changed = RegionalFleetManagement.cancel_retirements(store, _line_id)
	else:
		changed = RegionalFleetManagement.schedule_retirement(store, _line_id)
	if changed:
		if store.has_method("save_game"):
			store.call("save_game")
		if store.has_signal("state_changed"):
			store.emit_signal("state_changed")
	_refresh_remaining = 0.0


func _vehicle_name(mode: String) -> String:
	match mode:
		"tram":
			return "tram"
		"metro":
			return "train"
		_:
			return "bus"