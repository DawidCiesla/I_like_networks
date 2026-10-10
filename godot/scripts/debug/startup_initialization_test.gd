extends SceneTree

const CityRuntime = preload("res://scripts/city/city_runtime.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var store := root.get_node("GameStore")
	store.suppress_persistence = true
	_expect(store.city.is_empty(), "menu startup leaves the city ungenerated")
	_expect(not store.is_processing(), "menu startup does not simulate or autosave")
	_expect(not store.lines.is_empty(), "lightweight startup preserves line defaults")
	_expect(not store.depot.is_empty(), "lightweight startup preserves depot defaults")

	# A supported saved city must be restored without replacing its contents.
	var payload: Dictionary = store._current_save_payload().duplicate(true)
	payload["world_map"] = MapDefinition.create(MapDefinition.LEGACY_CITY_MAP_ID, 42)
	payload["city"] = CityRuntime.create_initial_city(42, MapDefinition.LEGACY_CITY_MAP_ID)
	payload["city"]["startup_regression_marker"] = "saved-city"
	payload["money"] = 12345.0
	store._apply_payload(payload)
	store.ensure_game_initialized()
	_expect(store.is_processing(), "entering gameplay resumes the simulation")
	_expect(store.money == 12345.0, "gameplay initialization preserves restored money")
	_expect(store.city.get("startup_regression_marker") == "saved-city", "gameplay initialization preserves the loaded city")
	store.set_process(false)

	# Older supported saves without a city still receive the generation fallback.
	payload.erase("city")
	store._apply_payload(payload)
	_expect(not store.city.is_empty(), "city-less saves retain fallback generation")
	if _failures == 0:
		print("STARTUP INITIALIZATION TEST: PASS")
	quit(0 if _failures == 0 else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error(message)
