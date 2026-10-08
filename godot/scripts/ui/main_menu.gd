extends Control
class_name MainMenu

@onready var continue_button: Button = $Panel/Margin/VBox/ContinueButton
@onready var new_game_button: Button = $Panel/Margin/VBox/NewGameButton
@onready var settings_button: Button = $Panel/Margin/VBox/SettingsButton
@onready var quit_button: Button = $Panel/Margin/VBox/QuitButton

@onready var seed_dialog: ConfirmationDialog = $SeedDialog
@onready var seed_input: LineEdit = $SeedDialog/Margin/VBox/SeedInput
@onready var settings_menu: SettingsMenu = $SettingsMenu


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var store := get_node_or_null("/root/GameStore")
	if is_instance_valid(store):
		store.suppress_persistence = true

	if is_instance_valid(continue_button):
		continue_button.disabled = not FileAccess.file_exists("user://save_godot_v2.json")
		continue_button.pressed.connect(_on_continue_pressed)

	if is_instance_valid(new_game_button):
		new_game_button.pressed.connect(_on_new_game_pressed)

	if is_instance_valid(settings_button):
		settings_button.pressed.connect(_on_settings_pressed)

	if is_instance_valid(quit_button):
		quit_button.pressed.connect(_on_quit_pressed)

	if is_instance_valid(seed_dialog):
		seed_dialog.confirmed.connect(_on_seed_confirmed)


func _on_continue_pressed() -> void:
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("click")
	var store := get_node_or_null("/root/GameStore")
	if is_instance_valid(store):
		store.suppress_persistence = false
		store.load_game()
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_new_game_pressed() -> void:
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("click")
	if is_instance_valid(seed_input):
		seed_input.text = str(randi() % 1000000 + 1)
	if is_instance_valid(seed_dialog):
		seed_dialog.popup_centered()


func _on_seed_confirmed() -> void:
	var seed_val := 42
	if is_instance_valid(seed_input) and seed_input.text.is_valid_int():
		seed_val = int(seed_input.text)
	var store := get_node_or_null("/root/GameStore")
	if is_instance_valid(store):
		store.suppress_persistence = false
		store.clear_save_and_reset(seed_val)
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_settings_pressed() -> void:
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("click")
	if is_instance_valid(settings_menu):
		settings_menu.show()


func _on_quit_pressed() -> void:
	get_tree().quit()
