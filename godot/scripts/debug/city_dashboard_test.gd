extends SceneTree

const Dashboard = preload("res://scripts/ui/city_dashboard.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var dashboard = Dashboard.new()
	root.add_child(dashboard)
	await process_frame
	_expect(not dashboard.visible, "dashboard starts closed")

	var headings := {
		"Overview": "City overview",
		"Transport": "Transport network",
		"Economy": "City economy",
		"Residents": "Residents",
	}
	for tab in headings:
		dashboard.open_tab(tab)
		await process_frame
		_expect(dashboard.visible, "%s tab opens the dashboard" % tab)
		_expect(dashboard.get_active_tab_name() == tab, "%s tab becomes active" % tab)
		var found_heading := false
		for label in dashboard.find_children("*", "Label", true, false):
			if label.text == str(headings[tab]):
				found_heading = true
				break
		_expect(found_heading, "%s page renders its heading" % tab)

	dashboard.close()
	_expect(not dashboard.visible, "close hides the dashboard")
	dashboard.queue_free()
	await process_frame
	if _failures == 0:
		print("City dashboard UI test: PASS")
		quit(0)
	else:
		push_error("City dashboard UI test: %d failure(s)" % _failures)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("FAIL: %s" % message)
