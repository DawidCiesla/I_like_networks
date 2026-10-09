extends Node3D

const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const BuildingDetailRenderer = preload("res://scripts/render/building_detail_renderer.gd")

@onready var _environment_controller: Node3D = $WorldEnvironmentController
@onready var _pause_menu: PauseMenu = $PauseCanvas/PauseMenu

var _building_detail_renderer: BuildingDetailRenderer


func _ready() -> void:
	GameStore.toast_requested.connect(_on_toast)
	if not GameStore.state_changed.is_connected(_on_state_changed):
		GameStore.state_changed.connect(_on_state_changed)
	_setup_regional_visual_detail()
	_on_state_changed()


func _setup_regional_visual_detail() -> void:
	var map_definition := MapDefinition.active_definition()
	if str(map_definition.get("id", MapDefinition.LEGACY_CITY_MAP_ID)) == MapDefinition.LEGACY_CITY_MAP_ID:
		return
	if _building_detail_renderer != null:
		return
	_building_detail_renderer = BuildingDetailRenderer.new()
	_building_detail_renderer.name = "BuildingDetails"
	add_child(_building_detail_renderer)


func _process(_delta: float) -> void:
	if not is_instance_valid(_environment_controller):
		return
	var simulation_seconds := maxf(0.0, float(GameStore.city.get("time_seconds", 0.0)))
	_environment_controller.call("set_time_of_day", 8.0 + simulation_seconds / 3600.0)


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


func _on_state_changed() -> void:
	pass


func _on_toast(message: String) -> void:
	print("[I Like Transit] ", message)
