extends Control
class_name SettingsMenu

signal closed

@onready var master_slider: HSlider = $Panel/Margin/VBox/AudioSection/MasterRow/Slider
@onready var master_val_label: Label = $Panel/Margin/VBox/AudioSection/MasterRow/ValLabel

@onready var music_slider: HSlider = $Panel/Margin/VBox/AudioSection/MusicRow/Slider
@onready var music_val_label: Label = $Panel/Margin/VBox/AudioSection/MusicRow/ValLabel

@onready var sfx_slider: HSlider = $Panel/Margin/VBox/AudioSection/SFXRow/Slider
@onready var sfx_val_label: Label = $Panel/Margin/VBox/AudioSection/SFXRow/ValLabel

@onready var fullscreen_check: CheckBox = $Panel/Margin/VBox/VideoSection/FullscreenRow/CheckBox
@onready var vsync_check: CheckBox = $Panel/Margin/VBox/VideoSection/VSyncRow/CheckBox
@onready var back_button: Button = $Panel/Margin/VBox/BackButton


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_sync_ui_with_settings()

	if is_instance_valid(master_slider):
		master_slider.value_changed.connect(_on_master_changed)
	if is_instance_valid(music_slider):
		music_slider.value_changed.connect(_on_music_changed)
	if is_instance_valid(sfx_slider):
		sfx_slider.value_changed.connect(_on_sfx_changed)
	if is_instance_valid(fullscreen_check):
		fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	if is_instance_valid(vsync_check):
		vsync_check.toggled.connect(_on_vsync_toggled)
	if is_instance_valid(back_button):
		back_button.pressed.connect(_on_back_pressed)


func _sync_ui_with_settings() -> void:
	var sm := get_node_or_null("/root/SettingsManager")
	if not is_instance_valid(sm):
		return

	if is_instance_valid(master_slider):
		master_slider.value = sm.master_volume * 100.0
		master_val_label.text = "%d%%" % int(master_slider.value)

	if is_instance_valid(music_slider):
		music_slider.value = sm.music_volume * 100.0
		music_val_label.text = "%d%%" % int(music_slider.value)

	if is_instance_valid(sfx_slider):
		sfx_slider.value = sm.sfx_volume * 100.0
		sfx_val_label.text = "%d%%" % int(sfx_slider.value)

	if is_instance_valid(fullscreen_check):
		fullscreen_check.button_pressed = sm.fullscreen

	if is_instance_valid(vsync_check):
		vsync_check.button_pressed = sm.vsync


func _on_master_changed(val: float) -> void:
	var sm := get_node_or_null("/root/SettingsManager")
	if is_instance_valid(sm):
		sm.master_volume = val / 100.0
	if is_instance_valid(master_val_label):
		master_val_label.text = "%d%%" % int(val)


func _on_music_changed(val: float) -> void:
	var sm := get_node_or_null("/root/SettingsManager")
	if is_instance_valid(sm):
		sm.music_volume = val / 100.0
	if is_instance_valid(music_val_label):
		music_val_label.text = "%d%%" % int(val)


func _on_sfx_changed(val: float) -> void:
	var sm := get_node_or_null("/root/SettingsManager")
	if is_instance_valid(sm):
		sm.sfx_volume = val / 100.0
	if is_instance_valid(sfx_val_label):
		sfx_val_label.text = "%d%%" % int(val)
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("click")


func _on_fullscreen_toggled(pressed: bool) -> void:
	var sm := get_node_or_null("/root/SettingsManager")
	if is_instance_valid(sm):
		sm.fullscreen = pressed


func _on_vsync_toggled(pressed: bool) -> void:
	var sm := get_node_or_null("/root/SettingsManager")
	if is_instance_valid(sm):
		sm.vsync = pressed


func _on_back_pressed() -> void:
	var am := get_node_or_null("/root/AudioManager")
	if is_instance_valid(am):
		am.play_sfx("click")
	hide()
	closed.emit()
