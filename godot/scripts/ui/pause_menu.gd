extends Control
class_name PauseMenu

signal resumed
signal back_to_menu_requested

@onready var resume_button: Button = $Panel/Margin/VBox/ResumeButton
@onready var save_button: Button = $Panel/Margin/VBox/SaveButton
@onready var settings_button: Button = $Panel/Margin/VBox/SettingsButton
@onready var menu_button: Button = $Panel/Margin/VBox/MenuButton
@onready var settings_menu: SettingsMenu = $SettingsMenu


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	hide()
	if is_instance_valid(settings_menu):
		settings_menu.hide()
		settings_menu.closed.connect(_on_settings_closed)

	if is_instance_valid(resume_button):
		resume_button.pressed.connect(_on_resume_pressed)
	if is_instance_valid(save_button):
		save_button.pressed.connect(_on_save_pressed)
	if is_instance_valid(settings_button):
		settings_button.pressed.connect(_on_settings_pressed)
	if is_instance_valid(menu_button):
		menu_button.pressed.connect(_on_menu_pressed)


func open() -> void:
	show()
	get_tree().paused = true
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("select")


func close() -> void:
	hide()
	if is_instance_valid(settings_menu):
		settings_menu.hide()
	get_tree().paused = false
	resumed.emit()


func _on_resume_pressed() -> void:
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("click")
	close()


func _on_save_pressed() -> void:
	var store := get_node_or_null("/root/GameStore")
	if is_instance_valid(store):
		store.save_game()
		store.toast_requested.emit("GAME SAVED")
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("cash")


func _on_settings_pressed() -> void:
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("click")
	if is_instance_valid(settings_menu):
		settings_menu.show()


func _on_settings_closed() -> void:
	pass


func _on_menu_pressed() -> void:
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("click")
	var store := get_node_or_null("/root/GameStore")
	if is_instance_valid(store):
		store.save_game()
		store.suppress_persistence = true

	get_tree().paused = false
	back_to_menu_requested.emit()
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
