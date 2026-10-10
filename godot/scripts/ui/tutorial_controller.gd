extends Control
class_name TutorialController

signal tutorial_completed

const RegionalTutorialProgress = preload("res://scripts/ui/regional_tutorial_progress.gd")

enum Step {
	WELCOME_AND_ROAD = 0,
	DEPOT_AND_BUS = 1,
	CREATE_FIRST_LINE = 2,
	NETWORK_EXPANSION = 3,
	COMPLETED = 4
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

	# Re-evaluate sequentially so a loaded game that already satisfies several
	# tutorial milestones advances to the first genuinely unfinished action.
	var guard := 0
	var progressed := true
	while progressed and guard < 5 and current_step < Step.COMPLETED:
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
	# Tutorial progression is state-driven. The action button is retained by the
	# scene for layout compatibility but cannot manually skip validation.
	next_button.disabled = true
	match current_step:
		Step.WELCOME_AND_ROAD:
			step_title.text = "TUTORIAL 1/4: REGIONAL INFRASTRUCTURE"
			step_body.text = "Build your first player road. Select ROAD BUILDER on the bottom panel and connect the regional network toward another settlement. The tutorial advances when a completed player-funded road exists."
			next_button.text = "WAITING FOR ROAD"

		Step.DEPOT_AND_BUS:
			step_title.text = "TUTORIAL 2/4: DEPOT"
			step_body.text = "Place a Bus Depot along the connected road network. The depot provides garage capacity for the vehicles assigned to your lines."
			next_button.text = "WAITING FOR DEPOT"

		Step.CREATE_FIRST_LINE:
			step_title.text = "TUTORIAL 3/4: FIRST TRANSIT LINE"
			step_body.text = "Create an active passenger line with at least two stops and a vehicle in service. Its real headway, traffic delay and operating balance will appear in Line Operations."
			next_button.text = "WAITING FOR SERVICE"

		Step.NETWORK_EXPANSION:
			var store := get_node_or_null("/root/GameStore")
			var progress := {"current": 0.0, "target": RegionalTutorialProgress.PASSENGER_TARGET}
			if is_instance_valid(store):
				progress = RegionalTutorialProgress.passenger_progress(store.stats)
			step_title.text = "TUTORIAL 4/4: PROVE THE SERVICE"
			step_body.text = "Let the line carry passengers to their destinations. Deliver %.0f / %.0f passengers. Watch Network Alerts, Traffic Map [T] and the line operating balance while the service runs." % [
				float(progress.get("current", 0.0)),
				float(progress.get("target", RegionalTutorialProgress.PASSENGER_TARGET)),
			]
			next_button.text = "WAITING FOR PASSENGERS"


func _on_next_pressed() -> void:
	# Manual completion was intentionally removed: every tutorial step now has a
	# measurable GameStore condition. Keep the handler because the scene still
	# contains the legacy button and may dispatch an input event during migration.
	_on_store_changed()


func _on_skip_pressed() -> void:
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("click")
	current_step = Step.COMPLETED
	hide()
	tutorial_completed.emit()