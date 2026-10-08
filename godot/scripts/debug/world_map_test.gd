extends SceneTree

const Data = preload("res://scripts/core/game_data.gd")
const StoreScript = preload("res://scripts/core/game_store.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")
const BrowserImporter = preload("res://scripts/persistence/browser_save_importer.gd")

var _failed := false

func _init() -> void:
	var store_script: GDScript = StoreScript
	if not store_script.can_instantiate():
		push_error("WORLD MAP TEST: GameStore failed to compile; skipping dependent checks")
		quit(1)
		return
	_test_legacy_map_definition()
	_test_save_v2_migration_preserves_city()
	_test_save_recovery_prefers_primary_then_last_good_backup()
	_test_save_transaction_retains_the_previous_valid_payload()
	_test_native_save_copy_exports_and_loads_without_loss()
	_test_new_region_seed_is_reproducible()
	_test_sandbox_payload_preserves_runtime_state()
	_test_terrain_brush_persists_and_updates_surface()
	_test_browser_import_selects_legacy_map()
	if _failed:
		push_error("WORLD MAP TEST: FAIL")
		quit(1)
		return
	print("WORLD MAP TEST: PASS")
	quit(0)

func _test_legacy_map_definition() -> void:
	var definition := MapDefinition.create(MapDefinition.LEGACY_CITY_MAP_ID, 78123)
	_expect(int(definition.get("schema_version", 0)) == MapDefinition.SCHEMA_VERSION)
	_expect(str(definition.get("id", "")) == MapDefinition.LEGACY_CITY_MAP_ID)
	_expect(int(definition.get("seed", 0)) == 78123)
	_expect(definition.get("outside_connections", []).size() == 4)
	var serialized_bounds := MapDefinition.rect_from_payload(definition)
	var derived_bounds := MapDefinition.bounds_for(MapDefinition.LEGACY_CITY_MAP_ID)
	_expect(serialized_bounds.position.distance_to(derived_bounds.position) < 0.001)
	_expect(serialized_bounds.size.distance_to(derived_bounds.size) < 0.001)
	MapDefinition.set_active(definition)
	var rendered_bounds := TerrainSurface.world_bounds()
	_expect(rendered_bounds.position.distance_to(derived_bounds.position) < 0.001)
	_expect(rendered_bounds.size.distance_to(derived_bounds.size) < 0.001)

func _test_save_v2_migration_preserves_city() -> void:
	var store = StoreScript.new()
	store.suppress_persistence = true
	store.reset_state(false)
	_expect(store.world_map.get("outside_connections", []).size() == store.city.get("outside_connections", []).size())
	var saved_city: Dictionary = store.city.duplicate(true)
	saved_city["time_seconds"] = 123.5
	saved_city["migration_marker"] = "keep"
	var saved_road_count: int = saved_city.get("roads", []).size()
	store._apply_payload({
		"version": 2,
		"city_seed": 456789,
		"city": saved_city,
		"money": 987.0,
	})
	_expect(str(store.world_map.get("id", "")) == MapDefinition.LEGACY_CITY_MAP_ID)
	_expect(int(store.world_map.get("seed", 0)) == 456789)
	_expect(is_equal_approx(float(store.city.get("time_seconds", 0.0)), 123.5))
	_expect(str(store.city.get("migration_marker", "")) == "keep")
	_expect(store.city.get("roads", []).size() == saved_road_count)
	_expect(str(store.city.get("world_map_id", "")) == MapDefinition.LEGACY_CITY_MAP_ID)
	_expect(is_equal_approx(float(store.money), 987.0))
	store.free()

func _test_save_recovery_prefers_primary_then_last_good_backup() -> void:
	var prefix := "/tmp/ilike-network-save-recovery-%d" % Time.get_ticks_usec()
	var primary_path := prefix + ".json"
	var backup_path := prefix + ".bak"
	var temporary_path := prefix + ".tmp"
	_write_test_save(primary_path, "{")
	_write_test_save(backup_path, JSON.stringify({"version": Data.GAME_VERSION, "money": 4321.0, "city": {}}))
	_write_test_save(temporary_path, JSON.stringify({"version": Data.GAME_VERSION, "money": 123.0, "city": {}}))
	var recovered := StoreScript._load_supported_save(primary_path, backup_path, temporary_path)
	_expect(bool(recovered.get("recovered", false)))
	_expect(str(recovered.get("source_path", "")) == backup_path)
	_expect(is_equal_approx(float(recovered.get("payload", {}).get("money", 0.0)), 4321.0))

	_write_test_save(primary_path, JSON.stringify({"version": Data.GAME_VERSION, "money": 7654.0, "city": {}}))
	var primary := StoreScript._load_supported_save(primary_path, backup_path, temporary_path)
	_expect(not bool(primary.get("recovered", true)))
	_expect(str(primary.get("source_path", "")) == primary_path)
	_expect(is_equal_approx(float(primary.get("payload", {}).get("money", 0.0)), 7654.0))

	_write_test_save(primary_path, JSON.stringify({"version": Data.GAME_VERSION + 1, "money": 1.0, "city": {}}))
	var fallback := StoreScript._load_supported_save(primary_path, backup_path, temporary_path)
	_expect(str(fallback.get("source_path", "")) == backup_path)
	for path in [primary_path, backup_path, temporary_path]:
		DirAccess.remove_absolute(path)

func _write_test_save(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null)
	if file == null:
		return
	file.store_string(contents)
	file.flush()
	file.close()

func _test_save_transaction_retains_the_previous_valid_payload() -> void:
	var prefix := "/tmp/ilike-network-save-transaction-%d" % Time.get_ticks_usec()
	var primary_path := prefix + ".json"
	var backup_path := primary_path + ".bak"
	var temporary_path := primary_path + ".tmp"
	var corrupt_path := primary_path + ".corrupt"
	var first_payload := {"version": Data.GAME_VERSION, "money": 100.0}
	var second_payload := {"version": Data.GAME_VERSION, "money": 200.0}
	var third_payload := {"version": Data.GAME_VERSION, "money": 300.0}
	_expect(StoreScript._write_save_payload_atomically(primary_path, first_payload))
	_expect(StoreScript._write_save_payload_atomically(primary_path, second_payload))
	_expect(is_equal_approx(float(StoreScript._read_supported_save(primary_path).get("money", 0.0)), 200.0))
	_expect(is_equal_approx(float(StoreScript._read_supported_save(backup_path).get("money", 0.0)), 100.0))

	_write_test_save(primary_path, "{")
	_expect(StoreScript._write_save_payload_atomically(primary_path, third_payload))
	_expect(is_equal_approx(float(StoreScript._read_supported_save(primary_path).get("money", 0.0)), 300.0))
	_expect(is_equal_approx(float(StoreScript._read_supported_save(backup_path).get("money", 0.0)), 100.0))
	_expect(FileAccess.file_exists(corrupt_path))
	for path in [primary_path, backup_path, temporary_path, corrupt_path]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)

func _test_native_save_copy_exports_and_loads_without_loss() -> void:
	var path := "/tmp/ilike-network-save-copy-%d.json" % Time.get_ticks_usec()
	var source = StoreScript.new()
	source.suppress_persistence = true
	source.reset_state(false)
	source.money = 87654.0
	source.city["save_copy_marker"] = "retain-city"
	_expect(source.export_save_copy(path))
	var exported := StoreScript._read_supported_save(path)
	_expect(not exported.is_empty())
	_expect(is_equal_approx(float(exported.get("money", 0.0)), 87654.0))
	var destination = StoreScript.new()
	destination.suppress_persistence = true
	_expect(destination.import_browser_save(path))
	_expect(is_equal_approx(float(destination.money), 87654.0))
	_expect(str(destination.city.get("save_copy_marker", "")) == "retain-city")
	_expect(int(destination.city_seed) == int(exported.get("city_seed", -1)))
	source.free()
	destination.free()
	for suffix in ["", ".bak", ".tmp", ".corrupt"]:
		var cleanup_path: String = path + str(suffix)
		if FileAccess.file_exists(cleanup_path):
			DirAccess.remove_absolute(cleanup_path)

func _test_new_region_seed_is_reproducible() -> void:
	var store = StoreScript.new()
	store.suppress_persistence = true
	var seed := 82419
	store.clear_save_and_reset(seed)
	var first_settlements: Array = store.city.get("regional_settlements", []).duplicate(true)
	var first_roads: Array = store.city.get("roads", []).duplicate(true)
	_expect(int(store.city_seed) == seed)
	store.clear_save_and_reset(seed)
	_expect(JSON.stringify(first_settlements) == JSON.stringify(store.city.get("regional_settlements", [])))
	_expect(JSON.stringify(first_roads) == JSON.stringify(store.city.get("roads", [])))
	store.free()

func _test_browser_import_selects_legacy_map() -> void:
	var payload := BrowserImporter.convert_browser_save({
		"version": 12,
		"money": 10.0,
		"city": {"seed": 2468},
	})
	_expect(int(payload.get("version", 0)) == Data.GAME_VERSION)
	_expect(str(payload.get("world_map", {}).get("id", "")) == MapDefinition.LEGACY_CITY_MAP_ID)
	_expect(int(payload.get("world_map", {}).get("seed", 0)) == 2468)
	_expect(payload.get("world_map", {}).has("terrain_edits"))

func _test_sandbox_payload_preserves_runtime_state() -> void:
	var store = StoreScript.new()
	store.suppress_persistence = true
	store.city_seed = 96322
	store.reset_state(false)
	var saved_city: Dictionary = store.city.duplicate(true)
	saved_city["payload_marker"] = "preserve-sandbox"
	var expected_road_count := (saved_city.get("roads", []) as Array).size()
	var persisted_health := {
		"schema_version": 2,
		"elapsed_years": 0.5,
		"districts": {"saved-settlement": {
			"population": 100.0,
			"observed_population": 100.0,
			"cohorts": {"adults": {
				"age_group": "adults",
				"population": 100.0,
				"health_index": 81.0,
				"underlying_health_index": 82.0,
				"planning_health_index": 82.0,
				"acute_cases": 4.0,
				"chronic_cases": 12.0,
			}},
		}},
	}
	saved_city["resident_health_state"] = persisted_health.duplicate(true)
	saved_city["service_buildings"] = [{
		"id": "player-clinic-save",
		"settlementId": "saved-settlement",
		"service": "healthcare",
		"source": "player",
		"status": "operational",
		"capacity": 250.0,
	}]
	var saved_roads: Array = saved_city.get("roads", [])
	if not saved_roads.is_empty():
		var persisted_road: Dictionary = saved_roads[0]
		persisted_road["a"] = "saved-node-a"
		persisted_road["b"] = "saved-node-b"
		persisted_road["graphEndpointIds"] = ["saved-node-a", "saved-node-b"]
	var saved_depot := {
		"built": true,
		"garage_slots": 4,
		"level": 0,
		"position": {"x": 320.0, "y": -240.0},
	}
	var saved_network: Dictionary = store.transit_network.duplicate(true)
	var saved_stops: Dictionary = saved_network.get("stops", {})
	saved_stops["payload-stop"] = {
		"id": "payload-stop",
		"x": 320.0,
		"y": -240.0,
		"status": "built",
		"served_line_ids": [],
	}
	saved_network["stops"] = saved_stops
	saved_network["unlocked_modes"] = {"bus": true, "tram": true, "metro": true}
	store._apply_payload({
		"version": Data.GAME_VERSION,
		"money": 54321.0,
		"city_seed": store.city_seed,
		"world_map": store.world_map.duplicate(true),
		"lines": store.lines.duplicate(true),
		"stations": store.stations.duplicate(true),
		"depot": saved_depot,
		"stats": store.stats.duplicate(true),
		"city": saved_city,
		"transit_network": saved_network,
	})
	_expect(str(store.world_map.get("id", "")) == MapDefinition.DEFAULT_MAP_ID)
	_expect(is_equal_approx(float(store.money), 54321.0))
	_expect((store.city.get("roads", []) as Array).size() == expected_road_count)
	_expect(str(store.city.get("payload_marker", "")) == "preserve-sandbox")
	_expect(bool(store.depot.get("built", false)))
	_expect(store.transit_network.get("stops", {}).has("payload-stop"))
	_expect(store.transit_network.get("unlocked_modes", {}).get("tram", false))
	_expect(store.transit_network.get("unlocked_modes", {}).get("metro", false))
	_expect(store.city.get("resident_health_state", {}) == persisted_health)
	var saved_services: Array = store.city.get("service_buildings", [])
	_expect(not saved_services.is_empty() and str(saved_services[0].get("id", "")) == "player-clinic-save")
	var loaded_roads: Array = store.city.get("roads", [])
	if not loaded_roads.is_empty():
		_expect(str(loaded_roads[0].get("a", "")) == "saved-node-a")
		_expect(loaded_roads[0].get("graphEndpointIds", []) == ["saved-node-a", "saved-node-b"])
	store.free()


func _test_terrain_brush_persists_and_updates_surface() -> void:
	var store = StoreScript.new()
	store.suppress_persistence = true
	store.city_seed = 96321
	store.world_map = MapDefinition.create(MapDefinition.LEGACY_CITY_MAP_ID, store.city_seed)
	MapDefinition.set_active(store.world_map)
	TerrainSurface.set_terrain_edit_payload(store.world_map.get("terrain_edits", {}))
	var center := Vector2.ZERO
	var before := TerrainSurface.height(store.city_seed, center.x, center.y)
	var result: Dictionary = store.raise_terrain(center, 120.0, 6.0)
	_expect(bool(result.get("ok", false)))
	var after := TerrainSurface.height(store.city_seed, center.x, center.y)
	_expect(is_equal_approx(after - before, 6.0))
	var serialized: Variant = JSON.parse_string(JSON.stringify(store.world_map.get("terrain_edits", {})))
	_expect(typeof(serialized) == TYPE_DICTIONARY)
	if typeof(serialized) == TYPE_DICTIONARY:
		var loaded_map: Dictionary = store.world_map.duplicate(true)
		loaded_map["terrain_edits"] = serialized
		MapDefinition.set_active(loaded_map)
		TerrainSurface.set_terrain_edit_payload(loaded_map["terrain_edits"])
		_expect(is_equal_approx(TerrainSurface.height(store.city_seed, center.x, center.y), after))
	store.free()

func _expect(condition: bool) -> void:
	if condition:
		return
	_failed = true
	push_error("WORLD MAP CHECK FAILED")
