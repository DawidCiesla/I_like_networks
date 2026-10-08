extends SceneTree

const Data = preload("res://scripts/core/game_data.gd")
const GameStoreScript = preload("res://scripts/core/game_store.gd")
const BrowserImporter = preload("res://scripts/persistence/browser_save_importer.gd")
const TransitNetwork = preload("res://scripts/transport/transit_network.gd")
const MapDefinition = preload("res://scripts/world/world_map_definition.gd")

var failures := 0


func _initialize() -> void:
	_test_custom_sandbox_network_import()
	_test_legacy_payload_without_transit_network()
	_test_future_transit_schema_is_rejected()
	if failures == 0:
		print("Browser transit import tests: PASS")
		quit(0)
	else:
		push_error("Browser transit import tests: %d failure(s)" % failures)
		quit(1)


func _test_custom_sandbox_network_import() -> void:
	var custom_network := {
		"schemaVersion": TransitNetwork.SCHEMA_VERSION,
		"source": "freeLines",
		"nextStopSerial": 3,
		"nextLineSerial": 3,
		"unlockedModes": {"bus": true, "tram": true, "metro": true},
		"stops": {
			"custom-stop-1": {"id": "custom-stop-1", "x": 100.0, "y": 200.0, "status": "built", "servedLineIds": ["custom-line-1"]},
			"custom-stop-2": {"id": "custom-stop-2", "x": 1000.0, "y": 200.0, "status": "built", "servedLineIds": ["custom-line-1"]},
			"custom-stop-3": {"id": "custom-stop-3", "x": 1000.0, "y": 1000.0, "status": "built", "servedLineIds": ["custom-line-2"]},
			"custom-stop-4": {"id": "custom-stop-4", "x": 1800.0, "y": 1000.0, "status": "built", "servedLineIds": ["custom-line-2"]},
		},
		"lines": {
			# Imported regional saves can carry legacy bus records beside new
			# custom lines. The importer must infer this well-known ID as legacy.
			"line1": {"id": "line1", "mode": "bus", "status": "active"},
			"custom-line-1": {
				"id": "custom-line-1",
				"name": "Central Tram",
				"source": "custom",
				"mode": "tram",
				"status": "active",
				"stopIds": ["custom-stop-1", "custom-stop-2"],
				"plannedStopIds": ["custom-stop-1", "custom-stop-2"],
				"routeSegments": [{"fromStopId": "custom-stop-1", "toStopId": "custom-stop-2", "success": true, "lengthWorld": 900.0}],
				"routeLengthWorld": 900.0,
				"fleetCount": 1,
				"vehicles": [{"id": 7, "currentStopIndex": 0, "nextStopIndex": 1, "direction": 1, "phase": "dwell", "phaseMinutesRemaining": 2.0, "onboardByDestination": [0.0, 2.0], "onboardPassengers": 2.0}],
				"nextVehicleId": 8,
				"waitingByStop": [[0.0, 5.0], [3.0, 0.0]],
				"queuePassengers": 8.0,
			},
			"custom-line-2": {
				"id": "custom-line-2",
				"name": "Regional Metro",
				"source": "custom",
				"mode": "metro",
				"status": "active",
				"stopIds": ["custom-stop-3", "custom-stop-4"],
				"plannedStopIds": ["custom-stop-3", "custom-stop-4"],
				"routeSegments": [{"fromStopId": "custom-stop-3", "toStopId": "custom-stop-4", "success": true, "lengthWorld": 800.0, "gradeSeparated": true, "underground": true}],
				"routeLengthWorld": 800.0,
				"fleetCount": 0,
				"vehicles": [],
				"nextVehicleId": 1,
				"waitingByStop": [[0.0, 0.0], [0.0, 0.0]],
				"queuePassengers": 0.0,
			},
		},
	}
	var browser_payload := {
		"state": {
			"version": 12,
			"money": 45000.0,
			"city": {"seed": 456123},
			"worldMap": {"id": MapDefinition.DEFAULT_MAP_ID, "seed": 456123},
			"transitNetwork": custom_network,
		},
	}
	var imported := BrowserImporter.convert_browser_save(browser_payload)
	_expect(imported.has("transit_network"), "browser importer returns the supplied transit network")
	_expect(str(imported.get("world_map", {}).get("id", "")) == MapDefinition.DEFAULT_MAP_ID, "browser importer retains the sandbox map identity")
	var converted_network: Dictionary = imported.get("transit_network", {})
	var converted_lines: Dictionary = converted_network.get("lines", {})
	_expect(str(converted_lines.get("custom-line-1", {}).get("source", "")) == "custom", "camelCase custom tram keeps its custom source")
	_expect(str(converted_lines.get("custom-line-2", {}).get("mode", "")) == "metro", "camelCase metro mode is normalized")
	_expect(str(converted_lines.get("line1", {}).get("source", "")) == "legacy", "well-known fixed line IDs are not misclassified as custom")
	_expect(converted_lines.get("custom-line-1", {}).get("route_segments", []).size() == 1, "custom route segments survive import")
	_expect(converted_network.get("unlocked_modes", {}).get("tram", false), "used tram mode remains unlocked")
	_expect(converted_network.get("unlocked_modes", {}).get("metro", false), "used metro mode remains unlocked")

	var store = GameStoreScript.new()
	store.suppress_persistence = true
	store._apply_payload(imported)
	var custom_ids := TransitNetwork.custom_line_ids(store.transit_network)
	_expect(store.is_sandbox(), "imported sandbox network remains in the regional simulation")
	_expect(custom_ids == ["custom-line-1", "custom-line-2"], "GameStore retains both custom mode lines")
	var loaded_tram: Dictionary = store.transit_network.get("lines", {}).get("custom-line-1", {})
	var loaded_metro: Dictionary = store.transit_network.get("lines", {}).get("custom-line-2", {})
	_expect(str(loaded_tram.get("mode", "")) == "tram", "GameStore retains the tram operating mode")
	_expect(str(loaded_metro.get("mode", "")) == "metro", "GameStore retains the metro operating mode")
	_expect(float(loaded_tram.get("waiting_by_stop", [])[0][1]) == 5.0, "waiting passengers survive runtime normalization")
	_expect(int(loaded_tram.get("vehicles", [])[0].get("id", 0)) == 7, "saved vehicle identity survives runtime normalization")
	_expect(is_equal_approx(float(loaded_tram.get("vehicles", [])[0].get("onboard_passengers", 0.0)), 2.0), "onboard passenger state survives runtime normalization")
	_expect(int(loaded_metro.get("fleet_count", -1)) == 1, "runtime creates a starter metro vehicle when a line has none")
	store.free()


func _test_legacy_payload_without_transit_network() -> void:
	var imported := BrowserImporter.convert_browser_save({
		"version": 12,
		"money": 1200.0,
		"city": {"seed": 9281},
		"line1": {"built": true, "stopCount": 2, "fleetCount": 1},
	})
	_expect(not imported.has("transit_network"), "legacy browser payload without a network remains on the migration path")
	_expect(str(imported.get("world_map", {}).get("id", "")) == MapDefinition.LEGACY_CITY_MAP_ID, "legacy browser payload still selects the legacy map")

	var store = GameStoreScript.new()
	store.suppress_persistence = true
	store._apply_payload(imported)
	_expect(not store.is_sandbox(), "legacy import remains in the legacy city mode")
	_expect(TransitNetwork.custom_line_ids(store.transit_network).is_empty(), "legacy migration does not invent custom lines")
	var legacy_lines: Dictionary = store.transit_network.get("lines", {})
	_expect(legacy_lines.has("line1"), "legacy fixed line is rebuilt in the transit bridge")
	_expect(str(legacy_lines.get("line1", {}).get("source", "")) == "legacy", "migrated fixed line keeps legacy identity")
	_expect(str(legacy_lines.get("line1", {}).get("status", "")) == "active", "legacy line state remains active after import")
	store.free()


func _test_future_transit_schema_is_rejected() -> void:
	var imported := BrowserImporter.convert_browser_save({
		"state": {
			"version": 12,
			"money": 45000.0,
			"city": {"seed": 456123},
			"transitNetwork": {
				"schemaVersion": TransitNetwork.SCHEMA_VERSION + 1,
				"lines": {"custom-line-1": {"id": "custom-line-1", "mode": "metro"}},
			},
		}
	})
	_expect(imported.is_empty(), "future transit schemas reject the complete import instead of silently dropping network progress")


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error("Browser transit import check failed: %s" % message)
