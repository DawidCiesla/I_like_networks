extends Control
class_name TutorialController

signal tutorial_completed

const RegionalTutorialProgress = preload("res://scripts/ui/regional_tutorial_progress.gd")

enum Step {
	WELCOME_AND_ROAD = 0,
	DEPOT_AND_BUS = 1,
	CREATE_FIRST_LINE = 2,
	NETWORK_EXPANSION = 3,
	POSITIVE_OPERATIONS = 4,
	COMPLETED = 5
}

var current_step: int = Step.WELCOME_AND_ROAD

@onready var panel: PanelContainer = $Panel
@onready var step_title: Label = $Panel/Margin/VBox/Header/Title
@onready var step_body: Label = $Panel/Margin/VBox/Body
@onready var skip_button: Button = $Panel/Margin/VBox/Actions/SkipButton
@onready var next_button: Button = $Panel/Margin/VBox/Actions/NextButton


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var store := get_node_or_null("/root/GameStore")
	if is_instance_valid(store):
		store.state_changed.connect(_on_store_changed)
		store.city_changed.connect(_on_store_changed)
	if is_instance_valid(skip_button):
		skip_button.pressed.connect(_on_skip_pressed)
	if is_instance_valid(next_button):
		next_button.pressed.connect(_on_next_pressed)
	_update_step_ui()
	_on_store_changed()


func _on_store_changed() -> void:
	var store := get_node_or_null("/root/GameStore")
	if not is_instance_valid(store):
		return
	# Loaded saves advance through every milestone already supported by their
	# canonical state; no tutorial step depends on a manual acknowledgement.
	var guard := 0
	var progressed := true
	while progressed and guard < 6 and current_step < Step.COMPLETED:
		guard += 1
		progressed = false
		match current_step:
			Step.WELCOME_AND_ROAD:
				if RegionalTutorialProgress.has_player_road(store.city):
					advance_step(Step.DEPOT_AND_BUS)
					progressed = true
			Step.DEPOT_AND_BUS:
				if store.has_method("has_depot") and bool(store.call("has_depot")):
					advance_step(Step.CREATE_FIRST_LINE)
					progressed = true
			Step.CREATE_FIRST_LINE:
				if RegionalTutorialProgress.has_operating_line(store.transit_network):
					advance_step(Step.NETWORK_EXPANSION)
					progressed = true
			Step.NETWORK_EXPANSION:
				if RegionalTutorialProgress.passenger_target_met(store.stats):
					advance_step(Step.POSITIVE_OPERATIONS)
					progressed = true
			Step.POSITIVE_OPERATIONS:
				if RegionalTutorialProgress.positive_operating_cashflow(store.city):
					advance_step(Step.COMPLETED)
					progressed = true
	if current_step < Step.COMPLETED:
		_update_step_ui()


func advance_step(next_step: int) -> void:
	if next_step == current_step:
		return
	current_step = next_step
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("upgrade")
	_update_step_ui()
	if current_step == Step.COMPLETED:
		tutorial_completed.emit()


func _update_step_ui() -> void:
	if current_step == Step.COMPLETED:
		hide()
		return
	show()
	next_button.disabled = true
	match current_step:
		Step.WELCOME_AND_ROAD:
			step_title.text = "TUTORIAL 1/5: REGIONAL INFRASTRUCTURE"
			step_body.text = "Build your first player road. Select ROAD BUILDER and connect the regional network toward another settlement. This step advances only after construction is complete."
			next_button.text = "WAITING FOR ROAD"
		Step.DEPOT_AND_BUS:
			step_title.text = "TUTORIAL 2/5: DEPOT"
			step_body.text = "Place a Bus Depot along the connected road network. It provides garage capacity for vehicles assigned to your lines."
			next_button.text = "WAITING FOR DEPOT"
		Step.CREATE_FIRST_LINE:
			step_title.text = "TUTORIAL 3/5: FIRST TRANSIT LINE"
			step_body.text = "Create an active passenger line with at least two stops and a vehicle in service. The tutorial detects the real custom line and fleet state."
			next_button.text = "WAITING FOR SERVICE"
		Step.NETWORK_EXPANSION:
			var store := get_node_or_null("/root/GameStore")
			var progress := {"current": 0.0, "target": RegionalTutorialProgress.PASSENGER_TARGET}
			if is_instance_valid(store):
				progress = RegionalTutorialProgress.passenger_progress(store.stats)
			step_title.text = "TUTORIAL 4/5: PROVE THE SERVICE"
			step_body.text = "Let the line carry passengers. Deliver %.0f / %.0f passengers while watching demand, traffic and fleet performance." % [float(progress.get("current", 0.0)), float(progress.get("target", RegionalTutorialProgress.PASSENGER_TARGET))]
			next_button.text = "WAITING FOR PASSENGERS"
		Step.POSITIVE_OPERATIONS:
			var store := get_node_or_null("/root/GameStore")
			var cashflow := {"available": false, "net_per_minute": 0.0}
			if is_instance_valid(store):
				cashflow = RegionalTutorialProgress.operating_cashflow(store.city)
			step_title.text = "TUTORIAL 5/5: SUSTAIN THE NETWORK"
			step_body.text = "Make current operations profitable. Net operating cashflow: %s$%.1f/min. Adjust routes, ridership or fleet size until it is positive." % ["+" if float(cashflow.get("net_per_minute", 0.0)) >= 0.0 else "−", absf(float(cashflow.get("net_per_minute", 0.0)))]
			next_button.text = "WAITING FOR POSITIVE CASHFLOW"


func _on_next_pressed() -> void:
	_on_store_changed()


func _on_skip_pressed() -> void:
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("click")
	current_step = Step.COMPLETED
	hide()
	tutorial_completed.emit()
