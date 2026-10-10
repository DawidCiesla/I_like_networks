extends SceneTree

const RegionalTrafficOverlayRenderer = preload("res://scripts/render/regional_traffic_overlay_renderer.gd")

var _failures := 0


func _init() -> void:
	_test_color_thresholds()
	_test_overlay_builds_only_traffic_roads()
	if _failures > 0:
		push_error("REGIONAL TRAFFIC OVERLAY RENDERER TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL TRAFFIC OVERLAY RENDERER TEST: PASS")
	quit(0)


func _test_color_thresholds() -> void:
	var free := RegionalTrafficOverlayRenderer._traffic_color(0.50)
	var warning := RegionalTrafficOverlayRenderer._traffic_color(0.75)
	var heavy := RegionalTrafficOverlayRenderer._traffic_color(0.92)
	var severe := RegionalTrafficOverlayRenderer._traffic_color(1.15)
	_expect(free.g > free.r, "free-flow traffic uses a green-dominant overlay")
	_expect(warning.r > 0.8 and warning.g > 0.7, "moderate traffic uses a yellow overlay")
	_expect(heavy.r > heavy.g and heavy.g > heavy.b, "heavy traffic uses an orange overlay")
	_expect(severe.r > severe.g * 2.0, "severe congestion uses a red overlay")


func _test_overlay_builds_only_traffic_roads() -> void:
	var renderer := RegionalTrafficOverlayRenderer.new()
	var roads: Array = [
		{
			"id": "road-a",
			"status": "built",
			"class": "collector",
			"points": [Vector2(0.0, 0.0), Vector2(300.0, 0.0)],
			"traffic": {"vc_ratio": 1.10, "flow_vph": 1500.0},
		},
		{
			"id": "road-b",
			"status": "built",
			"class": "local",
			"points": [Vector2(0.0, 100.0), Vector2(300.0, 100.0)],
		},
		{
			"id": "road-c",
			"status": "queued",
			"class": "arterial",
			"points": [Vector2(0.0, 200.0), Vector2(300.0, 200.0)],
			"traffic": {"vc_ratio": 1.30, "flow_vph": 2400.0},
		},
	]
	renderer._rebuild(roads, 731945)
	_expect(renderer.get_child_count() == 1, "overlay renders only completed roads carrying traffic metrics")
	if renderer.get_child_count() == 1:
		_expect(str(renderer.get_child(0).name) == "Traffic_road-a", "overlay node keeps the source road id")
	renderer.free()


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional traffic overlay renderer: %s" % message)
