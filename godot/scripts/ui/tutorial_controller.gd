extends Control
class_name TutorialController

signal tutorial_completed

enum Step {
	WELCOME_AND_ROAD = 0,
	DEPOT_AND_BUS = 1,
	CREATE_FIRST_LINE = 2,
	NETWORK_EXPANSION = 3,
	COMPLETED = 4
}

var current_step: Step = Step.WELCOME_AND_ROAD

@onready var panel: PanelContainer = $Panel
@onready var step_title: Label = $Panel/Margin/VBox/Header/Title
@onready var step_body: Label = $Panel/Margin/VBox/Body
@onready var skip_button: Button = $Panel/Margin/VBox/Actions/SkipButton
@onready var next_button: Button = $Panel/Margin/VBox/Actions/NextButton

var _last_road_count := 0
var _last_bus_count := 0
var _last_line_count := 0


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


func _on_store_changed() -> void:
	var store := get_node_or_null("/root/GameStore")
	if not is_instance_valid(store):
		return

	match current_step:
		Step.WELCOME_AND_ROAD:
			# Check if player built at least one road
			var roads: Array = store.city.get("roads", [])
			if roads.size() > _last_road_count and _last_road_count > 0:
				advance_step(Step.DEPOT_AND_BUS)
			elif _last_road_count == 0:
				_last_road_count = roads.size()

		Step.DEPOT_AND_BUS:
			# Check if depot exists and has at least 1 bus
			var fleet: Array = store.transit_network.get("fleet", [])
			var depot_built: bool = store.city.get("depot_built", false) or store.has_depot()
			if depot_built and fleet.size() > 0:
				advance_step(Step.CREATE_FIRST_LINE)

		Step.CREATE_FIRST_LINE:
			# Check if at least 1 active transit line exists
			var lines: Array = store.transit_network.get("lines", [])
			if lines.size() > 0:
				advance_step(Step.NETWORK_EXPANSION)

		Step.NETWORK_EXPANSION:
			# Step is completed once passengers start travelling or cash > starting cash
			if store.money > 12000 or store.city.get("total_passengers_served", 0) > 0:
				advance_step(Step.COMPLETED)


func advance_step(next_step: Step) -> void:
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
	match current_step:
		Step.WELCOME_AND_ROAD:
			step_title.text = "TUTORIAL 1/4: REGIONAL INFRASTRUCTURE"
			step_body.text = "Welcome to I Like Transit!\n\nYour settlements need transit connections. Select the ROAD BUILDER tool on the bottom panel, click a settlement road endpoint, and drag to connect another settlement."
			next_button.text = "I'VE BUILT IT"

		Step.DEPOT_AND_BUS:
			step_title.text = "TUTORIAL 2/4: FLEET & DEPOT"
			step_body.text = "Now you need vehicles. Place a Bus Depot along your built road, then click the Depot to purchase your first starter bus."
			next_button.text = "DEPOT READY"

		Step.CREATE_FIRST_LINE:
			step_title.text = "TUTORIAL 3/4: FIRST TRANSIT LINE"
			step_body.text = "Click 'CREATE LINE' in the bottom toolbar. Select two or more stops along your road to open your first passenger route!"
			next_button.text = "LINE OPENED"

		Step.NETWORK_EXPANSION:
			step_title.text = "TUTORIAL 4/4: REVENUE & ADVANCEMENT"
			step_body.text = "Passengers will board your buses and pay fares upon reaching their destination. Reinvest profits to unlock Trams, Metro and City Services!"
			next_button.text = "FINISH TUTORIAL"


func _on_next_pressed() -> void:
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("click")

	if current_step < Step.COMPLETED:
		advance_step(Step(int(current_step) + 1))


func _on_skip_pressed() -> void:
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("click")
	current_step = Step.COMPLETED
	hide()
	tutorial_completed.emit()
