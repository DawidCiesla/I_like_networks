extends CanvasLayer

const Data = preload("res://scripts/core/game_data.gd")

@onready var money_label: Label = $Root/TopBar/Money
@onready var network_label: Label = $Root/TopBar/Network
@onready var objective_label: Label = $Root/Objective
@onready var inspector: PanelContainer = $Root/Inspector
@onready var inspector_title: Label = $Root/Inspector/Margin/Content/Title
@onready var inspector_body: Label = $Root/Inspector/Margin/Content/Body
@onready var primary_button: Button = $Root/Inspector/Margin/Content/PrimaryButton
@onready var fleet_box: VBoxContainer = $Root/Inspector/Margin/Content/FleetButtons
@onready var depot_upgrade_button: Button = $Root/Inspector/Margin/Content/DepotUpgradeButton
@onready var close_button: Button = $Root/Inspector/Margin/Content/CloseButton
@onready var toast_label: Label = $Root/Toast
@onready var pause_button: Button = $Root/SpeedPanel/Row/Pause
@onready var speed_1_button: Button = $Root/SpeedPanel/Row/Speed1
@onready var speed_2_button: Button = $Root/SpeedPanel/Row/Speed2
@onready var speed_4_button: Button = $Root/SpeedPanel/Row/Speed4
@onready var reset_button: Button = $Root/ResetButton

var _primary_action := ""
var _primary_payload := ""
var _toast_seconds := 0.0

func _ready() -> void:
	GameStore.state_changed.connect(refresh)
	GameStore.selection_changed.connect(_on_selection_changed)
	GameStore.toast_requested.connect(show_toast)

	primary_button.pressed.connect(_on_primary_pressed)
	depot_upgrade_button.pressed.connect(_on_depot_upgrade)
	close_button.pressed.connect(func(): GameStore.set_selection(""))
	pause_button.pressed.connect(func(): GameStore.set_speed(0))
	speed_1_button.pressed.connect(func(): GameStore.set_speed(1))
	speed_2_button.pressed.connect(func(): GameStore.set_speed(2))
	speed_4_button.pressed.connect(func(): GameStore.set_speed(4))
	reset_button.pressed.connect(_on_reset_pressed)

	refresh()
	_on_selection_changed(GameStore.selected)

func _process(delta: float) -> void:
	if _toast_seconds > 0.0:
		_toast_seconds -= delta
		if _toast_seconds <= 0.0:
			toast_label.visible = false

func refresh() -> void:
	money_label.text = "$%d" % roundi(GameStore.money)
	network_label.text = "%d LINES  ·  %d BUSES  ·  DEPOT %d/%d" % [
		_built_line_count(),
		GameStore.garage_used(),
		GameStore.garage_used(),
		int(GameStore.depot.garage_slots),
	]
	_render_objective()
	_render_speed()
	_render_inspector()

func _built_line_count() -> int:
	var result := 0
	for line_key in Data.LINE_KEYS:
		if bool(GameStore.lines[line_key].built):
			result += 1
	return result

func _render_speed() -> void:
	for button in [pause_button, speed_1_button, speed_2_button, speed_4_button]:
		button.disabled = false
	match GameStore.simulation_speed:
		0:
			pause_button.disabled = true
		1:
			speed_1_button.disabled = true
		2:
			speed_2_button.disabled = true
		4:
			speed_4_button.disabled = true

func _render_objective() -> void:
	if not bool(GameStore.lines.line1.built):
		objective_label.text = "BUY MARKET SQUARE · START BUS LINE 1"
		return
	if GameStore.can_build_depot():
		objective_label.text = "BUS DEPOT UNLOCKED · CLICK ITS GHOST BUILDING"
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

func _on_selection_changed(_selection: String) -> void:
	_render_inspector()

func _render_inspector() -> void:
	var selection := GameStore.selected
	_clear_fleet_buttons()
	depot_upgrade_button.visible = false
	primary_button.visible = false
	_primary_action = ""
	_primary_payload = ""

	if selection.is_empty():
		inspector.visible = false
		return

	inspector.visible = true

	if selection.begins_with("station:"):
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

func _render_station(station_id: String) -> void:
	var served := GameStore.station_served_lines(station_id)
	var served_text: Array[String] = []
	for line_key in served:
		served_text.append("L%d" % Data.line_number(line_key))

	var level := GameStore.station_level(station_id)
	inspector_title.text = Data.station_name(station_id).to_upper()
	inspector_body.text = "%s · %s\nWAITING  %.1f PAX\nQUEUE CAPACITY  %d PAX / LINE\nLOCAL UPGRADE  %d / %d" % [
		GameStore.station_tier(station_id).to_upper(),
		" + ".join(served_text) if not served_text.is_empty() else "NO SERVICE",
		GameStore.station_waiting_passengers(station_id),
		GameStore.station_capacity(station_id),
		level,
		int(Data.STATION_UPGRADE.max_level),
	]

	if level < int(Data.STATION_UPGRADE.max_level):
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
	inspector_title.text = Data.station_name(station_id).to_upper()
	inspector_body.text = "BUS LINE %d EXPANSION\n%s" % [
		Data.line_number(line_key),
		"CONNECT EXISTING INTERCHANGE" if GameStore.station_is_built(station_id) else "BUILD NEW STOP",
	]
	primary_button.visible = true
	primary_button.disabled = GameStore.money < cost
	primary_button.text = "BUILD / CONNECT  ·  $%d" % cost
	_primary_action = "build_stop"
	_primary_payload = line_key

func _render_future_line(line_key: String) -> void:
	var cost := GameStore.line_build_cost(line_key)
	inspector_title.text = "BUS LINE %d" % Data.line_number(line_key)
	inspector_body.text = "%s → %s\nSTARTER FLEET  1 BUS\nSTARTER STOPS  2" % [
		Data.STOP_NAMES[line_key][0],
		Data.STOP_NAMES[line_key][1],
	]
	primary_button.visible = true
	primary_button.disabled = GameStore.money < cost or not GameStore.can_unlock_line(line_key)
	primary_button.text = "OPEN LINE %d  ·  $%d" % [Data.line_number(line_key), cost]
	_primary_action = "build_line"
	_primary_payload = line_key

func _render_future_depot() -> void:
	var cost := int(Data.ECONOMY.depot_build_cost)
	inspector_title.text = "BUS DEPOT"
	inspector_body.text = "SHARED FLEET FACILITY\nSTARTING CAPACITY  4 BUSES"
	primary_button.visible = true
	primary_button.disabled = GameStore.money < cost
	primary_button.text = "BUILD DEPOT  ·  $%d" % cost
	_primary_action = "build_depot"

func _render_depot() -> void:
	inspector_title.text = "BUS DEPOT"
	inspector_body.text = "GARAGE  %d / %d\nNEXT BUS  $%d" % [
		GameStore.garage_used(),
		int(GameStore.depot.garage_slots),
		GameStore.vehicle_purchase_cost(),
	]

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
