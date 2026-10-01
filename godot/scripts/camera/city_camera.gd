extends Node3D

@onready var camera: Camera3D = $Camera3D

@export var distance := 1350.0
@export var min_distance := 180.0
@export var max_distance := 4200.0
@export var zoom_speed := 0.12
@export var rotate_speed := 0.006
@export var pan_speed := 0.00125

var yaw := -0.72
var pitch := 0.72
var _drag_button := 0

func _ready() -> void:
	reset_view()

func reset_view() -> void:
	position = Vector3(-260.0, 0.0, -120.0)
	distance = 1350.0
	yaw = -0.72
	pitch = 0.72
	_update_camera()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			distance = max(min_distance, distance * (1.0 - zoom_speed))
			_update_camera()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			distance = min(max_distance, distance * (1.0 + zoom_speed))
			_update_camera()
			get_viewport().set_input_as_handled()
		elif event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			if GameStore.route_editor_active():
				_drag_button = 0
			else:
				_drag_button = event.button_index if event.pressed else 0

	elif event is InputEventMouseMotion and _drag_button != 0:
		if _drag_button == MOUSE_BUTTON_LEFT:
			yaw -= event.relative.x * rotate_speed
			pitch = clamp(pitch - event.relative.y * rotate_speed, 0.18, 1.42)
		else:
			_pan(event.relative)
		_update_camera()
		get_viewport().set_input_as_handled()

	if (
		event is InputEventKey
		and event.pressed
		and not event.echo
		and event.physical_keycode == KEY_F
	):
		reset_view()
		get_viewport().set_input_as_handled()

func _pan(relative: Vector2) -> void:
	var right := camera.global_transform.basis.x
	var forward := -camera.global_transform.basis.z
	right.y = 0.0
	forward.y = 0.0
	right = right.normalized()
	forward = forward.normalized()

	var scale := distance * pan_speed
	position += (-right * relative.x + forward * relative.y) * scale

func _update_camera() -> void:
	var horizontal := cos(pitch) * distance
	var vertical := sin(pitch) * distance
	camera.position = Vector3(
		sin(yaw) * horizontal,
		vertical,
		cos(yaw) * horizontal
	)
	camera.look_at(global_position, Vector3.UP)
