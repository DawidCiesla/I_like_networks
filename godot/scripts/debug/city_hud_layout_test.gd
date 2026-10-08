extends SceneTree

var failures := 0

func _initialize() -> void:
	await process_frame
	var store := root.get_node("GameStore")
	store.suppress_persistence = true
	store.set_speed(0)
	var scene = load("res://scenes/main.tscn").instantiate()
	var hud = scene.get_node("HUD")
	scene.remove_child(hud)
	scene.free()
	root.add_child(hud)
	await process_frame
	for dimensions in [Vector2(1920, 1080), Vector2(1280, 720), Vector2(1024, 768)]:
		hud.root_control.size = dimensions
		hud._layout_hud()
		await process_frame
		var rail: Control = hud.root_control.get_node("CityToolbar")
		_expect(rail.position.y >= dimensions.y - 120, "toolbar stays at bottom")
		_expect(rail.position.x + rail.size.x <= dimensions.x + 1, "toolbar fits viewport")
		hud._toolbar_buttons["roads"].pressed.emit()
		await process_frame
		_expect(hud._road_builder_button.visible, "roads tab reveals real road action")
		_expect(not hud._terrain_tool_button.visible, "roads tab hides terrain action")
		hud._toolbar_buttons["economy"].pressed.emit()
		await process_frame
		_expect(hud._dashboard.visible, "economy opens dashboard")
		_expect(hud._dashboard.get_active_tab_name() == "Economy", "economy selects matching data tab")
		_expect(not hud._road_builder_button.visible, "dashboard hides build tray")
		hud._dashboard.close()
		_expect(not hud._dashboard.visible and hud._tool_category.is_empty(), "close restores map state")
		hud._toolbar_buttons["saves"].pressed.emit()
		_expect(hud.import_button.visible and hud.save_copy_button.visible and hud.reset_button.visible, "save tools remain available")
	store.set_speed(1)
	for button_and_speed in [[hud.pause_button, 0], [hud.speed_1_button, 1], [hud.speed_2_button, 2], [hud.speed_4_button, 4]]:
		button_and_speed[0].pressed.emit()
		_expect(store.simulation_speed == button_and_speed[1], "speed controls preserve simulation actions")
	store.set_speed(0)
	hud.queue_free()
	await process_frame
	if failures == 0:
		print("CITY HUD LAYOUT TEST: PASS (3 resolutions, categories, dashboard, save and speed actions)")
	quit(0 if failures == 0 else 1)

func _expect(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
