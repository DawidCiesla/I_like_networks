extends CanvasLayer

const Data = preload("res://scripts/core/game_data.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")
const StatRowScene = preload("res://scenes/ui/inspector_stat_row.tscn")
const LineLegendItemScene = preload("res://scenes/ui/line_legend_item.tscn")

@onready var root_control: Control = $Root
@onready var money_label: Label = $Root/Resources/Content/Money
@onready var income_label: Label = $Root/Resources/Content/Income
@onready var throughput_label: Label = $Root/Resources/Content/Throughput
@onready var status_panel: PanelContainer = $Root/StatusPanel
@onready var progress_label: Label = $Root/StatusPanel/Content/Progress
@onready var objective_label: Label = $Root/StatusPanel/Content/ActionRow/Objective
@onready var legend_panel: PanelContainer = $Root/LineLegend
@onready var legend_rows: VBoxContainer = $Root/LineLegend/Content/Rows
@onready var inspector: PanelContainer = $Root/Inspector
@onready var inspector_eyebrow: Label = $Root/Inspector/Margin/Content/Eyebrow
@onready var inspector_title: Label = $Root/Inspector/Margin/Content/Title
@onready var inspector_body: Label = $Root/Inspector/Margin/Content/Body
@onready var inspector_stat_rows: VBoxContainer = $Root/Inspector/Margin/Content/DetailsScroll/Details/StatRows
@onready var primary_button: Button = $Root/Inspector/Margin/Content/PrimaryButton
@onready var fleet_box: VBoxContainer = $Root/Inspector/Margin/Content/DetailsScroll/Details/FleetButtons
@onready var depot_upgrade_button: Button = $Root/Inspector/Margin/Content/DepotUpgradeButton
@onready var close_button: Button = $Root/Inspector/Margin/Content/CloseButton
@onready var toast_label: Label = $Root/Toast
@onready var pause_button: Button = $Root/StatusPanel/Content/ActionRow/SpeedPanel/Row/Pause
@onready var speed_1_button: Button = $Root/StatusPanel/Content/ActionRow/SpeedPanel/Row/Speed1
@onready var speed_2_button: Button = $Root/StatusPanel/Content/ActionRow/SpeedPanel/Row/Speed2
@onready var speed_4_button: Button = $Root/StatusPanel/Content/ActionRow/SpeedPanel/Row/Speed4
@onready var reset_button: Button = $Root/ResetButton
@onready var import_button: Button = $Root/ImportButton
@onready var hint_label: Label = $Root/Hint

var _import_dialog: FileDialog
var _legend_item_by_line: Dictionary = {}
var _custom_legend_item_by_line: Dictionary = {}
var _create_line_button: Button

var _primary_action := ""
var _primary_payload := ""
var _toast_seconds := 0.0

func _ready() -> void:
	GameStore.state_changed.connect(refresh)
	GameStore.selection_changed.connect(_on_selection_changed)
	GameStore.toast_requested.connect(show_toast)
	GameStore.route_editor_changed.connect(refresh)
	root_control.resized.connect(_layout_hud)

	primary_button.pressed.connect(_on_primary_pressed)
	depot_upgrade_button.pressed.connect(_on_depot_upgrade)
	close_button.pressed.connect(_on_close_pressed)
	pause_button.pressed.connect(_on_pause_pressed)
	speed_1_button.pressed.connect(func(): GameStore.set_speed(1))
	speed_2_button.pressed.connect(func(): GameStore.set_speed(2))
	speed_4_button.pressed.connect(func(): GameStore.set_speed(4))
	reset_button.pressed.connect(_on_reset_pressed)
	import_button.pressed.connect(_on_import_pressed)

	_create_line_button = Button.new()
	_create_line_button.name = "CreateLineButton"
	_create_line_button.text = "CREATE LINE"
	_create_line_button.pressed.connect(_on_create_line_pressed)
	root_control.add_child(_create_line_button)

	_import_dialog = FileDialog.new()
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_import_dialog.filters = PackedStringArray(["*.json ; Browser save JSON"])
	_import_dialog.title = "Import I Like Transit browser save"
	_import_dialog.file_selected.connect(_on_import_file_selected)
	add_child(_import_dialog)

	_create_line_legend()
	_layout_hud()
	refresh()
	_on_selection_changed(GameStore.selected)

func _process(delta: float) -> void:
	if _toast_seconds > 0.0:
		_toast_seconds -= delta
		if _toast_seconds <= 0.0:
			toast_label.visible = false

func refresh() -> void:
	money_label.text = "$%s" % _compact_amount(GameStore.money)
	var last_fare := float(GameStore.stats.get("last_fare_event_value", 0.0))
	income_label.text = "LAST +$%s" % _compact_amount(last_fare) if last_fare > 0.0 else "LAST —"
	var delivered_ppm := 0.0
	for line_key in Data.LINE_KEYS:
		delivered_ppm += float(GameStore.lines[line_key].get("last_delivered_ppm", 0.0))
	for line_id in TransitNetwork.custom_line_ids(GameStore.transit_network):
		var custom_line := GameStore.transit_line(line_id)
		delivered_ppm += float(custom_line.get("last_delivered_ppm", 0.0))
	throughput_label.text = "%.1f PAX/MIN" % delivered_ppm
	_render_objective()
	_render_progress()
	_render_speed()
	_render_line_legend()
	_render_create_line_button()
	_render_inspector()

func _compact_amount(amount: float) -> String:
	var magnitude := absf(amount)
	if magnitude >= 1000000.0:
		return "%.1fM" % (amount / 1000000.0)
	if magnitude >= 10000.0:
		return "%.1fK" % (amount / 1000.0)
	return "%d" % roundi(amount)

func _layout_hud() -> void:
	var width := root_control.size.x
	var height := root_control.size.y
	if width <= 0.0 or height <= 0.0:
		return

	var narrow := width < 1220.0
	var status_width := minf(720.0, width - 540.0) if not narrow else minf(680.0, width - 32.0)
	status_width = maxf(1.0, status_width)
	status_panel.anchor_left = 0.5
	status_panel.anchor_right = 0.5
	status_panel.anchor_top = 0.0
	status_panel.anchor_bottom = 0.0
	status_panel.offset_left = -status_width * 0.5
	status_panel.offset_right = status_width * 0.5
	status_panel.offset_top = 14.0 if not narrow else 124.0
	status_panel.offset_bottom = status_panel.offset_top + 130.0
	var toast_half_width := minf(300.0, maxf(120.0, (width - 32.0) * 0.5))
	toast_label.offset_left = -toast_half_width
	toast_label.offset_right = toast_half_width
	if narrow:
		toast_label.anchor_top = 0.0
		toast_label.anchor_bottom = 0.0
		toast_label.offset_top = status_panel.offset_bottom + 10.0
		toast_label.offset_bottom = status_panel.offset_bottom + 52.0
	else:
		toast_label.anchor_top = 1.0
		toast_label.anchor_bottom = 1.0
		toast_label.offset_top = -146.0
		toast_label.offset_bottom = -104.0

	legend_panel.visible = width >= 1220.0
	if _create_line_button != null:
		_create_line_button.anchor_left = 0.0
		_create_line_button.anchor_right = 0.0
		_create_line_button.anchor_top = 1.0
		_create_line_button.anchor_bottom = 1.0
		_create_line_button.offset_left = 16.0
		_create_line_button.offset_right = 190.0
		_create_line_button.offset_top = -108.0
		_create_line_button.offset_bottom = -66.0

	var inspector_height := minf(500.0, maxf(300.0, height * 0.54))
	if width < 820.0:
		var dock_height := minf(420.0, maxf(230.0, height * 0.46))
		inspector.anchor_left = 0.0
		inspector.anchor_right = 1.0
		inspector.anchor_top = 1.0
		inspector.anchor_bottom = 1.0
		inspector.offset_left = 16.0
		inspector.offset_right = -16.0
		inspector.offset_top = -(dock_height + 64.0)
		inspector.offset_bottom = -64.0
		hint_label.visible = false
	else:
		inspector.anchor_left = 1.0
		inspector.anchor_right = 1.0
		inspector.anchor_top = 1.0
		inspector.anchor_bottom = 1.0
		inspector.offset_left = -360.0
		inspector.offset_right = -16.0
		inspector.offset_top = -(inspector_height + 70.0)
		inspector.offset_bottom = -70.0
		hint_label.visible = width >= 1000.0

func _create_line_legend() -> void:
	for line_key in Data.LINE_KEYS:
		var item := LineLegendItemScene.instantiate()
		var color_swatch: ColorRect = item.get_node("Swatch")
		color_swatch.color = Data.LINE_COLORS[line_key]
		legend_rows.add_child(item)
		_legend_item_by_line[line_key] = item

func _render_line_legend() -> void:
	for line_key in Data.LINE_KEYS:
		var line: Dictionary = GameStore.lines[line_key]
		var item: HBoxContainer = _legend_item_by_line[line_key]
		var label: Label = item.get_node("Label")
		var stop_count := int(line.get("stop_count", 0))
		var max_stops := int(Data.LINE_CONFIG[line_key].max_stops)
		var bus_count := int(line.get("fleet_count", 0))
		var status := "%d/%d STOPS · %d BUS" % [stop_count, max_stops, bus_count]
		if not bool(line.get("built", false)):
			status = "LOCKED" if line_key != "line1" else "1/%d STOPS" % max_stops
		label.text = "L%d  %s" % [Data.line_number(line_key), status]

	var live_custom: Dictionary = {}
	for line_id in TransitNetwork.custom_line_ids(GameStore.transit_network):
		live_custom[line_id] = true
		var item: HBoxContainer = _custom_legend_item_by_line.get(line_id)
		if item == null:
			item = LineLegendItemScene.instantiate()
			item.mouse_filter = Control.MOUSE_FILTER_STOP
			item.gui_input.connect(_on_custom_legend_gui_input.bind(line_id))
			legend_rows.add_child(item)
			_custom_legend_item_by_line[line_id] = item
		var line := GameStore.transit_line(line_id)
		var swatch: ColorRect = item.get_node("Swatch")
		swatch.color = Color(str(line.get("color", "#58b8ff")))
		var label: Label = item.get_node("Label")
		label.text = "%s  %d STOPS · %d BUS" % [
			str(line.get("name", "CUSTOM")),
			TransitNetwork.line_stop_ids(GameStore.transit_network, line_id).size(),
			int(line.get("fleet_count", 0)),
		]

	for line_id_value in _custom_legend_item_by_line.keys():
		var line_id := str(line_id_value)
		if live_custom.has(line_id):
			continue
		var stale: Node = _custom_legend_item_by_line[line_id]
		if is_instance_valid(stale):
			stale.queue_free()
		_custom_legend_item_by_line.erase(line_id)

func _render_create_line_button() -> void:
	if _create_line_button == null:
		return
	_create_line_button.visible = bool(GameStore.depot.get("built", false))
	_create_line_button.disabled = (
		GameStore.route_editor_active()
		or not GameStore.can_begin_free_line()
	)
	_create_line_button.text = "CREATE LINE" if not GameStore.route_editor_active() else "EDITING LINE"

func _on_custom_legend_gui_input(event: InputEvent, line_id: String) -> void:
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and event.pressed
	):
		GameStore.set_selection("free_line:%s" % line_id)

func _built_line_count() -> int:
	var result := 0
	for line_key in Data.LINE_KEYS:
		if bool(GameStore.lines[line_key].built):
			result += 1
	for line_id in TransitNetwork.custom_line_ids(GameStore.transit_network):
		var line := GameStore.transit_line(line_id)
		if str(line.get("status", "")) == "active":
			result += 1
	return result

func _render_speed() -> void:
	pause_button.disabled = false
	pause_button.text = "▶" if GameStore.simulation_speed == 0 else "Ⅱ"
	for button in [speed_1_button, speed_2_button, speed_4_button]:
		button.disabled = false
	match GameStore.simulation_speed:
		1:
			speed_1_button.disabled = true
		2:
			speed_2_button.disabled = true
		4:
			speed_4_button.disabled = true

func _render_objective() -> void:
	if GameStore.route_editor_active():
		var points := GameStore.route_editor_points()
		objective_label.text = (
			"DESIGN LINE · CTRL+CLICK ADDS VIA POINTS · ENTER TO CONFIRM"
			if points.size() >= 2
			else "DESIGN LINE · CLICK BUILT ROADS TO PLACE STOPS"
		)
		return
	if not bool(GameStore.lines.line1.built):
		objective_label.text = "BUY MARKET SQUARE · START BUS LINE 1"
		return
	if GameStore.can_build_depot():
		objective_label.text = "BUS DEPOT UNLOCKED · CLICK ITS GHOST BUILDING"
		return
	if bool(GameStore.depot.get("built", false)):
		var custom_ids := TransitNetwork.custom_line_ids(GameStore.transit_network)
		objective_label.text = (
			"CREATE YOUR OWN BUS LINE · USE THE CREATE LINE BUTTON"
			if custom_ids.is_empty()
			else "EXPAND YOUR NETWORK · CREATE OR EDIT BUS LINES"
		)
		return

	for line_key in Data.LINE_KEYS:
		var line: Dictionary = GameStore.lines[line_key]
		if bool(line.built):
			if int(line.stop_count) < int(Data.LINE_CONFIG[line_key].max_stops):
				objective_label.text = "EXTEND BUS LINE %d · CLICK ITS NEXT GHOST STOP" % Data.line_number(line_key)
				return
			if not GameStore.line_is_stable(line_key) and bool(GameStore.depot.built):
				objective_label.text = "LINE %d IS OVERLOADED · ADD A BUS FROM THE DEPOT" % Data.line_number(line_key)
				return
		elif line_key != "line1" and GameStore.can_unlock_line(line_key):
			objective_label.text = "BUS LINE %d UNLOCKED · CLICK ITS COLORED GHOST BRANCH" % Data.line_number(line_key)
			return

	objective_label.text = "GROW BUS ERA · UPGRADE BUSY STATIONS INTO HUBS"

func _render_progress() -> void:
	if GameStore.route_editor_active():
		var points := GameStore.route_editor_points()
		progress_label.text = "%d STOPS · COST $%d · RMB UNDO · DEL REMOVE" % [
			points.size(),
			int(GameStore.route_editor.get("estimated_cost", 0)),
		]
		return
	if not bool(GameStore.lines.line1.built):
		progress_label.text = "1 / 5 STOPS  ·  START THE FIRST LINE"
		return
	if not bool(GameStore.depot.built):
		var depot_state := "BUILD DEPOT" if GameStore.can_build_depot() else "DEPOT LOCKED"
		progress_label.text = "%d / 5 STOPS  ·  %s" % [int(GameStore.lines.line1.stop_count), depot_state]
		return
	progress_label.text = "%d LINES  ·  %d BUSES  ·  GARAGE %d/%d" % [
		_built_line_count(),
		GameStore.garage_used(),
		GameStore.garage_used(),
		int(GameStore.depot.garage_slots),
	]

func _on_close_pressed() -> void:
	if GameStore.route_editor_active():
		GameStore.cancel_route_editor()
	else:
		GameStore.set_selection("")

func _on_create_line_pressed() -> void:
	GameStore.begin_free_line_editor()

func _on_pause_pressed() -> void:
	GameStore.set_speed(1 if GameStore.simulation_speed == 0 else 0)

func _on_selection_changed(_selection: String) -> void:
	_render_inspector()

func _render_inspector() -> void:
	var selection := GameStore.selected
	_clear_fleet_buttons()
	_clear_stat_rows()
	depot_upgrade_button.visible = false
	primary_button.visible = false
	_primary_action = ""
	_primary_payload = ""
	inspector_eyebrow.text = "OBJECT INSPECTOR"

	if selection.is_empty():
		inspector.visible = false
		return

	inspector.visible = true

	if selection == "route_editor":
		_render_route_editor()
	elif selection.begins_with("free_line:"):
		_render_free_line(selection.trim_prefix("free_line:"))
	elif selection.begins_with("free_stop:"):
		_render_free_stop(selection.trim_prefix("free_stop:"))
	elif selection.begins_with("station:"):
		_render_station(selection.trim_prefix("station:"))
	elif selection.begins_with("future_stop:"):
		_render_future_stop(selection.trim_prefix("future_stop:"))
	elif selection.begins_with("future_line:"):
		_render_future_line(selection.trim_prefix("future_line:"))
	elif selection == "future_depot":
		_render_future_depot()
	elif selection == "depot":
		_render_depot()
	else:
		inspector_title.text = "INSPECTOR"
		inspector_body.text = selection

func _add_stat_row(key: String, value: String) -> void:
	var row := StatRowScene.instantiate()
	var key_label: Label = row.get_node("Key")
	var value_label: Label = row.get_node("Value")
	key_label.text = key.to_upper()
	value_label.text = value
	inspector_stat_rows.add_child(row)

func _clear_stat_rows() -> void:
	for child in inspector_stat_rows.get_children():
		child.queue_free()

func _render_route_editor() -> void:
	var points := GameStore.route_editor_points()
	var waypoints := GameStore.route_editor_waypoints()
	var waypoint_count := 0
	for segment_value in waypoints:
		var segment: Array = segment_value
		waypoint_count += segment.size()
	var mode := str(GameStore.route_editor.get("mode", "new"))
	var selected := int(GameStore.route_editor.get("selected_index", -1))
	inspector_eyebrow.text = "ROUTE DESIGNER"
	inspector_title.text = "NEW BUS LINE" if mode == "new" else "EDIT BUS LINE"
	inspector_body.text = "Click roads to add stops. Select a stop to move or reorder it. Ctrl+click adds a VIA point that forces the route through another street."
	_add_stat_row("Stops", "%d / %d" % [points.size(), TransitNetwork.MAX_CUSTOM_STOPS])
	_add_stat_row("Via points", "%d" % waypoint_count)
	_add_stat_row("Minimum spacing", "%d" % roundi(TransitNetwork.MIN_STOP_SPACING))
	_add_stat_row("Build / edit cost", "$%d" % int(GameStore.route_editor.get("estimated_cost", 0)))
	_add_stat_row("Controls", "CTRL+LMB VIA · CTRL+RMB REMOVE VIA")
	_add_stat_row("Navigate", "MMB PAN · WHEEL ZOOM")
	_add_stat_row("Finish", "ENTER CONFIRM · RMB UNDO · ESC CANCEL")

	if selected >= 0 and selected < points.size():
		var earlier_button := Button.new()
		earlier_button.text = "MOVE STOP EARLIER"
		earlier_button.disabled = selected <= 0
		earlier_button.pressed.connect(
			GameStore.route_editor_reorder_selected.bind(-1)
		)
		fleet_box.add_child(earlier_button)

		var later_button := Button.new()
		later_button.text = "MOVE STOP LATER"
		later_button.disabled = selected >= points.size() - 1
		later_button.pressed.connect(
			GameStore.route_editor_reorder_selected.bind(1)
		)
		fleet_box.add_child(later_button)

		var remove_button := Button.new()
		remove_button.text = "REMOVE SELECTED STOP"
		remove_button.disabled = points.size() <= 2
		remove_button.pressed.connect(GameStore.route_editor_remove_selected)
		fleet_box.add_child(remove_button)

	primary_button.visible = true
	primary_button.disabled = (
		points.size() < 2
		or GameStore.money < float(GameStore.route_editor.get("estimated_cost", 0))
	)
	primary_button.text = "CONFIRM LINE  ·  $%d" % int(GameStore.route_editor.get("estimated_cost", 0))
	_primary_action = "commit_route"

func _render_free_line(line_id: String) -> void:
	var line := GameStore.transit_line(line_id)
	if line.is_empty():
		inspector.visible = false
		return
	var stop_count := TransitNetwork.line_stop_ids(GameStore.transit_network, line_id).size()
	var headway := GameStore.custom_line_headway_minutes(line_id)
	inspector_eyebrow.text = "CUSTOM BUS LINE"
	inspector_title.text = str(line.get("name", line_id)).to_upper()
	inspector_body.text = "A player-designed route following the live road network."
	_add_stat_row("Stops", "%d" % stop_count)
	_add_stat_row("Route", "%.2f KM" % GameStore.custom_line_route_length_km(line_id))
	_add_stat_row("Demand", "%.1f PAX/MIN" % GameStore.custom_line_demand(line_id))
	_add_stat_row("Waiting", "%.1f PAX" % GameStore.custom_line_waiting_passengers(line_id))
	_add_stat_row(
		"Headway",
		("%.1f MIN" % headway) if is_finite(headway) else "NO SERVICE"
	)
	_add_stat_row("Buses", "%d" % int(line.get("fleet_count", 0)))
	primary_button.visible = true
	primary_button.text = "EDIT LINE"
	primary_button.disabled = GameStore.route_editor_active()
	_primary_action = "edit_free_line"
	_primary_payload = line_id

	var add_bus_button := Button.new()
	add_bus_button.text = "BUY BUS  ·  $%d" % GameStore.vehicle_purchase_cost()
	add_bus_button.disabled = (
		GameStore.garage_used() >= int(GameStore.depot.get("garage_slots", 0))
		or GameStore.money < GameStore.vehicle_purchase_cost()
		or int(line.get("fleet_count", 0)) >= int(Data.ECONOMY.max_vehicles_per_line)
	)
	add_bus_button.pressed.connect(GameStore.add_bus_to_transit_line.bind(line_id))
	fleet_box.add_child(add_bus_button)

	var remove_button := Button.new()
	remove_button.text = "REMOVE LINE"
	remove_button.pressed.connect(GameStore.delete_custom_line.bind(line_id))
	fleet_box.add_child(remove_button)

func _render_free_stop(stop_id: String) -> void:
	var stop := GameStore.transit_stop(stop_id)
	if stop.is_empty():
		inspector.visible = false
		return
	var stats := GameStore.custom_stop_catchment(stop_id)
	var served: Array = stop.get("served_line_ids", [])
	var served_names: Array[String] = []
	for line_id_value in served:
		var line_id := str(line_id_value)
		var line := GameStore.transit_line(line_id)
		served_names.append(str(line.get("name", line_id)))
	inspector_eyebrow.text = "FREE-FORM STOP"
	inspector_title.text = str(stop.get("name", stop_id)).to_upper()
	inspector_body.text = (
		" + ".join(served_names)
		if not served_names.is_empty()
		else "NO ACTIVE SERVICE"
	)
	_add_stat_row("Catchment", "%d" % roundi(float(stats.get("radius", 0.0))))
	_add_stat_row("Buildings", "%d" % int(stats.get("building_count", 0)))
	_add_stat_row("Demand", "%.1f PAX/MIN" % float(stats.get("demand_ppm", 0.0)))
	_add_stat_row("Waiting", "%.1f PAX" % GameStore.custom_stop_waiting_passengers(stop_id))
	_add_stat_row("Overlapping stops", "%d" % int(stats.get("overlap_count", 0)))
	for line_id_value in served:
		var line_id := str(line_id_value)
		var line := GameStore.transit_line(line_id)
		if str(line.get("source", "")) != "custom":
			continue
		var open_line_button := Button.new()
		open_line_button.text = "OPEN %s" % str(line.get("name", line_id)).to_upper()
		open_line_button.pressed.connect(
			GameStore.set_selection.bind("free_line:%s" % line_id)
		)
		fleet_box.add_child(open_line_button)
	var level := int(stop.get("level", 0))
	_add_stat_row("Level", "%d / %d" % [level, int(Data.STATION_UPGRADE.max_level)])
	if level < int(Data.STATION_UPGRADE.max_level):
		primary_button.visible = true
		primary_button.disabled = GameStore.money < GameStore.custom_stop_upgrade_cost(stop_id)
		primary_button.text = "UPGRADE STOP  ·  $%d" % GameStore.custom_stop_upgrade_cost(stop_id)
		_primary_action = "upgrade_free_stop"
		_primary_payload = stop_id

func _render_station(station_id: String) -> void:
	var served := GameStore.station_served_lines(station_id)
	var served_text: Array[String] = []
	for line_key in served:
		served_text.append("L%d" % Data.line_number(line_key))

	var level := GameStore.station_level(station_id)
	inspector_eyebrow.text = "STATION · LEVEL %d" % (level + 1)
	inspector_title.text = Data.station_name(station_id).to_upper()
	inspector_body.text = "%s · %s" % [
		GameStore.station_tier(station_id).to_upper(),
		" + ".join(served_text) if not served_text.is_empty() else "NO SERVICE",
	]
	_add_stat_row("Waiting", "%.1f PAX" % GameStore.station_waiting_passengers(station_id))
	_add_stat_row("Queue capacity", "%d PAX / LINE" % GameStore.station_capacity(station_id))
	_add_stat_row("Upgrade", "%d / %d" % [level, int(Data.STATION_UPGRADE.max_level)])

	if level < int(Data.STATION_UPGRADE.max_level):
		_add_stat_row("Next tier", str(Data.STATION_UPGRADE.tier_names[level + 1]).to_upper())
		primary_button.visible = true
		primary_button.disabled = GameStore.money < GameStore.station_upgrade_cost(station_id)
		primary_button.text = "UPGRADE TO %s  ·  $%d" % [
			Data.STATION_UPGRADE.tier_names[level + 1].to_upper(),
			GameStore.station_upgrade_cost(station_id),
		]
		_primary_action = "upgrade_station"
		_primary_payload = station_id

func _render_future_stop(line_key: String) -> void:
	var line: Dictionary = GameStore.lines[line_key]
	var stop_index := int(line.stop_count)
	var station_id: String = Data.STATION_IDS[line_key][stop_index]
	var cost := GameStore.next_stop_cost(line_key)
	inspector_eyebrow.text = "LINE %d · NEXT STOP" % Data.line_number(line_key)
	inspector_title.text = Data.station_name(station_id).to_upper()
	inspector_body.text = "Connect a physical interchange." if GameStore.station_is_built(station_id) else "Build a new stop for this route."
	_add_stat_row("Route", "LINE %d" % Data.line_number(line_key))
	_add_stat_row("Stop type", "EXISTING INTERCHANGE" if GameStore.station_is_built(station_id) else "NEW STATION")
	_add_stat_row("Stop", "%d / %d" % [stop_index + 1, int(Data.LINE_CONFIG[line_key].max_stops)])
	primary_button.visible = true
	primary_button.disabled = GameStore.money < cost
	primary_button.text = "BUILD / CONNECT  ·  $%d" % cost
	_primary_action = "build_stop"
	_primary_payload = line_key

func _render_future_line(line_key: String) -> void:
	var cost := GameStore.line_build_cost(line_key)
	inspector_eyebrow.text = "NEW ROUTE · LINE %d" % Data.line_number(line_key)
	inspector_title.text = "BUS LINE %d" % Data.line_number(line_key)
	inspector_body.text = "%s → %s" % [
		Data.STOP_NAMES[line_key][0],
		Data.STOP_NAMES[line_key][1],
	]
	_add_stat_row("Starting fleet", "1 BUS")
	_add_stat_row("Starting stops", "2")
	_add_stat_row("Demand / stop", "%.1f PAX/MIN" % float(Data.LINE_CONFIG[line_key].demand_per_stop_ppm))
	primary_button.visible = true
	primary_button.disabled = GameStore.money < cost or not GameStore.can_unlock_line(line_key)
	primary_button.text = "OPEN LINE %d  ·  $%d" % [Data.line_number(line_key), cost]
	_primary_action = "build_line"
	_primary_payload = line_key

func _render_future_depot() -> void:
	var cost := int(Data.ECONOMY.depot_build_cost)
	inspector_eyebrow.text = "TRANSPORT FACILITY"
	inspector_title.text = "BUS DEPOT"
	inspector_body.text = "A shared garage for the active bus network."
	_add_stat_row("Starting capacity", "4 BUSES")
	_add_stat_row("Build cost", "$%s" % _compact_amount(cost))
	primary_button.visible = true
	primary_button.disabled = GameStore.money < cost
	primary_button.text = "BUILD DEPOT  ·  $%d" % cost
	_primary_action = "build_depot"

func _render_depot() -> void:
	inspector_eyebrow.text = "TRANSPORT FACILITY"
	inspector_title.text = "BUS DEPOT"
	inspector_body.text = "Buy buses for open lines or expand the garage."
	_add_stat_row("Garage", "%d / %d BUSES" % [GameStore.garage_used(), int(GameStore.depot.garage_slots)])
	_add_stat_row("Next bus", "$%s" % _compact_amount(GameStore.vehicle_purchase_cost()))

	for line_key in Data.LINE_KEYS:
		if not bool(GameStore.lines[line_key].built):
			continue
		var button := Button.new()
		button.text = "BUY BUS FOR LINE %d  ·  $%d" % [
			Data.line_number(line_key),
			GameStore.vehicle_purchase_cost(),
		]
		button.disabled = (
			GameStore.garage_used() >= int(GameStore.depot.garage_slots)
			or int(GameStore.lines[line_key].fleet_count) >= int(Data.ECONOMY.max_vehicles_per_line)
			or GameStore.money < GameStore.vehicle_purchase_cost()
		)
		button.pressed.connect(_buy_bus.bind(line_key))
		fleet_box.add_child(button)

	for line_id in TransitNetwork.custom_line_ids(GameStore.transit_network):
		var line := GameStore.transit_line(line_id)
		var button := Button.new()
		button.text = "BUY BUS FOR %s  ·  $%d" % [
			str(line.get("name", line_id)).to_upper(),
			GameStore.vehicle_purchase_cost(),
		]
		button.disabled = (
			GameStore.garage_used() >= int(GameStore.depot.garage_slots)
			or int(line.get("fleet_count", 0)) >= int(Data.ECONOMY.max_vehicles_per_line)
			or GameStore.money < GameStore.vehicle_purchase_cost()
		)
		button.pressed.connect(GameStore.add_bus_to_transit_line.bind(line_id))
		fleet_box.add_child(button)

	var upgrade_cost := roundi(
		float(Data.ECONOMY.depot_upgrade_base_cost)
		* pow(float(Data.ECONOMY.depot_upgrade_cost_growth), int(GameStore.depot.level))
	)
	depot_upgrade_button.visible = true
	depot_upgrade_button.disabled = GameStore.money < upgrade_cost
	depot_upgrade_button.text = "EXPAND GARAGE +4  ·  $%d" % upgrade_cost

func _on_primary_pressed() -> void:
	match _primary_action:
		"upgrade_station":
			GameStore.upgrade_station(_primary_payload)
		"build_stop":
			var line_key := _primary_payload
			if GameStore.build_next_stop(line_key):
				var index := int(GameStore.lines[line_key].stop_count) - 1
				GameStore.set_selection("station:%s" % Data.STATION_IDS[line_key][index])
		"build_line":
			var line_key := _primary_payload
			if GameStore.build_line(line_key):
				GameStore.set_selection("station:%s" % Data.STATION_IDS[line_key][1])
		"build_depot":
			if GameStore.build_depot():
				GameStore.set_selection("depot")
		"commit_route":
			GameStore.commit_route_editor()
		"edit_free_line":
			GameStore.begin_edit_line_editor(_primary_payload)
		"upgrade_free_stop":
			GameStore.upgrade_custom_stop(_primary_payload)

func _buy_bus(line_key: String) -> void:
	GameStore.add_bus(line_key)

func _on_depot_upgrade() -> void:
	GameStore.upgrade_depot()

func _clear_fleet_buttons() -> void:
	for child in fleet_box.get_children():
		child.queue_free()

func show_toast(message: String) -> void:
	toast_label.text = message
	toast_label.visible = true
	_toast_seconds = 3.0

func _on_reset_pressed() -> void:
	GameStore.clear_save_and_reset()
	GameStore.set_selection("")
	show_toast("Game reset to the first stop.")


func _on_import_pressed() -> void:
	_import_dialog.popup_centered_ratio(0.72)

func _on_import_file_selected(path: String) -> void:
	if GameStore.import_browser_save(path):
		GameStore.set_selection("")
