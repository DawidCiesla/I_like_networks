extends CanvasLayer

const CityUIIcons = preload("res://scripts/ui/city_ui_icons.gd")
const CityUITheme = preload("res://scripts/ui/city_ui_theme.gd")
const Data = preload("res://scripts/core/game_data.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")
const SandboxProgression = preload("res://scripts/city/sandbox_progression.gd")
const StatRowScene = preload("res://scenes/ui/inspector_stat_row.tscn")
const LineLegendItemScene = preload("res://scenes/ui/line_legend_item.tscn")
const TERRAIN_TOOL_MODES := ["", "raise", "lower", "flatten", "smooth"]

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
@onready var save_copy_button: Button = $Root/SaveCopyButton
@onready var hint_label: Label = $Root/Hint

var _import_dialog: FileDialog
var _save_copy_dialog: FileDialog
var _reset_confirmation: ConfirmationDialog
var _legend_item_by_line: Dictionary = {}
var _custom_legend_item_by_line: Dictionary = {}
var _create_line_button: Button
var _transit_mode_button: Button
var _terrain_tool_button: Button
var _road_builder_button: Button
var _depot_placement_button: Button
var _world_build_tools_signature := ""
var _cached_built_road_count := -1
var _cached_built_road_available := false

var _toolbar: PanelContainer
var _footer: Panel
var _tool_tray: PanelContainer
var _toolbar_buttons: Dictionary = {}
var _tool_category := ""
var _population_label: Label
var _region_label: Label
var _guidance_panel: PanelContainer
var _guidance_label: Label
var _dashboard: Control

var _primary_action := ""
var _primary_payload := ""
var _toast_seconds := 0.0
var _refresh_requested := false
var _refresh_elapsed := 0.0

func _ready() -> void:
	GameStore.state_changed.connect(_request_refresh)
	GameStore.selection_changed.connect(_on_selection_changed)
	GameStore.toast_requested.connect(show_toast)
	GameStore.route_editor_changed.connect(refresh)
	GameStore.city_changed.connect(_invalidate_built_road_cache)
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
	save_copy_button.pressed.connect(_on_save_copy_pressed)

	_create_line_button = Button.new()
	_create_line_button.name = "CreateLineButton"
	_create_line_button.text = "CREATE LINE"
	_create_line_button.pressed.connect(_on_create_line_pressed)
	root_control.add_child(_create_line_button)

	_transit_mode_button = Button.new()
	_transit_mode_button.name = "TransitModeButton"
	_transit_mode_button.pressed.connect(_on_transit_mode_pressed)
	root_control.add_child(_transit_mode_button)

	_terrain_tool_button = Button.new()
	_terrain_tool_button.name = "TerrainToolButton"
	_terrain_tool_button.pressed.connect(_on_terrain_tool_pressed)
	root_control.add_child(_terrain_tool_button)

	_road_builder_button = Button.new()
	_road_builder_button.name = "RoadBuilderButton"
	_road_builder_button.pressed.connect(_on_road_builder_pressed)
	root_control.add_child(_road_builder_button)

	_depot_placement_button = Button.new()
	_depot_placement_button.name = "DepotPlacementButton"
	_depot_placement_button.pressed.connect(_on_depot_placement_pressed)
	root_control.add_child(_depot_placement_button)

	_import_dialog = FileDialog.new()
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_import_dialog.filters = PackedStringArray(["*.json,*.bak ; I Like Transit or browser save"])
	_import_dialog.title = "Load I Like Transit or browser save"
	_import_dialog.file_selected.connect(_on_import_file_selected)
	add_child(_import_dialog)

	_save_copy_dialog = FileDialog.new()
	_save_copy_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_copy_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_save_copy_dialog.filters = PackedStringArray(["*.json ; I Like Transit save"])
	_save_copy_dialog.title = "Save a copy of this city"
	_save_copy_dialog.file_selected.connect(_on_save_copy_file_selected)
	add_child(_save_copy_dialog)

	_reset_confirmation = ConfirmationDialog.new()
	_reset_confirmation.title = "Start a new regional sandbox?"
	_reset_confirmation.dialog_text = "This replaces the current autosave with a new region. Choose SAVE COPY first if you want to keep this city."
	_reset_confirmation.confirmed.connect(_on_reset_confirmed)
	add_child(_reset_confirmation)

	_create_line_legend()
	_build_city_shell()
	_layout_hud()
	refresh()
	_on_selection_changed(GameStore.selected)

func _request_refresh() -> void:
	_refresh_requested = true

func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_requested and _refresh_elapsed >= 0.2:
		_refresh_requested = false
		_refresh_elapsed = 0.0
		refresh()
	_render_world_build_tool_buttons()
	_apply_tool_category()
	if _toast_seconds > 0.0:
		_toast_seconds -= delta
		if _toast_seconds <= 0.0:
			toast_label.visible = false

func refresh() -> void:
	money_label.text = "$%s" % _compact_amount(GameStore.money)
	var total_net := float(GameStore.stats.get("lifetime_revenue", 0.0)) - float(GameStore.stats.get("lifetime_operating_costs", 0.0))
	income_label.text = "TOTAL NET $%s" % _compact_amount(total_net)
	var delivered_ppm := 0.0
	if not GameStore.is_sandbox():
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
	_render_terrain_tool_button()
	_render_world_build_tool_buttons()
	_render_inspector()
	_refresh_city_shell()

func _compact_amount(amount: float) -> String:
	var magnitude := absf(amount)
	if magnitude >= 1000000.0:
		return "%.1fM" % (amount / 1000000.0)
	if magnitude >= 10000.0:
		return "%.1fK" % (amount / 1000.0)
	return "%d" % roundi(amount)

func _build_city_shell() -> void:
	root_control.theme = CityUITheme.create_theme()
	_footer = Panel.new()
	_footer.name = "CityStatusBar"
	_footer.mouse_filter = Control.MOUSE_FILTER_STOP
	root_control.add_child(_footer)
	root_control.move_child(_footer, 0)
	_toolbar = PanelContainer.new()
	_toolbar.name = "CityToolbar"
	root_control.add_child(_toolbar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_toolbar.add_child(row)
	var rail_style := CityUITheme.create_accent_panel_style()
	rail_style.content_margin_top = 4
	rail_style.content_margin_bottom = 4
	_toolbar.add_theme_stylebox_override("panel", rail_style)
	root_control.get_node("StatusPanel/Content/ActionRow/SpeedPanel").add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	status_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	root_control.get_node("Resources").add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var title := Label.new()
	title.text = "I LIKE TRANSIT"
	title.custom_minimum_size.x = 170
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color("b7d8df"))
	row.add_child(title)
	for entry in [["overview", "Region"], ["roads", "Roads"], ["transport", "Transport"], ["terrain", "Landscape"], ["economy", "Economy"], ["residents", "Residents"], ["saves", "Save / Load"]]:
		var key := str(entry[0])
		var button := Button.new()
		button.name = key.capitalize() + "Category"
		button.text = ""
		button.icon = CityUIIcons.texture(key)
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 28)
		button.alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(48, 40)
		var normal := StyleBoxFlat.new()
		normal.bg_color = Color(0, 0, 0, 0)
		normal.set_content_margin_all(6)
		button.add_theme_stylebox_override("normal", normal)
		button.tooltip_text = "Open %s tools and information" % str(entry[1]).to_lower()
		button.pressed.connect(_on_category_pressed.bind(key))
		row.add_child(button)
		_toolbar_buttons[key] = button
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var rail_hint := Label.new()
	rail_hint.text = "REGIONAL TRANSPORT"
	rail_hint.add_theme_font_size_override("font_size", 11)
	rail_hint.add_theme_color_override("font_color", Color("859aa8"))
	row.add_child(rail_hint)
	_tool_tray = PanelContainer.new()
	_tool_tray.name = "ToolTray"
	_tool_tray.mouse_filter = Control.MOUSE_FILTER_STOP
	root_control.add_child(_tool_tray)
	root_control.move_child(_tool_tray, 0)
	_population_label = Label.new()
	_population_label.name = "Population"
	_population_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_population_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_population_label.tooltip_text = "Residents currently living in this region"
	root_control.add_child(_population_label)
	_region_label = Label.new()
	_region_label.name = "RegionName"
	_region_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root_control.add_child(_region_label)
	_guidance_panel = PanelContainer.new()
	_guidance_panel.name = "ContextGuidance"
	root_control.add_child(_guidance_panel)
	_guidance_label = Label.new()
	_guidance_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_guidance_label.add_theme_font_size_override("font_size", 12)
	_guidance_panel.add_child(_guidance_label)
	var dashboard_script := load("res://scripts/ui/city_dashboard.gd")
	if dashboard_script != null:
		_dashboard = dashboard_script.new()
		_dashboard.name = "CityDashboard"
		root_control.add_child(_dashboard)
		_dashboard.visible = false
		_dashboard.connect("closed", _on_dashboard_closed)
	for label in [money_label, income_label, throughput_label]:
		label.add_theme_font_size_override("font_size", 13)
		label.custom_minimum_size.x = 120
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var chip := StyleBoxFlat.new()
		chip.bg_color = Color("111e29")
		chip.set_corner_radius_all(5)
		chip.content_margin_left = 8
		chip.content_margin_right = 8
		label.add_theme_stylebox_override("normal", chip)
	money_label.add_theme_color_override("font_color", Color("b7e87e"))
	income_label.add_theme_color_override("font_color", Color("76cbd5"))
	objective_label.visible = false
	progress_label.visible = false

func _on_dashboard_closed() -> void:
	_tool_category = ""
	_refresh_city_shell()
	_layout_hud()

func _on_category_pressed(category: String) -> void:
	_tool_category = "" if _tool_category == category else category
	if _tool_category != "roads" and GameStore.road_builder_active():
		GameStore.cancel_road_builder()
	if _tool_category != "transport" and GameStore.depot_placement_active():
		GameStore.cancel_depot_placement()
	if _tool_category != "terrain" and not str(GameStore.terrain_tool_mode).is_empty():
		GameStore.set_terrain_tool_mode("")
	if _dashboard != null:
		if _tool_category in ["overview", "economy", "residents"]:
			_dashboard.call("open_tab", _tool_category)
		else:
			_dashboard.visible = false
	_refresh_city_shell()
	_layout_hud()

func _apply_tool_category() -> void:
	if _toolbar == null:
		return
	_create_line_button.visible = _create_line_button.visible and _tool_category == "transport"
	_transit_mode_button.visible = _transit_mode_button.visible and _tool_category == "transport"
	_depot_placement_button.visible = _depot_placement_button.visible and _tool_category == "transport"
	_road_builder_button.visible = _road_builder_button.visible and _tool_category == "roads"
	_terrain_tool_button.visible = _tool_category == "terrain"
	for button in [import_button, save_copy_button, reset_button]:
		button.visible = _tool_category == "saves"
	_tool_tray.visible = _tool_category in ["transport", "roads", "terrain", "saves"]
	for key in _toolbar_buttons:
		(_toolbar_buttons[key] as Button).set_pressed_no_signal(key == _tool_category)
	(_toolbar_buttons["roads"] as Button).disabled = not _is_sandbox_map()
	legend_panel.visible = _tool_category == "transport" and root_control.size.x >= 900.0

func _refresh_city_shell() -> void:
	if _toolbar == null:
		return
	# Recompute source visibility before applying the category filter.
	_render_create_line_button()
	_render_world_build_tool_buttons()
	_apply_tool_category()
	_guidance_label.text = objective_label.text
	_guidance_panel.tooltip_text = objective_label.text
	_guidance_panel.visible = not inspector.visible and (_dashboard == null or not _dashboard.visible)
	var population := 0.0
	if GameStore.is_sandbox():
		population = float(_resident_transport_metrics().get("resident_count", 0.0))
	else:
		for district in GameStore.city.get("districts", []):
			population += float(district.get("population", 0.0))
	_population_label.text = "POPULATION  %s" % _compact_amount(population)
	var minutes := int(480.0 + float(GameStore.city.get("time_seconds", 0.0)) / 60.0) % 1440
	_region_label.text = "%02d:%02d  ·  I LIKE TRANSIT" % [minutes / 60, minutes % 60]
	_region_label.tooltip_text = "Region seed: %d" % GameStore.city_seed
	_population_label.tooltip_text = progress_label.text
	income_label.tooltip_text = "Lifetime fares $%s · operating costs $%s" % [_compact_amount(float(GameStore.stats.get("lifetime_revenue", 0.0))), _compact_amount(float(GameStore.stats.get("lifetime_operating_costs", 0.0)))]

func _place_control(control: Control, rect: Rect2) -> void:
	control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	control.position = rect.position
	control.size = rect.size

func _layout_hud() -> void:
	var width := root_control.size.x
	var height := root_control.size.y
	if width <= 0.0 or height <= 0.0 or _toolbar == null:
		return
	var dock_top := height - 92.0
	_place_control(_toolbar, Rect2(0, dock_top, width, 52))
	_place_control(_footer, Rect2(0, height - 40, width, 40))
	_place_control(status_panel, Rect2(8, height - 38, 198, 36))
	_place_control(root_control.get_node("Resources"), Rect2(width - 460, height - 36, 450, 32))
	_place_control(_region_label, Rect2(214, height - 36, 210, 32))
	_place_control(_population_label, Rect2(430, height - 36, maxf(0, width - 904), 32))
	_region_label.visible = width >= 900
	_population_label.visible = width >= 1200
	var tray_buttons: Array[Control] = []
	match _tool_category:
		"transport": tray_buttons = [_depot_placement_button, _transit_mode_button, _create_line_button]
		"roads": tray_buttons = [_road_builder_button]
		"terrain": tray_buttons = [_terrain_tool_button]
		"saves": tray_buttons = [import_button, save_copy_button, reset_button]
	var tray_width := minf(width - 32, 640.0)
	_place_control(_tool_tray, Rect2((width - tray_width) * 0.5, dock_top - 66, tray_width, 58))
	var slot_width := (tray_width - 24.0) / maxi(1, tray_buttons.size())
	for index in range(tray_buttons.size()):
		_place_control(tray_buttons[index], Rect2((width - tray_width) * 0.5 + 12 + index * slot_width, dock_top - 58, slot_width - 6, 42))
	_place_control(_guidance_panel, Rect2(16, 16, minf(470, width - 32), 38))
	_place_control(legend_panel, Rect2(width - 256, 16, 240, minf(320, height - 160)))
	var inspector_width := minf(360, width - 32)
	_place_control(inspector, Rect2(16, 16, inspector_width, minf(540, height - 240)))
	_place_control(hint_label, Rect2(16, dock_top - (98 if _tool_tray.visible else 28), minf(620, width - 32), 22))
	hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_label.visible = width >= 900
	_place_control(toast_label, Rect2(maxf(16, (width - 600) * 0.5), 16, minf(600, width - 32), 42))
	if _dashboard != null:
		_place_control(_dashboard, Rect2(0, 0, width, dock_top - 4))

func _create_line_legend() -> void:
	for line_key in Data.LINE_KEYS:
		var item := LineLegendItemScene.instantiate()
		var color_swatch: ColorRect = item.get_node("Swatch")
		color_swatch.color = Data.LINE_COLORS[line_key]
		legend_rows.add_child(item)
		_legend_item_by_line[line_key] = item

func _render_line_legend() -> void:
	var sandbox_map := GameStore.is_sandbox()
	var custom_line_ids := TransitNetwork.custom_line_ids(GameStore.transit_network)
	legend_panel.visible = (
		root_control.size.x >= 1220.0
		and (not sandbox_map or not custom_line_ids.is_empty())
	)
	for line_key in Data.LINE_KEYS:
		var item: HBoxContainer = _legend_item_by_line[line_key]
		item.visible = not sandbox_map
		if sandbox_map:
			continue
		var line: Dictionary = GameStore.lines[line_key]
		var label: Label = item.get_node("Label")
		var stop_count := int(line.get("stop_count", 0))
		var max_stops := int(Data.LINE_CONFIG[line_key].max_stops)
		var bus_count := int(line.get("fleet_count", 0))
		var status := "%d/%d STOPS · %d BUS" % [stop_count, max_stops, bus_count]
		if not bool(line.get("built", false)):
			status = "LOCKED" if line_key != "line1" else "1/%d STOPS" % max_stops
		label.text = "L%d  %s" % [Data.line_number(line_key), status]

	var live_custom: Dictionary = {}
	for line_id in custom_line_ids:
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
		label.text = "%s  %d STOPS · %d %s" % [
			str(line.get("name", "CUSTOM")),
			TransitNetwork.line_stop_ids(GameStore.transit_network, line_id).size(),
			int(line.get("fleet_count", 0)),
			GameStore.transit_vehicle_name(line_id, true).to_upper(),
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
	if GameStore.is_sandbox():
		_create_line_button.text = "NEW %s LINE" % GameStore.selected_transit_mode.to_upper() if not GameStore.route_editor_active() else "DESIGNING LINE"
	else:
		_create_line_button.text = "CREATE LINE" if not GameStore.route_editor_active() else "EDITING LINE"
	if _transit_mode_button != null:
		_transit_mode_button.visible = GameStore.is_sandbox() and bool(GameStore.depot.get("built", false))
		_transit_mode_button.text = "MODE: %s" % GameStore.selected_transit_mode.to_upper()
		_transit_mode_button.disabled = (
			GameStore.route_editor_active()
			and GameStore.route_editor_points().size() > 0
		)
		var mode_profile := GameStore.transit_mode_profile(GameStore.selected_transit_mode)
		var status := GameStore.transit_mode_status(GameStore.selected_transit_mode)
		var mode_capital := float(status.get(
			"minimum_startup_capital",
			status.get("unlock_cost", mode_profile.get("unlock_cost", 0.0))
		))
		_transit_mode_button.tooltip_text = (
			"%s · %d seats · %.0f km/h · minimum new-line capital $%s" % [
				GameStore.selected_transit_mode.capitalize(),
				int(mode_profile.get("vehicle_capacity", 0)),
				float(mode_profile.get("speed_kph", 0.0)),
				_compact_amount(mode_capital),
			]
			if bool(status.get("unlocked", false))
			else "Locked: %s · requires %s residents and at least $%s for the licence and a minimal line." % [
				GameStore.selected_transit_mode.capitalize(),
				_compact_amount(float(mode_profile.get("unlock_population", 0))),
				_compact_amount(mode_capital),
			]
		)


func _render_terrain_tool_button() -> void:
	if _terrain_tool_button == null:
		return
	_terrain_tool_button.disabled = GameStore.route_editor_active()
	var mode := str(GameStore.terrain_tool_mode)
	_terrain_tool_button.text = "TERRAIN: %s" % mode.to_upper() if not mode.is_empty() else "TERRAIN: OFF"


func _is_sandbox_map() -> bool:
	return GameStore.is_sandbox()


func _has_built_sandbox_road() -> bool:
	var roads: Variant = GameStore.city.get("roads", [])
	if typeof(roads) != TYPE_ARRAY:
		return false
	var road_array: Array = roads
	var road_count := road_array.size()
	if road_count == _cached_built_road_count:
		return _cached_built_road_available
	_cached_built_road_count = road_count
	_cached_built_road_available = false
	for road_value in road_array:
		if typeof(road_value) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_value
		var points: Variant = road.get("points", [])
		var point_array: Array = []
		if typeof(points) == TYPE_ARRAY:
			point_array = points
		if (
			str(road.get("status", "")) == "built"
			and point_array.size() >= 2
		):
			_cached_built_road_available = true
			break
	return _cached_built_road_available


func _invalidate_built_road_cache() -> void:
	_cached_built_road_count = -1


func _render_world_build_tool_buttons() -> void:
	if _road_builder_button == null or _depot_placement_button == null:
		return
	var sandbox_map := _is_sandbox_map()
	var road_active := GameStore.road_builder_active()
	var road_points := GameStore.road_builder_points()
	var depot_active := GameStore.depot_placement_active()
	var depot_available := (
		sandbox_map
		and _has_built_sandbox_road()
		and not bool(GameStore.depot.get("built", false))
	)
	if not sandbox_map:
		if road_active:
			GameStore.cancel_road_builder()
		if depot_active:
			GameStore.cancel_depot_placement()
	_road_builder_button.visible = sandbox_map
	_depot_placement_button.visible = depot_available
	_road_builder_button.disabled = GameStore.route_editor_active()
	_depot_placement_button.disabled = GameStore.route_editor_active()
	var signature := "%s|%s|%d|%s|%s" % [
		str(sandbox_map),
		str(road_active),
		road_points.size(),
		str(depot_available),
		str(depot_active),
	]
	if signature == _world_build_tools_signature:
		return
	_world_build_tools_signature = signature
	if road_active:
		if road_points.size() >= 2:
			_road_builder_button.text = "COMMIT ROAD · %d POINTS" % road_points.size()
			_road_builder_button.tooltip_text = "Click to commit. Right click removes the last point; Escape cancels."
		else:
			_road_builder_button.text = "CANCEL ROAD · %d/2 POINTS" % road_points.size()
			_road_builder_button.tooltip_text = "Click terrain twice near completed roads. Click this button or press Escape to cancel; right click undoes the last point."
	else:
		_road_builder_button.text = "BUILD ROAD · 2 CLICKS"
		_road_builder_button.tooltip_text = "Begin a collector road by clicking twice near completed roads."
	if depot_active:
		_depot_placement_button.text = "DEPOT ACTIVE · ESC CANCEL"
		_depot_placement_button.tooltip_text = "Click terrain to place the depot. Right click or Escape cancels."
	else:
		_depot_placement_button.text = "PLACE DEPOT"
		_depot_placement_button.tooltip_text = "Place a depot on the map."
	if hint_label != null:
		if not sandbox_map:
			hint_label.text = "LMB ORBIT   ·   RMB PAN   ·   WHEEL ZOOM   ·   SPACE PAUSE"
		elif depot_active:
			hint_label.text = "DEPOT · LMB PLACE · RMB / ESC CANCEL"
		elif road_active:
			hint_label.text = "ROAD · LMB POINTS · RMB UNDO · ESC CANCEL"
		else:
			hint_label.text = "MMB PAN · WHEEL ZOOM · F FIT REGION · SPACE PAUSE"

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
	if GameStore.is_sandbox():
		_render_sandbox_objective()
		return
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


func _render_sandbox_objective() -> void:
	if GameStore.depot_placement_active():
		objective_label.text = "DEPOT PLACEMENT · CLICK BESIDE A COMPLETED ROAD · RIGHT CLICK / ESC CANCEL"
		return
	if GameStore.road_builder_active():
		var road_points := GameStore.road_builder_points()
		if road_points.size() >= 2:
			objective_label.text = "ROAD READY · CLICK COMMIT ROAD · RIGHT CLICK UNDOES THE LAST POINT"
		else:
			objective_label.text = (
				"ROAD BUILDER · " + str(road_points.size())
				+ "/2 POINTS · CLICK NEAR COMPLETED ROADS · RIGHT CLICK UNDO"
			)
		return
	if GameStore.route_editor_active():
		var route_points := GameStore.route_editor_points()
		objective_label.text = "TRANSIT LINE DESIGN · " + str(route_points.size()) + " STOPS · ENTER CONFIRMS · ESC CANCELS"
		return
	if not str(GameStore.terrain_tool_mode).is_empty():
		objective_label.text = "TERRAIN TOOL · %s · CLICK MAP TO SCULPT" % str(GameStore.terrain_tool_mode).to_upper()
		return
	if not _has_built_sandbox_road():
		objective_label.text = "SANDBOX GOAL · BUILD CONNECTED ROADS, THEN PLACE A DEPOT AND CREATE A TRANSIT LINE"
		return
	if not bool(GameStore.depot.get("built", false)):
		objective_label.text = "NEXT · PLACE A DEPOT BESIDE A COMPLETED ROAD, THEN CREATE A TRANSIT LINE"
		return
	if _sandbox_active_line_count() == 0:
		objective_label.text = "NEXT · CREATE A TRANSIT LINE ON COMPLETED ROADS TO SERVE REGIONAL SETTLEMENTS"
		return
	var transport := _resident_transport_metrics()
	var health := GameStore.resident_health_metrics()
	var progression := SandboxProgression.evaluate({
		"resident_count": float(transport.get("resident_count", 0.0)),
		"public_treasury": GameStore.money,
		"unlocked_modes": GameStore.transit_network.get("unlocked_modes", {"bus": true}),
		"reachable_transit_od_pairs": float(transport.get("reachable_transit_od_pairs", 0.0)),
		"total_od_pairs": float(transport.get("total_od_pairs", 0.0)),
		"healthcare_coverage": float(health.get("healthcare_coverage", 0.0)),
		"healthcare_data_available": bool(health.get("healthcare_data_available", false)),
		"lifetime_revenue": float(GameStore.stats.get("lifetime_revenue", 0.0)),
		"lifetime_operating_costs": float(GameStore.stats.get("lifetime_operating_costs", 0.0)),
		"minimum_startup_capital_by_mode": _sandbox_mode_startup_capital(),
	})
	var next_objective: Dictionary = progression.get("next_objective", {})
	if next_objective.is_empty():
		objective_label.text = "REGION WELL CONNECTED · EXPAND SERVICES OR IMPROVE OPERATOR MARGIN"
		return
	var objective_id := str(next_objective.get("id", ""))
	if str(next_objective.get("kind", "")) == "infrastructure_unlock":
		var mode_label := str(next_objective.get("label", "Transit mode")).to_upper()
		if bool(next_objective.get("ready_to_unlock", false)):
			objective_label.text = "READY · %s · SELECT THE MODE AND BUILD A VALID MINIMUM-COST LINE" % mode_label
		else:
			objective_label.text = "NEXT · %s" % str(next_objective.get("feedback", "")).to_upper()
		return
	match objective_id:
		"regional_access":
			objective_label.text = "NEXT · EXTEND GOLD ROAD CORRIDORS AND TRANSIT TO REACH 25% OF REGIONAL TRIP PAIRS"
		"operator_balance":
			objective_label.text = "NEXT · IMPROVE SERVICE FREQUENCY AND RIDERSHIP UNTIL FARES COVER OPERATING COSTS"
		"healthcare_coverage":
			objective_label.text = "NEXT · BUILD LOCAL CLINICS TO KEEP HEALTHCARE COVERAGE ABOVE 95%"
		_:
			objective_label.text = "NETWORK ACTIVE · CONNECT SETTLEMENTS AND IMPROVE RESIDENT ACCESS"


func _sandbox_active_line_count() -> int:
	var count := 0
	for line_id in TransitNetwork.custom_line_ids(GameStore.transit_network):
		var line := GameStore.transit_line(line_id)
		if str(line.get("status", "")) in ["active", "built"]:
			count += 1
	return count

func _render_progress() -> void:
	if GameStore.is_sandbox():
		_render_sandbox_progress()
		return
	progress_label.custom_minimum_size.y = 0.0
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


func _render_sandbox_progress() -> void:
	progress_label.custom_minimum_size.y = 100.0
	progress_label.tooltip_text = "Regional world seed: %d. Starting a new region creates a fresh seed; save copies preserve this one." % GameStore.city_seed
	var metrics := _resident_transport_metrics()
	var health := GameStore.resident_health_metrics()
	var age_transport: Dictionary = metrics.get("age_group_transport", {})
	var child_transport: Dictionary = age_transport.get("children", {})
	var senior_transport: Dictionary = age_transport.get("seniors", {})
	var resident_count := _sandbox_metric_number(metrics, "resident_count", 0.0)
	var transit_share := _sandbox_metric_number(metrics, "transit_share", 0.0)
	var car_share := _sandbox_metric_number(metrics, "car_share", 0.0)
	var commute_minutes := _sandbox_metric_number(metrics, "average_commute_minutes", 0.0)
	var expected_trips := _sandbox_metric_number(metrics, "expected_transit_trips_per_hour", 0.0)
	var average_wellbeing := _sandbox_metric_number(metrics, "average_wellbeing", 0.0)
	var health_index := _sandbox_metric_number(health, "health_index", 100.0)
	var healthcare_coverage := _sandbox_metric_number(health, "healthcare_coverage", 0.0)
	var preventable_burden := _sandbox_metric_number(health, "preventable_burden", 0.0)
	var acute_prevalence := _sandbox_metric_number(health, "acute_prevalence", 0.0)
	var chronic_prevalence := _sandbox_metric_number(health, "chronic_prevalence", 0.0)
	var treasury := _sandbox_metric_number(metrics, "public_treasury", GameStore.money)
	var lifetime_revenue := _sandbox_metric_number(GameStore.stats, "lifetime_revenue", 0.0)
	var lifetime_operating_costs := _sandbox_metric_number(
		GameStore.stats,
		"lifetime_operating_costs",
		0.0
	)
	var lifetime_net := lifetime_revenue - lifetime_operating_costs
	var first_line := (
		"POP " + _compact_amount(resident_count)
		+ " · TRANSIT " + _sandbox_share_text(transit_share)
		+ " · CAR " + _sandbox_share_text(car_share)
		+ " · AVG COMMUTE " + String.num(maxf(0.0, commute_minutes), 1) + " MIN"
	)
	var second_line := (
		"TRIPS/H " + str(roundi(maxf(0.0, expected_trips)))
		+ " · WELLBEING " + _sandbox_wellbeing_text(average_wellbeing)
		+ " · TREASURY $" + _compact_amount(treasury)
	)
	var third_line := (
		"LIFETIME FARE REVENUE $" + _compact_amount(lifetime_revenue)
		+ " · OPERATING COSTS $" + _compact_amount(lifetime_operating_costs)
		+ " · NET $" + _compact_amount(lifetime_net)
	)
	var fourth_line := (
		"HEALTH " + str(roundi(health_index)) + "/100"
		+ " · CARE " + _sandbox_share_text(healthcare_coverage)
		+ " · ACUTE " + _sandbox_share_text(acute_prevalence)
		+ " · CHRONIC " + _sandbox_share_text(chronic_prevalence)
	)
	progress_label.tooltip_text += "\nAge mix — children: %s transit, $%s fare/trip; seniors: %s transit, $%s fare/trip." % [
		_sandbox_share_text(float(child_transport.get("transit_share", 0.0))),
		String.num(float(child_transport.get("fare_per_transit_trip", 0.0)), 2),
		_sandbox_share_text(float(senior_transport.get("transit_share", 0.0))),
		String.num(float(senior_transport.get("fare_per_transit_trip", 0.0)), 2),
	]
	var progression := SandboxProgression.evaluate({
		"resident_count": resident_count,
		"public_treasury": treasury,
		"unlocked_modes": GameStore.transit_network.get("unlocked_modes", {"bus": true}),
		"reachable_transit_od_pairs": float(metrics.get("reachable_transit_od_pairs", 0.0)),
		"total_od_pairs": float(metrics.get("total_od_pairs", 0.0)),
		"healthcare_coverage": healthcare_coverage,
		"healthcare_data_available": bool(health.get("healthcare_data_available", false)),
		"lifetime_revenue": lifetime_revenue,
		"lifetime_operating_costs": lifetime_operating_costs,
		"minimum_startup_capital_by_mode": _sandbox_mode_startup_capital(),
	})
	var fifth_line := _sandbox_goal_summary(progression.get("goals", []))
	progress_label.tooltip_text = "Health combines access, commute and pollution with aggregate acute/chronic illness, treatment, births, aging and expected deaths. These are gameplay estimates, not individual medical diagnoses. Preventable burden: %d/100." % roundi(preventable_burden)
	progress_label.text = first_line + "\n" + second_line + "\n" + third_line + "\n" + fourth_line + "\n" + fifth_line


func _sandbox_mode_startup_capital() -> Dictionary:
	var result: Dictionary = {}
	for mode in ["tram", "metro"]:
		var status: Dictionary = GameStore.transit_mode_status(mode)
		result[mode] = float(status.get(
			"minimum_startup_capital",
			status.get("unlock_cost", 0.0)
		))
	return result


func _sandbox_goal_summary(goals_value: Variant) -> String:
	if typeof(goals_value) != TYPE_ARRAY:
		return "MILESTONES · CONNECT 25% OF TRIP PAIRS · BALANCE FARES/COSTS · COVER 95% OF CARE NEEDS"
	var goals: Array = goals_value
	var values: Dictionary = {}
	for goal_value in goals:
		if typeof(goal_value) == TYPE_DICTIONARY:
			var goal: Dictionary = goal_value
			values[str(goal.get("id", ""))] = goal
	var access: Dictionary = values.get("regional_access", {})
	var balance: Dictionary = values.get("operator_balance", {})
	var care: Dictionary = values.get("healthcare_coverage", {})
	var access_text := "ACCESS —"
	if bool(access.get("available", false)):
		access_text = "ACCESS %d%%/25%%" % roundi(float(access.get("value", 0.0)) * 100.0)
	var balance_text := "OPS —"
	if bool(balance.get("available", false)):
		var net := float(balance.get("value", 0.0))
		balance_text = "OPS %s$%s" % ["+" if net >= 0.0 else "−", _compact_amount(absf(net))]
	var care_text := "CARE —"
	if bool(care.get("available", false)):
		care_text = "CARE %d%%/95%%" % roundi(float(care.get("value", 0.0)) * 100.0)
	return "MILESTONES · " + access_text + " · " + balance_text + " · " + care_text


func _resident_transport_metrics() -> Dictionary:
	if not GameStore.has_method("resident_transport_metrics"):
		return {}
	var raw_metrics: Variant = GameStore.call("resident_transport_metrics")
	if typeof(raw_metrics) != TYPE_DICTIONARY:
		return {}
	var metrics: Dictionary = raw_metrics
	return metrics


func _sandbox_metric_number(metrics: Dictionary, key: String, fallback: float = 0.0) -> float:
	var raw_value: Variant = metrics.get(key, fallback)
	if typeof(raw_value) not in [TYPE_INT, TYPE_FLOAT]:
		return fallback
	var number := float(raw_value)
	return number if is_finite(number) else fallback


func _sandbox_share_text(value: float) -> String:
	var percentage := value * 100.0 if value <= 1.0 else value
	return str(roundi(clampf(percentage, 0.0, 100.0))) + "%"


func _sandbox_wellbeing_text(value: float) -> String:
	var score := value * 100.0 if value <= 1.0 else value
	return str(roundi(clampf(score, 0.0, 100.0))) + "/100"

func _on_close_pressed() -> void:
	if GameStore.route_editor_active():
		GameStore.cancel_route_editor()
	else:
		GameStore.set_selection("")

func _on_create_line_pressed() -> void:
	GameStore.begin_free_line_editor()


func _on_transit_mode_pressed() -> void:
	GameStore.cycle_selected_transit_mode()


func _on_terrain_tool_pressed() -> void:
	var current_index := TERRAIN_TOOL_MODES.find(str(GameStore.terrain_tool_mode))
	var next_index := (current_index + 1) % TERRAIN_TOOL_MODES.size()
	var next_mode := str(TERRAIN_TOOL_MODES[next_index])
	GameStore.set_terrain_tool_mode(next_mode)
	if next_mode.is_empty():
		show_toast("Terrain sculpting off.")
	else:
		show_toast("%s terrain: click map to sculpt (radius 130 m)." % next_mode.capitalize())


func _on_road_builder_pressed() -> void:
	if not _is_sandbox_map():
		return
	if GameStore.road_builder_active():
		if GameStore.road_builder_points().size() >= 2:
			if GameStore.commit_road_builder():
				show_toast("Collector road added.")
			else:
				show_toast("The road could not be committed.")
		else:
			GameStore.cancel_road_builder()
			show_toast("Road placement cancelled.")
	else:
		if GameStore.depot_placement_active():
			GameStore.cancel_depot_placement()
		if not str(GameStore.terrain_tool_mode).is_empty():
			GameStore.set_terrain_tool_mode("")
		if GameStore.begin_road_builder("collector"):
			show_toast("Click twice near completed roads to connect them. Right click undoes a point; Escape cancels.")
		else:
			show_toast("Road placement could not be started.")
	_world_build_tools_signature = ""
	_render_world_build_tool_buttons()


func _on_depot_placement_pressed() -> void:
	if not _is_sandbox_map() or not _has_built_sandbox_road():
		return
	if GameStore.depot_placement_active():
		GameStore.cancel_depot_placement()
		show_toast("Depot placement cancelled.")
	else:
		if GameStore.road_builder_active():
			GameStore.cancel_road_builder()
		if not str(GameStore.terrain_tool_mode).is_empty():
			GameStore.set_terrain_tool_mode("")
		if GameStore.begin_depot_placement():
			show_toast("Click the terrain to place a depot. Right click or Escape cancels.")
		else:
			show_toast("Depot placement could not be started.")
	_world_build_tools_signature = ""
	_render_world_build_tool_buttons()

func _on_pause_pressed() -> void:
	GameStore.set_speed(1 if GameStore.simulation_speed == 0 else 0)

func _on_selection_changed(_selection: String) -> void:
	_render_inspector()
	_refresh_city_shell()

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
	elif selection.begins_with("settlement:"):
		_render_settlement(selection.trim_prefix("settlement:"))
	elif selection.begins_with("regional_road:"):
		_render_regional_road(selection.trim_prefix("regional_road:"))
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
	var transit_mode := str(GameStore.route_editor.get("transit_mode", "bus"))
	var selected := int(GameStore.route_editor.get("selected_index", -1))
	inspector_eyebrow.text = "ROUTE DESIGNER"
	inspector_title.text = ("NEW " if mode == "new" else "EDIT ") + transit_mode.to_upper() + " LINE"
	inspector_body.text = (
		"Place accessible underground stations inside the map. Trains follow the route beneath the visible tunnel cutaway. "
		if transit_mode == "metro"
		else "Click completed roads to place stops. Tram construction reserves tracks on its road corridor. "
		if transit_mode == "tram"
		else "Click completed roads to add stops. Ctrl+click adds a VIA point that forces the route through another street."
	)
	_add_stat_row("Mode", "%s · %.0f km/h · %d seats" % [transit_mode.to_upper(), float(GameStore.transit_mode_profile(transit_mode).get("speed_kph", 0.0)), int(GameStore.transit_mode_profile(transit_mode).get("vehicle_capacity", 0))])
	_add_stat_row("Stops", "%d / %d" % [points.size(), TransitNetwork.MAX_CUSTOM_STOPS])
	_add_stat_row("Via points", "%d" % waypoint_count)
	_add_stat_row("Minimum spacing", "%d m" % roundi(float(GameStore.transit_mode_profile(transit_mode).get("minimum_stop_spacing", TransitNetwork.MIN_STOP_SPACING))))
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


func _render_settlement(settlement_id: String) -> void:
	var settlement: Dictionary = {}
	for settlement_value in GameStore.city.get("regional_settlements", []):
		if typeof(settlement_value) != TYPE_DICTIONARY:
			continue
		var candidate: Dictionary = settlement_value
		if str(candidate.get("id", "")) == settlement_id:
			settlement = candidate
			break
	if settlement.is_empty():
		inspector.visible = false
		return
	var health: Dictionary = GameStore.resident_health_metrics()
	var district_health: Dictionary = health.get("districts", {}).get(settlement_id, {})
	var transport: Dictionary = _resident_transport_metrics()
	var district_transport: Dictionary = transport.get("districts", {}).get(settlement_id, {})
	var service_results: Dictionary = GameStore._current_regional_service_results()
	var service_district: Dictionary = service_results.get("services", {}).get("districts", {}).get(settlement_id, {}).get("services", {})
	inspector_eyebrow.text = "REGIONAL SETTLEMENT · %s" % str(settlement.get("tier", "village")).to_upper()
	inspector_title.text = str(settlement.get("name", settlement_id)).to_upper()
	inspector_body.text = "The settlement grows autonomously. Build transit and local services to improve access, health and quality of life."
	_add_stat_row("Residents", _compact_amount(float(settlement.get("population", 0))))
	_add_stat_row("Jobs", _compact_amount(float(settlement.get("jobs", 0))))
	_add_stat_row("Health", "%d / 100" % roundi(float(district_health.get("health_index", 100.0))))
	_add_stat_row("Healthcare", _sandbox_share_text(float(district_health.get("healthcare_coverage", 0.0))))
	_add_stat_row("Acute illness", _sandbox_share_text(float(district_health.get("acute_prevalence", 0.0))))
	_add_stat_row("Chronic burden", _sandbox_share_text(float(district_health.get("chronic_prevalence", 0.0))))
	_add_stat_row("Expected deaths", _compact_amount(float(district_health.get("deaths", 0.0))))
	_add_stat_row("New residents", _compact_amount(float(district_health.get("births", 0.0))))
	for service_type in ["education", "fire", "police", "waste", "recreation"]:
		var service: Dictionary = service_district.get(service_type, {})
		_add_stat_row(_service_name(service_type), _sandbox_share_text(float(service.get("coverage", 0.0))))
	_add_stat_row("Average commute", "%.1f MIN" % float(district_transport.get("average_commute_minutes", 0.0)))
	_add_stat_row("Transit share", _sandbox_share_text(float(district_transport.get("transit_share", 0.0))))
	var age_transport: Dictionary = district_transport.get("age_groups", {})
	_add_stat_row("Children · transit", _sandbox_share_text(float(age_transport.get("children", {}).get("transit_share", 0.0))))
	_add_stat_row("Seniors · transit", _sandbox_share_text(float(age_transport.get("seniors", {}).get("transit_share", 0.0))))
	_add_stat_row("Car exposure", _sandbox_share_text(float(district_health.get("pollution_exposure", 0.0))))
	_add_stat_row("Unserved trips", _sandbox_share_text(float(district_transport.get("unserved_share", 0.0))))
	for service_type in ["healthcare", "education", "fire", "police", "waste", "recreation"]:
		var status: Dictionary = GameStore.regional_service_build_status(settlement_id, service_type)
		if str(status.get("reason", "")) == "service_already_covered":
			continue
		var button := Button.new()
		button.custom_minimum_size.y = 42.0
		button.text = "BUILD %s  ·  $%s" % [
			_service_building_name(service_type),
			_compact_amount(float(status.get("cost", 0.0))),
		]
		button.disabled = not bool(status.get("available", false))
		button.tooltip_text = "Coverage: %s · upkeep is charged while the facility operates." % _sandbox_share_text(float(status.get("coverage", 0.0)))
		button.pressed.connect(GameStore.build_regional_service.bind(settlement_id, service_type))
		fleet_box.add_child(button)


func _service_name(service_type: String) -> String:
	match service_type:
		"healthcare":
			return "Healthcare"
		"education":
			return "Education"
		"fire":
			return "Fire service"
		"police":
			return "Police"
		"waste":
			return "Waste"
		"recreation":
			return "Recreation"
		_:
			return service_type.capitalize()


func _service_building_name(service_type: String) -> String:
	match service_type:
		"healthcare":
			return "CLINIC"
		"education":
			return "SCHOOL"
		"fire":
			return "FIRE STATION"
		"police":
			return "POLICE STATION"
		"waste":
			return "WASTE DEPOT"
		"recreation":
			return "PARK"
		_:
			return service_type.replace("_", " ").to_upper()


func _render_regional_road(road_id: String) -> void:
	var road: Dictionary = {}
	for road_value in GameStore.city.get("roads", []):
		if str(road_value.get("id", "")) == road_id:
			road = road_value
			break
	if road.is_empty():
		inspector.visible = false
		return
	var status := GameStore.regional_road_build_status(road_id)
	var road_class := str(road.get("class", "collector"))
	var role := str(road.get("regionalRole", "regional link")).replace("_", " ")
	inspector_eyebrow.text = "REGIONAL INFRASTRUCTURE · %s" % road_class.to_upper()
	inspector_title.text = "ROAD PROJECT"
	inspector_body.text = "Complete a generated corridor to extend the connected road network and open more settlements to local growth and transit."
	_add_stat_row("Connection", "%s → %s" % [str(status.get("connected_node", road.get("a", ""))), str(status.get("new_node", road.get("b", "")))])
	_add_stat_row("Role", role.to_upper())
	_add_stat_row("Length", "%.2f KM" % (float(status.get("length", 0.0)) / 1000.0))
	if bool(status.get("pending", false)):
		_add_stat_row("Construction", "%d%% · %s" % [roundi(float(status.get("progress", 0.0)) * 100.0), str(status.get("project_status", "queued")).to_upper()])
	elif str(status.get("reason", "")) == "already_built":
		_add_stat_row("Status", "COMPLETED")
	elif bool(status.get("available", false)):
		var cost := int(status.get("cost", 0))
		_add_stat_row("Status", "READY TO BUILD")
		_add_stat_row("Construction cost", "$%s" % _compact_amount(cost))
		primary_button.visible = true
		primary_button.disabled = GameStore.money < float(cost)
		primary_button.text = "START ROAD PROJECT  ·  $%s" % _compact_amount(cost)
		_primary_action = "build_regional_road"
		_primary_payload = road_id
	else:
		_add_stat_row("Status", "LOCKED · %s" % str(status.get("reason", "unavailable")).replace("_", " ").to_upper())

func _render_free_line(line_id: String) -> void:
	var line := GameStore.transit_line(line_id)
	if line.is_empty():
		inspector.visible = false
		return
	var stop_count := TransitNetwork.line_stop_ids(GameStore.transit_network, line_id).size()
	var headway := GameStore.custom_line_headway_minutes(line_id)
	var mode := str(line.get("mode", "bus"))
	inspector_eyebrow.text = "CUSTOM %s LINE" % mode.to_upper()
	inspector_title.text = str(line.get("name", line_id)).to_upper()
	inspector_body.text = "A player-designed %s corridor integrated with residents' trip choices." % mode
	_add_stat_row("Mode", "%s · %.0f km/h" % [mode.to_upper(), float(GameStore.transit_mode_profile(mode).get("speed_kph", 0.0))])
	_add_stat_row("Stops", "%d" % stop_count)
	_add_stat_row("Route", "%.2f KM" % GameStore.custom_line_route_length_km(line_id))
	_add_stat_row("Demand", "%.1f PAX/MIN" % GameStore.custom_line_demand(line_id))
	_add_stat_row("Waiting", "%.1f PAX" % GameStore.custom_line_waiting_passengers(line_id))
	_add_stat_row("Crowding pressure", _sandbox_share_text(float(line.get("crowding_ratio", 0.0))))
	_add_stat_row(
		"Headway",
		("%.1f MIN" % headway) if is_finite(headway) else "NO SERVICE"
	)
	_add_stat_row(GameStore.transit_vehicle_name(line_id, true).capitalize(), "%d" % int(line.get("fleet_count", 0)))
	primary_button.visible = true
	primary_button.text = "EDIT LINE"
	primary_button.disabled = GameStore.route_editor_active()
	_primary_action = "edit_free_line"
	_primary_payload = line_id

	var add_vehicle_button := Button.new()
	add_vehicle_button.text = "BUY %s  ·  $%d" % [GameStore.transit_vehicle_name(line_id).to_upper(), GameStore.transit_vehicle_purchase_cost(line_id)]
	add_vehicle_button.disabled = (
		GameStore.garage_used() >= int(GameStore.depot.get("garage_slots", 0))
		or GameStore.money < GameStore.transit_vehicle_purchase_cost(line_id)
		or int(line.get("fleet_count", 0)) >= int(Data.ECONOMY.max_vehicles_per_line)
	)
	add_vehicle_button.pressed.connect(GameStore.add_vehicle_to_transit_line.bind(line_id))
	fleet_box.add_child(add_vehicle_button)

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
	inspector_body.text = "A shared garage for the active public transport network."
	_add_stat_row("Starting capacity", "4 VEHICLES")
	_add_stat_row("Build cost", "$%s" % _compact_amount(cost))
	primary_button.visible = true
	primary_button.disabled = GameStore.money < cost
	primary_button.text = "BUILD DEPOT  ·  $%d" % cost
	_primary_action = "build_depot"

func _render_depot() -> void:
	inspector_eyebrow.text = "TRANSPORT FACILITY"
	inspector_title.text = "BUS DEPOT"
	inspector_body.text = "Buy vehicles for open lines or expand the shared garage."
	_add_stat_row("Garage", "%d / %d VEHICLES" % [GameStore.garage_used(), int(GameStore.depot.garage_slots)])
	_add_stat_row("Base bus price", "$%s" % _compact_amount(GameStore.vehicle_purchase_cost()))

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
		var vehicle_name := str(GameStore.transit_vehicle_name(line_id)).to_upper()
		var vehicle_cost := GameStore.transit_vehicle_purchase_cost(line_id)
		var button := Button.new()
		button.text = "BUY %s FOR %s  ·  $%d" % [
			vehicle_name,
			str(line.get("name", line_id)).to_upper(),
			vehicle_cost,
		]
		button.disabled = (
			GameStore.garage_used() >= int(GameStore.depot.garage_slots)
			or int(line.get("fleet_count", 0)) >= int(Data.ECONOMY.max_vehicles_per_line)
			or GameStore.money < vehicle_cost
		)
		button.pressed.connect(GameStore.add_vehicle_to_transit_line.bind(line_id))
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
		"build_regional_road":
			GameStore.build_regional_road(_primary_payload)
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
	_reset_confirmation.popup_centered(Vector2i(460, 190))

func _on_reset_confirmed() -> void:
	GameStore.clear_save_and_reset()
	GameStore.set_selection("")
	show_toast("New region started · seed %d" % GameStore.city_seed)


func _on_import_pressed() -> void:
	_import_dialog.popup_centered_ratio(0.72)

func _on_import_file_selected(path: String) -> void:
	if GameStore.import_browser_save(path):
		GameStore.set_selection("")

func _on_save_copy_pressed() -> void:
	_save_copy_dialog.current_file = "I Like Transit - Seed %d.json" % GameStore.city_seed
	_save_copy_dialog.popup_centered_ratio(0.72)

func _on_save_copy_file_selected(path: String) -> void:
	if GameStore.export_save_copy(path):
		show_toast("Save copy exported.")
	else:
		show_toast("Save copy could not be written.")
