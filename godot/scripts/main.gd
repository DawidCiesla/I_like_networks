extends Node3D

func _ready() -> void:
	GameStore.toast_requested.connect(_on_toast)
	if not GameStore.state_changed.is_connected(_on_state_changed):
		GameStore.state_changed.connect(_on_state_changed)
	_on_state_changed()

func _unhandled_input(event: InputEvent) -> void:
	if (
		event is InputEventKey
		and event.pressed
		and not event.echo
		and event.physical_keycode == KEY_SPACE
	):
		GameStore.set_speed(
			0
			if GameStore.simulation_speed > 0
			else 1
		)

func _on_state_changed() -> void:
	pass

func _on_toast(message: String) -> void:
	print("[I Like Transit] ", message)
