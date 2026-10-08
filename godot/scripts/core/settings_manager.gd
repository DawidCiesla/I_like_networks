extends Node

signal settings_changed(section: String, key: String, value: Variant)
signal audio_settings_changed
signal video_settings_changed

const SETTINGS_FILE_PATH := "user://settings.cfg"

var _config: ConfigFile = ConfigFile.new()

var master_volume: float = 1.0:
	set(val):
		master_volume = clampf(val, 0.0, 1.0)
		_save_setting("audio", "master_volume", master_volume)
		_apply_audio()
		audio_settings_changed.emit()

var music_volume: float = 0.8:
	set(val):
		music_volume = clampf(val, 0.0, 1.0)
		_save_setting("audio", "music_volume", music_volume)
		_apply_audio()
		audio_settings_changed.emit()

var sfx_volume: float = 0.9:
	set(val):
		sfx_volume = clampf(val, 0.0, 1.0)
		_save_setting("audio", "sfx_volume", sfx_volume)
		_apply_audio()
		audio_settings_changed.emit()

var fullscreen: bool = false:
	set(val):
		fullscreen = val
		_save_setting("video", "fullscreen", fullscreen)
		_apply_video()
		video_settings_changed.emit()

var vsync: bool = true:
	set(val):
		vsync = val
		_save_setting("video", "vsync", vsync)
		_apply_video()
		video_settings_changed.emit()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_settings()
	_apply_audio()
	_apply_video()


func load_settings() -> void:
	var err := _config.load(SETTINGS_FILE_PATH)
	if err == OK:
		master_volume = float(_config.get_value("audio", "master_volume", 1.0))
		music_volume = float(_config.get_value("audio", "music_volume", 0.8))
		sfx_volume = float(_config.get_value("audio", "sfx_volume", 0.9))
		fullscreen = bool(_config.get_value("video", "fullscreen", false))
		vsync = bool(_config.get_value("video", "vsync", true))
	else:
		save_all()


func save_all() -> void:
	_config.set_value("audio", "master_volume", master_volume)
	_config.set_value("audio", "music_volume", music_volume)
	_config.set_value("audio", "sfx_volume", sfx_volume)
	_config.set_value("video", "fullscreen", fullscreen)
	_config.set_value("video", "vsync", vsync)
	_config.save(SETTINGS_FILE_PATH)


func _save_setting(section: String, key: String, value: Variant) -> void:
	_config.set_value(section, key, value)
	_config.save(SETTINGS_FILE_PATH)
	settings_changed.emit(section, key, value)


func _apply_audio() -> void:
	_set_bus_volume("Master", master_volume)
	_set_bus_volume("Music", music_volume)
	_set_bus_volume("SFX", sfx_volume)


func _set_bus_volume(bus_name: String, linear_val: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx != -1:
		if linear_val <= 0.001:
			AudioServer.set_bus_mute(idx, true)
		else:
			AudioServer.set_bus_mute(idx, false)
			AudioServer.set_bus_volume_db(idx, linear_to_db(linear_val))


func _apply_video() -> void:
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

	# In Godot DisplayServer.VSyncMode: DISABLED = 0, ENABLED = 1
	var vsync_mode := DisplayServer.VSYNC_ENABLED if "VSYNC_ENABLED" in DisplayServer else 1
	var vsync_disabled := DisplayServer.VSYNC_DISABLED if "VSYNC_DISABLED" in DisplayServer else 0
	DisplayServer.window_set_vsync_mode(vsync_mode if vsync else vsync_disabled)
