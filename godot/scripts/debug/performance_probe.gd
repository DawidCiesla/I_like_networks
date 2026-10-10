extends Node

const MAX_SAMPLES := 900
const OVERLAY_REFRESH_SECONDS := 0.25
const REPORT_DIRECTORY := "user://performance_reports"

var _frame_ms: Array[float] = []
var _process_ms: Array[float] = []
var _render_cpu_ms: Array[float] = []
var _render_gpu_ms: Array[float] = []
var _span_samples: Dictionary = {}
var _span_counts: Dictionary = {}
var _counters: Dictionary = {}
var _overlay_elapsed := 0.0
var _canvas: CanvasLayer
var _panel: PanelContainer
var _label: Label
var _scene_root: Node
var _terrain_renderer: Node
var _environment_controller: Node
var _natural_details_enabled := true
var _sdfgi_enabled := true
var _shadows_enabled := true
var _volumetric_fog_enabled := true
var _render_scale := 1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_create_overlay()
	call_deferred("_enable_viewport_measurement")
	_register_custom_monitors()


func _exit_tree() -> void:
	for monitor_name in [
		"I Like Transit/Frame p95 ms",
		"I Like Transit/Frame p99 ms",
		"I Like Transit/GPU render ms",
	]:
		if Performance.has_custom_monitor(monitor_name):
			Performance.remove_custom_monitor(monitor_name)


func bind_scene(scene_root: Node, environment_controller: Node, terrain_renderer: Node) -> void:
	_scene_root = scene_root
	_environment_controller = environment_controller
	_terrain_renderer = terrain_renderer
	_apply_debug_state()


func _enable_viewport_measurement() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)


func _process(delta: float) -> void:
	_append_sample(_frame_ms, maxf(0.0, delta * 1000.0))
	_append_sample(_process_ms, maxf(0.0, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0))
	_overlay_elapsed += delta
	if _overlay_elapsed < OVERLAY_REFRESH_SECONDS:
		return
	_overlay_elapsed = 0.0
	_sample_render_times()
	if is_instance_valid(_panel) and _panel.visible:
		_refresh_overlay()


func _sample_render_times() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var viewport_rid := viewport.get_viewport_rid()
	_append_sample(_render_cpu_ms, maxf(0.0, RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)))
	_append_sample(_render_gpu_ms, maxf(0.0, RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)))


func record_duration(metric_name: String, duration_ms: float) -> void:
	var key := metric_name.strip_edges()
	if key.is_empty():
		return
	var samples: Array = _span_samples.get(key, [])
	samples.append(maxf(0.0, duration_ms))
	while samples.size() > MAX_SAMPLES:
		samples.pop_front()
	_span_samples[key] = samples
	_span_counts[key] = int(_span_counts.get(key, 0)) + 1


func increment_counter(counter_name: String, amount: int = 1) -> void:
	var key := counter_name.strip_edges()
	if key.is_empty():
		return
	_counters[key] = int(_counters.get(key, 0)) + amount


func reset_capture() -> void:
	_frame_ms.clear()
	_process_ms.clear()
	_render_cpu_ms.clear()
	_render_gpu_ms.clear()
	_span_samples.clear()
	_span_counts.clear()
	_counters.clear()
	if is_instance_valid(_panel) and _panel.visible:
		_refresh_overlay()
	print("[Perf] capture reset")


func report_snapshot() -> Dictionary:
	var viewport := get_viewport()
	var viewport_size := viewport.get_visible_rect().size if viewport != null else Vector2.ZERO
	var spans: Dictionary = {}
	var span_names: Array = _span_samples.keys()
	span_names.sort()
	for metric_name_value in span_names:
		var metric_name := str(metric_name_value)
		var samples: Array = _span_samples.get(metric_name, [])
		spans[metric_name] = _stats(samples)
		spans[metric_name]["count_total"] = int(_span_counts.get(metric_name, 0))
	return {
		"captured_at": Time.get_datetime_string_from_system(),
		"engine": Engine.get_version_info(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"viewport_size": {"x": viewport_size.x, "y": viewport_size.y},
		"toggles": {
			"natural_details": _natural_details_enabled,
			"sdfgi": _sdfgi_enabled,
			"shadows": _shadows_enabled,
			"volumetric_fog": _volumetric_fog_enabled,
			"render_scale_3d": _render_scale,
		},
		"frame_ms": _stats(_frame_ms),
		"process_ms": _stats(_process_ms),
		"render_cpu_ms": _stats(_render_cpu_ms),
		"render_gpu_ms": _stats(_render_gpu_ms),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objects_in_frame": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"primitives_in_frame": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"spans": spans,
		"counters": _counters.duplicate(true),
	}


func save_report(tag: String = "manual") -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REPORT_DIRECTORY))
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var safe_tag := tag.strip_edges().replace(" ", "_").replace("/", "_")
	if safe_tag.is_empty():
		safe_tag = "manual"
	var path := "%s/perf_%s_%s.json" % [REPORT_DIRECTORY, timestamp, safe_tag]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("PerformanceProbe could not write %s" % path)
		return ""
	file.store_string(JSON.stringify(report_snapshot(), "\t"))
	file.close()
	print("[Perf] report saved: %s" % path)
	return path


func toggle_overlay() -> bool:
	if not is_instance_valid(_panel):
		return false
	_panel.visible = not _panel.visible
	if _panel.visible:
		_refresh_overlay()
	return _panel.visible


func toggle_natural_details() -> bool:
	_natural_details_enabled = not _natural_details_enabled
	if is_instance_valid(_terrain_renderer) and _terrain_renderer.has_method("set_natural_detail_enabled"):
		_terrain_renderer.call("set_natural_detail_enabled", _natural_details_enabled)
	_refresh_overlay_if_visible()
	return _natural_details_enabled


func toggle_sdfgi() -> bool:
	_sdfgi_enabled = not _sdfgi_enabled
	_set_environment_property("sdfgi_enabled", _sdfgi_enabled)
	_refresh_overlay_if_visible()
	return _sdfgi_enabled


func toggle_shadows() -> bool:
	_shadows_enabled = not _shadows_enabled
	var sun := _sun_light()
	if sun != null:
		sun.shadow_enabled = _shadows_enabled
	_refresh_overlay_if_visible()
	return _shadows_enabled


func toggle_volumetric_fog() -> bool:
	_volumetric_fog_enabled = not _volumetric_fog_enabled
	_set_environment_property("volumetric_fog_enabled", _volumetric_fog_enabled)
	_refresh_overlay_if_visible()
	return _volumetric_fog_enabled


func toggle_render_scale() -> float:
	_render_scale = 0.75 if _render_scale > 0.9 else 1.0
	var viewport := get_viewport()
	if viewport != null:
		var viewport_rid := viewport.get_viewport_rid()
		RenderingServer.viewport_set_scaling_3d_mode(
			viewport_rid,
			RenderingServer.VIEWPORT_SCALING_3D_MODE_BILINEAR
		)
		RenderingServer.viewport_set_scaling_3d_scale(viewport_rid, _render_scale)
	_refresh_overlay_if_visible()
	return _render_scale


func handle_debug_key(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	if event.physical_keycode == KEY_F9 and not event.ctrl_pressed and not event.meta_pressed:
		toggle_overlay()
		return true
	if event.physical_keycode == KEY_F10 and not event.ctrl_pressed and not event.meta_pressed:
		reset_capture()
		return true
	if event.physical_keycode == KEY_F11 and not event.ctrl_pressed and not event.meta_pressed:
		save_report("manual")
		return true
	if not (event.ctrl_pressed or event.meta_pressed):
		return false
	match event.physical_keycode:
		KEY_1:
			toggle_natural_details()
			return true
		KEY_2:
			toggle_sdfgi()
			return true
		KEY_3:
			toggle_shadows()
			return true
		KEY_4:
			toggle_volumetric_fog()
			return true
		KEY_5:
			toggle_render_scale()
			return true
	return false


func _apply_debug_state() -> void:
	if is_instance_valid(_terrain_renderer) and _terrain_renderer.has_method("set_natural_detail_enabled"):
		_terrain_renderer.call("set_natural_detail_enabled", _natural_details_enabled)
	_set_environment_property("sdfgi_enabled", _sdfgi_enabled)
	_set_environment_property("volumetric_fog_enabled", _volumetric_fog_enabled)
	var sun := _sun_light()
	if sun != null:
		sun.shadow_enabled = _shadows_enabled


func _environment_resource() -> Environment:
	if not is_instance_valid(_environment_controller):
		return null
	var value: Variant = _environment_controller.get("_environment")
	return value as Environment if value is Environment else null


func _sun_light() -> DirectionalLight3D:
	if not is_instance_valid(_environment_controller):
		return null
	var value: Variant = _environment_controller.get("_sun")
	return value as DirectionalLight3D if value is DirectionalLight3D else null


func _set_environment_property(property_name: String, value: Variant) -> void:
	var environment := _environment_resource()
	if environment == null:
		return
	environment.set(property_name, value)


func _create_overlay() -> void:
	_canvas = CanvasLayer.new()
	_canvas.layer = 120
	_canvas.name = "PerformanceProbeOverlay"
	add_child(_canvas)
	_panel = PanelContainer.new()
	_panel.position = Vector2(12.0, 132.0)
	_panel.custom_minimum_size = Vector2(500.0, 0.0)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	_canvas.add_child(_panel)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 12)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(_label)


func _refresh_overlay_if_visible() -> void:
	if is_instance_valid(_panel) and _panel.visible:
		_refresh_overlay()


func _refresh_overlay() -> void:
	if not is_instance_valid(_label):
		return
	var frame := _stats(_frame_ms)
	var render_cpu := _stats(_render_cpu_ms)
	var render_gpu := _stats(_render_gpu_ms)
	var lines: Array[String] = []
	lines.append("PERFORMANCE PROBE · F9 hide · F10 reset · F11 save JSON")
	lines.append("Frame ms  p50 %.2f  p95 %.2f  p99 %.2f  max %.2f" % [
		float(frame.get("p50", 0.0)),
		float(frame.get("p95", 0.0)),
		float(frame.get("p99", 0.0)),
		float(frame.get("max", 0.0)),
	])
	lines.append("Render    CPU %.2f ms  GPU %.2f ms  draw calls %d" % [
		float(render_cpu.get("latest", 0.0)),
		float(render_gpu.get("latest", 0.0)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
	])
	for metric_name in [
		"ground_cover_rebuild_ms",
		"landscape_detail_rebuild_ms",
		"riparian_detail_rebuild_ms",
		"resident_transport_metrics_ms",
		"traffic_refresh_ms",
		"transit_traffic_apply_ms",
	]:
		var samples: Array = _span_samples.get(metric_name, [])
		var stat := _stats(samples)
		lines.append("%-28s count %4d  p95 %6.2f  max %6.2f" % [
			metric_name,
			int(_span_counts.get(metric_name, 0)),
			float(stat.get("p95", 0.0)),
			float(stat.get("max", 0.0)),
		])
	lines.append("A/B  Ctrl/Cmd+1 details:%s  +2 SDFGI:%s  +3 shadows:%s" % [
		_on_off(_natural_details_enabled),
		_on_off(_sdfgi_enabled),
		_on_off(_shadows_enabled),
	])
	lines.append("     Ctrl/Cmd+4 fog:%s  +5 render scale:%.2f" % [
		_on_off(_volumetric_fog_enabled),
		_render_scale,
	])
	_label.text = "\n".join(lines)


func _register_custom_monitors() -> void:
	if not Performance.has_custom_monitor("I Like Transit/Frame p95 ms"):
		Performance.add_custom_monitor("I Like Transit/Frame p95 ms", Callable(self, "_monitor_frame_p95"))
	if not Performance.has_custom_monitor("I Like Transit/Frame p99 ms"):
		Performance.add_custom_monitor("I Like Transit/Frame p99 ms", Callable(self, "_monitor_frame_p99"))
	if not Performance.has_custom_monitor("I Like Transit/GPU render ms"):
		Performance.add_custom_monitor("I Like Transit/GPU render ms", Callable(self, "_monitor_gpu_render"))


func _monitor_frame_p95() -> float:
	return float(_stats(_frame_ms).get("p95", 0.0))


func _monitor_frame_p99() -> float:
	return float(_stats(_frame_ms).get("p99", 0.0))


func _monitor_gpu_render() -> float:
	return float(_stats(_render_gpu_ms).get("latest", 0.0))


func _append_sample(samples: Array[float], value: float) -> void:
	samples.append(value)
	while samples.size() > MAX_SAMPLES:
		samples.pop_front()


func _stats(raw_samples: Array) -> Dictionary:
	if raw_samples.is_empty():
		return {"count": 0, "latest": 0.0, "mean": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var samples: Array[float] = []
	var total := 0.0
	var maximum := 0.0
	for value in raw_samples:
		var number := maxf(0.0, float(value))
		samples.append(number)
		total += number
		maximum = maxf(maximum, number)
	samples.sort()
	return {
		"count": samples.size(),
		"latest": float(raw_samples.back()),
		"mean": total / float(samples.size()),
		"p50": _percentile(samples, 0.50),
		"p95": _percentile(samples, 0.95),
		"p99": _percentile(samples, 0.99),
		"max": maximum,
	}


func _percentile(sorted_samples: Array[float], fraction: float) -> float:
	if sorted_samples.is_empty():
		return 0.0
	if sorted_samples.size() == 1:
		return sorted_samples[0]
	var position := clampf(fraction, 0.0, 1.0) * float(sorted_samples.size() - 1)
	var lower := floori(position)
	var upper := ceili(position)
	if lower == upper:
		return sorted_samples[lower]
	return lerpf(sorted_samples[lower], sorted_samples[upper], position - float(lower))


static func _on_off(value: bool) -> String:
	return "ON" if value else "OFF"
