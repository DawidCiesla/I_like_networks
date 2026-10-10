extends Node3D

const Data = preload("res://scripts/core/game_data.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const RegionalAccessibility = preload("res://scripts/city/regional_accessibility.gd")
const RegionalDevelopmentPressure = preload("res://scripts/city/regional_development_pressure.gd")
const RegionalHighwayProposalRuntime = preload("res://scripts/city/regional_highway_proposal_runtime.gd")
const RegionalProgressionRuntime = preload("res://scripts/city/regional_progression_runtime.gd")
const RegionalTrafficRuntime = preload("res://scripts/simulation/regional_traffic_runtime.gd")
const RegionalTransitTrafficRuntime = preload("res://scripts/simulation/regional_transit_traffic_runtime.gd")
const RegionalEconomy = preload("res://scripts/simulation/regional_economy.gd")
const RegionalFleetManagement = preload("res://scripts/simulation/regional_fleet_management.gd")
const RegionalGameplayAlerts = preload("res://scripts/ui/regional_gameplay_alerts.gd")
const RegionalInfrastructureProposalWidget = preload("res://scripts/ui/regional_infrastructure_proposal_widget.gd")
const RegionalLineOperationsWidget = preload("res://scripts/ui/regional_line_operations_widget.gd")
const RegionalProgressionWidget = preload("res://scripts/ui/regional_progression_widget.gd")
const RegionalSettlementMobilityWidget = preload("res://scripts/ui/regional_settlement_mobility_widget.gd")
const RegionalGrowthOverlayRenderer = preload("res://scripts/render/regional_growth_overlay_renderer.gd")
const RegionalTrafficOverlayRenderer = preload("res://scripts/render/regional_traffic_overlay_renderer.gd")
const BridgeDetailRenderer = preload("res://scripts/render/bridge_detail_renderer.gd")
const BuildingDetailRenderer = preload("res://scripts/render/building_detail_renderer.gd")
const BuildingHlodRenderer = preload("res://scripts/render/building_hlod_renderer.gd")
const BuildingWindowRenderer = preload("res://scripts/render/building_window_renderer.gd")
const CloudLayerRenderer = preload("res://scripts/render/cloud_layer_renderer.gd")
const RegionalRoadsideRenderer = preload("res://scripts/render/regional_roadside_renderer.gd")
const RoadsidePropsRenderer = preload("res://scripts/render/roadside_props_renderer.gd")
const ForestHlodRenderer = preload("res://scripts/world/forest_hlod_renderer.gd")

@onready var _environment_controller: Node3D = $WorldEnvironmentController
@onready var _pause_menu: PauseMenu = $PauseCanvas/PauseMenu

var _bridge_detail_renderer: BridgeDetailRenderer
var _building_detail_renderer: BuildingDetailRenderer
var _building_hlod_renderer: BuildingHlodRenderer
var _building_window_renderer: BuildingWindowRenderer
var _cloud_layer_renderer: CloudLayerRenderer
var _regional_roadside_renderer: RegionalRoadsideRenderer
var _roadside_props_renderer: RoadsidePropsRenderer
var _forest_hlod_renderer: ForestHlodRenderer
var _traffic_overlay_renderer: RegionalTrafficOverlayRenderer
var _growth_overlay_renderer: RegionalGrowthOverlayRenderer
var _gameplay_alerts: RegionalGameplayAlerts
var _infrastructure_proposal_widget: RegionalInfrastructureProposalWidget
var _line_operations_widget: RegionalLineOperationsWidget
var _progression_widget: RegionalProgressionWidget
var _settlement_mobility_widget: RegionalSettlementMobilityWidget
var _last_traffic_elapsed_seconds := 0.0


func _ready() -> void:
	GameStore.toast_requested.connect(_on_toast)
	if not GameStore.state_changed.is_connected(_on_state_changed):
		GameStore.state_changed.connect(_on_state_changed)
	_setup_regional_visual_detail()
	_setup_regional_traffic()
	_on_state_changed()


func _setup_regional_visual_detail() -> void:
	var map_definition := MapDefinition.active_definition()
	if str(map_definition.get("id", MapDefinition.LEGACY_CITY_MAP_ID)) == MapDefinition.LEGACY_CITY_MAP_ID:
		return
	if _cloud_layer_renderer == null:
		_cloud_layer_renderer = CloudLayerRenderer.new()
		_cloud_layer_renderer.name = "CloudLayers"
		add_child(_cloud_layer_renderer)
	if _regional_roadside_renderer == null:
		_regional_roadside_renderer = RegionalRoadsideRenderer.new()
		_regional_roadside_renderer.name = "RegionalRoadsideDetail"
		add_child(_regional_roadside_renderer)
	if _roadside_props_renderer == null:
		_roadside_props_renderer = RoadsidePropsRenderer.new()
		_roadside_props_renderer.name = "RoadsideProps"
		add_child(_roadside_props_renderer)
	if _bridge_detail_renderer == null:
		_bridge_detail_renderer = BridgeDetailRenderer.new()
		_bridge_detail_renderer.name = "BridgeDetails"
		add_child(_bridge_detail_renderer)
	if _building_detail_renderer == null:
		_building_detail_renderer = BuildingDetailRenderer.new()
		_building_detail_renderer.name = "BuildingDetails"
		add_child(_building_detail_renderer)
	if _building_window_renderer == null:
		_building_window_renderer = BuildingWindowRenderer.new()
		_building_window_renderer.name = "BuildingWindows"
		add_child(_building_window_renderer)
	if _building_hlod_renderer == null:
		_building_hlod_renderer = BuildingHlodRenderer.new()
		_building_hlod_renderer.name = "BuildingHLOD"
		add_child(_building_hlod_renderer)
	if _forest_hlod_renderer == null:
		_forest_hlod_renderer = ForestHlodRenderer.new()
		_forest_hlod_renderer.name = "ForestHLOD"
		add_child(_forest_hlod_renderer)


func _setup_regional_traffic() -> void:
	_last_traffic_elapsed_seconds = maxf(0.0, float(GameStore.elapsed_seconds))
	if not GameStore.is_sandbox():
		return
	RegionalTrafficRuntime.ensure(GameStore.city)
	if RegionalTrafficRuntime.refresh(GameStore):
		GameStore.emit_signal("city_changed")
	RegionalAccessibility.apply(GameStore)
	RegionalDevelopmentPressure.apply(GameStore)
	RegionalHighwayProposalRuntime.apply(GameStore.city)
	GameStore.city["economy"] = RegionalEconomy.evaluate(GameStore)
	RegionalTransitTrafficRuntime.apply(GameStore)
	RegionalProgressionRuntime.apply(GameStore)
	if _traffic_overlay_renderer == null:
		_traffic_overlay_renderer = RegionalTrafficOverlayRenderer.new()
		_traffic_overlay_renderer.name = "RegionalTrafficOverlay"
		add_child(_traffic_overlay_renderer)
	if _growth_overlay_renderer == null:
		_growth_overlay_renderer = RegionalGrowthOverlayRenderer.new()
		_growth_overlay_renderer.name = "RegionalGrowthOverlay"
		add_child(_growth_overlay_renderer)
	if _gameplay_alerts == null:
		_gameplay_alerts = RegionalGameplayAlerts.new()
		_gameplay_alerts.name = "RegionalGameplayAlerts"
		_gameplay_alerts.traffic_overlay_requested.connect(_toggle_traffic_overlay)
		add_child(_gameplay_alerts)
		_gameplay_alerts.set_traffic_overlay_active(false)
	if _progression_widget == null:
		_progression_widget = RegionalProgressionWidget.new()
		_progression_widget.name = "RegionalProgression"
		add_child(_progression_widget)
	if _line_operations_widget == null:
		_line_operations_widget = RegionalLineOperationsWidget.new()
		_line_operations_widget.name = "RegionalLineOperations"
		add_child(_line_operations_widget)
	if _settlement_mobility_widget == null:
		_settlement_mobility_widget = RegionalSettlementMobilityWidget.new()
		_settlement_mobility_widget.name = "RegionalSettlementMobility"
		add_child(_settlement_mobility_widget)
	if _infrastructure_proposal_widget == null:
		_infrastructure_proposal_widget = RegionalInfrastructureProposalWidget.new()
		_infrastructure_proposal_widget.name = "RegionalInfrastructureProposal"
		add_child(_infrastructure_proposal_widget)


func _process(_delta: float) -> void:
	if is_instance_valid(_environment_controller):
		var simulation_seconds := maxf(0.0, float(GameStore.city.get("time_seconds", 0.0)))
		_environment_controller.call("set_time_of_day", 8.0 + simulation_seconds / 3600.0)
	_advance_regional_traffic()
	if GameStore.is_sandbox():
		RegionalTransitTrafficRuntime.apply(GameStore)
		var retired := RegionalFleetManagement.process_retirements(GameStore)
		if retired > 0:
			GameStore.city["economy"] = RegionalEconomy.evaluate(GameStore)
			RegionalProgressionRuntime.apply(GameStore)
			if GameStore.has_method("save_game"):
				GameStore.save_game()
			GameStore.emit_signal("state_changed")


func _advance_regional_traffic() -> void:
	var elapsed := maxf(0.0, float(GameStore.elapsed_seconds))
	var traffic_delta := maxf(0.0, elapsed - _last_traffic_elapsed_seconds)
	_last_traffic_elapsed_seconds = elapsed
	if traffic_delta <= 0.0 or not GameStore.is_sandbox():
		return
	# GameStore already accrues transit and service OPEX. Economy V1 adds only
	# player-road maintenance here, using the same simulation-clock delta so
	# pause and speed controls remain authoritative.
	RegionalEconomy.advance(
		GameStore,
		traffic_delta * float(Data.GAME_MINUTES_PER_REAL_SECOND)
	)
	var traffic_changed := RegionalTrafficRuntime.advance(GameStore, traffic_delta)
	if traffic_changed:
		# Accessibility, parcel development pressure and highway proposal benefits
		# sample the freshly-updated travel conditions once per traffic refresh.
		# Growth consumes this stable previous-period snapshot rather than
		# recalculating mode choice itself.
		RegionalAccessibility.apply(GameStore)
		RegionalDevelopmentPressure.apply(GameStore)
		RegionalHighwayProposalRuntime.apply(GameStore.city)
		RegionalProgressionRuntime.apply(GameStore)
		GameStore.emit_signal("city_changed")


func _toggle_traffic_overlay() -> void:
	if not GameStore.is_sandbox() or not is_instance_valid(_traffic_overlay_renderer):
		return
	var active := _traffic_overlay_renderer.toggle()
	if active and is_instance_valid(_growth_overlay_renderer):
		_growth_overlay_renderer.set_enabled(false)
	if is_instance_valid(_gameplay_alerts):
		_gameplay_alerts.set_traffic_overlay_active(active)


func _toggle_growth_overlay() -> void:
	if not GameStore.is_sandbox() or not is_instance_valid(_growth_overlay_renderer):
		return
	var active := _growth_overlay_renderer.toggle()
	if active and is_instance_valid(_traffic_overlay_renderer):
		_traffic_overlay_renderer.set_enabled(false)
		if is_instance_valid(_gameplay_alerts):
			_gameplay_alerts.set_traffic_overlay_active(false)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE:
			if is_instance_valid(_pause_menu):
				if _pause_menu.visible:
					_pause_menu.close()
				else:
					_pause_menu.open()
				get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_SPACE:
			GameStore.set_speed(
				0
				if GameStore.simulation_speed > 0
				else 1
			)
		elif event.physical_keycode == KEY_T and GameStore.is_sandbox():
			_toggle_traffic_overlay()
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_G and GameStore.is_sandbox():
			_toggle_growth_overlay()
			get_viewport().set_input_as_handled()


func _on_state_changed() -> void:
	pass


func _on_toast(message: String) -> void:
	print("[I Like Transit] ", message)