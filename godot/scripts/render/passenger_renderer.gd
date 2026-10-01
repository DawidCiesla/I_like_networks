extends Node3D

const Data = preload("res://scripts/core/game_data.gd")
const Layout = preload("res://scripts/transport/transport_layout.gd")
const Terrain = preload("res://scripts/world/terrain_model.gd")

const MAX_VISIBLE_PER_STATION := 12
const PASSENGERS_PER_MARKER := 2.5

var _crowd_root: Node3D
var _effects_root: Node3D
var _crowds: Dictionary = {}
var _effects: Array[Dictionary] = []
var _last_serial: Dictionary = {}
var _crowd_accumulator := 0.0

func _ready() -> void:
	_crowd_root = Node3D.new()
	_crowd_root.name = "WaitingPassengers"
	add_child(_crowd_root)

	_effects_root = Node3D.new()
	_effects_root.name = "PassengerEffects"
	add_child(_effects_root)

	for line_key in Data.LINE_KEYS:
		var line: Dictionary = GameStore.lines[line_key]
		_last_serial[line_key] = int(line.get("event_serial", 0))

	GameStore.state_changed.connect(_sync_crowds)
	_sync_crowds()

func _process(delta: float) -> void:
	_poll_passenger_events()
	_update_effects(delta)

	_crowd_accumulator += delta
	if _crowd_accumulator >= 0.2:
		_crowd_accumulator = 0.0
		_sync_crowds()

func _sync_crowds() -> void:
	for station_id in Data.all_station_ids():
		var built := GameStore.station_is_built(station_id)
		var waiting := GameStore.station_waiting_passengers(station_id) if built else 0.0
		var count := clampi(ceili(waiting / PASSENGERS_PER_MARKER), 0, MAX_VISIBLE_PER_STATION)
		var crowd: MultiMeshInstance3D = _crowds.get(station_id)

		if crowd == null and built:
			crowd = _create_crowd(station_id)
			_crowds[station_id] = crowd
			_crowd_root.add_child(crowd)

		if crowd == null:
			continue

		crowd.visible = built and count > 0
		if not crowd.visible:
			continue

		crowd.multimesh.visible_instance_count = count
		var station_point := _station_position(station_id)
		var ground := Terrain.height(GameStore.city_seed, station_point.x, station_point.y)

		for index in range(count):
			var angle := float(index) * 2.3999632 + _station_phase(station_id)
			var ring := 15.0 + float(index % 3) * 4.0
			var local := Vector2(cos(angle), sin(angle)) * ring
			var transform := Transform3D.IDENTITY
			transform.origin = Vector3(
				station_point.x + local.x,
				ground + 2.2,
				station_point.y + local.y
			)
			transform = transform.rotated(Vector3.UP, angle + PI)
			crowd.multimesh.set_instance_transform(index, transform)

func _create_crowd(station_id: String) -> MultiMeshInstance3D:
	var body := CapsuleMesh.new()
	body.radius = 0.9
	body.height = 4.2
	body.radial_segments = 5
	body.rings = 3

	var material := StandardMaterial3D.new()
	var hue := fposmod(float(_hash32(station_id)) / 4294967295.0, 1.0)
	material.albedo_color = Color.from_hsv(hue, 0.34, 0.92)
	material.roughness = 0.9
	body.material = material

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.instance_count = MAX_VISIBLE_PER_STATION
	multi.visible_instance_count = 0
	multi.mesh = body

	var instance := MultiMeshInstance3D.new()
	instance.name = "Crowd_%s" % station_id
	instance.multimesh = multi
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance

func _poll_passenger_events() -> void:
	for line_key in Data.LINE_KEYS:
		var line: Dictionary = GameStore.lines[line_key]
		var latest := int(_last_serial.get(line_key, 0))
		var current_serial := int(line.get("event_serial", 0))
		if current_serial < latest:
			latest = 0
			_last_serial[line_key] = 0

		for event in line.get("passenger_events", []):
			var serial := int(event.get("serial", 0))
			if serial <= latest:
				continue
			_spawn_event(line_key, event)
			latest = max(latest, serial)
		_last_serial[line_key] = latest

func _spawn_event(line_key: String, event: Dictionary) -> void:
	var stop_index := int(event.get("stop_index", 0))
	if stop_index < 0 or stop_index >= int(GameStore.lines[line_key].get("stop_count", 0)):
		return

	var station_id: String = Data.STATION_IDS[line_key][stop_index]
	var station_point := Layout.stop_position(line_key, stop_index)
	var ground := Terrain.height(GameStore.city_seed, station_point.x, station_point.y)
	var event_type := str(event.get("type", ""))
	var count := float(event.get("count", 0.0))
	var markers := clampi(ceili(count / 6.0), 1, 5)
	var seed_angle := float(int(event.get("serial", 0)) % 17) * 0.71
	var outward := Vector2(cos(seed_angle), sin(seed_angle))
	var station_world := Vector3(station_point.x, ground + 2.4, station_point.y)
	var outside_world := Vector3(
		station_point.x + outward.x * 28.0,
		ground + 2.4,
		station_point.y + outward.y * 28.0
	)

	var root := Node3D.new()
	root.name = "PassengerEvent_%s_%d" % [line_key, int(event.get("serial", 0))]
	_effects_root.add_child(root)

	for index in range(markers):
		var marker := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 1.2
		sphere.height = 2.4
		sphere.radial_segments = 6
		sphere.rings = 4
		var material := StandardMaterial3D.new()
		material.albedo_color = Data.LINE_COLORS[line_key]
		material.emission_enabled = true
		material.emission = Data.LINE_COLORS[line_key]
		material.emission_energy_multiplier = 0.25
		sphere.material = material
		marker.mesh = sphere
		marker.position = Vector3(float(index - markers / 2) * 1.8, sin(float(index)) * 0.8, 0.0)
		marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(marker)

	var fare := float(event.get("fare", 0.0))
	if event_type == "alight" and fare > 0.0:
		var label := Label3D.new()
		label.text = "+$%d" % roundi(fare)
		label.font_size = 28
		label.outline_size = 8
		label.modulate = Color("#ffe36b")
		label.position.y = 7.0
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		root.add_child(label)

	var start := outside_world if event_type == "board" else station_world
	var finish := station_world if event_type == "board" else outside_world
	root.global_position = start

	_effects.append({
		"node": root,
		"start": start,
		"finish": finish,
		"age": 0.0,
		"duration": 0.65 if event_type == "board" else 0.9,
	})

func _update_effects(delta: float) -> void:
	for index in range(_effects.size() - 1, -1, -1):
		var effect: Dictionary = _effects[index]
		var node: Node3D = effect["node"]
		if not is_instance_valid(node):
			_effects.remove_at(index)
			continue

		effect["age"] = float(effect["age"]) + delta
		var duration: float = maxf(0.01, float(effect["duration"]))
		var t: float = clampf(float(effect["age"]) / duration, 0.0, 1.0)
		var eased := 1.0 - pow(1.0 - t, 3.0)
		var start: Vector3 = effect["start"]
		var finish: Vector3 = effect["finish"]
		node.global_position = start.lerp(finish, eased)
		node.global_position.y += sin(t * PI) * 8.0
		_effects[index] = effect

		if t >= 1.0:
			node.queue_free()
			_effects.remove_at(index)

func _station_position(station_id: String) -> Vector2:
	for line_key in Data.LINE_KEYS:
		var index: int = Data.STATION_IDS[line_key].find(station_id)
		if index >= 0:
			return Layout.stop_position(line_key, index)
	return Vector2.ZERO

func _station_phase(station_id: String) -> float:
	return float(_hash32(station_id) % 6283) / 1000.0

func _hash32(value: String) -> int:
	var hash_value: int = 2166136261
	for index in range(value.length()):
		hash_value = (hash_value ^ value.unicode_at(index)) & 0xffffffff
		hash_value = (hash_value * 16777619) & 0xffffffff
	return hash_value
