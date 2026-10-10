extends Node

const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")

const BENCHMARK_VERSION := 1
const BENCHMARK_SEED := 812733
const REPORT_DIRECTORY := "user://performance_reports"
const MENU_SCENE := "res://scenes/ui/main_menu.tscn"

var _pending := false
var _running := false
var _scene_root: Node
var _camera_rig: Node
var _variant_results: Array[Dictionary] = []
var _last_report_json := ""
var _last_report_markdown := ""


func request_full_suite() -> void:
	_pending = true
	_variant_results.clear()
	_last_report_json = ""
	_last_report_markdown = ""


func has_pending_run() -> bool:
	return _pending


func is_running() -> bool:
	return _running


func last_report_json() -> String:
	return _last_report_json


func last_report_markdown() -> String:
	return _last_report_markdown


func benchmark_seed() -> int:
	return BENCHMARK_SEED


func bind_scene(scene_root: Node, camera_rig: Node) -> void:
	_scene_root = scene_root
	_camera_rig = camera_rig
	if _pending and not _running:
		call_deferred("_begin_pending_run")


func _begin_pending_run() -> void:
	if not _pending or _running:
		return
	if not is_instance_valid(_camera_rig):
		push_error("PerformanceBenchmark: camera rig is unavailable")
		return
	_running = true
	_pending = false
	_variant_results.clear()
	if _camera_rig.has_method("set_benchmark_controlled"):
		_camera_rig.call("set_benchmark_controlled", true)
	GameStore.simulation_speed = 0
	await _run_suite()
	await _finish_suite()


func _run_suite() -> void:
	var variants: Array[Dictionary] = [
		{
			"id": "baseline",
			"details": true,
			"sdfgi": true,
			"shadows": true,
			"fog": true,
			"render_scale": 1.0,
		},
		{
			"id": "details_off",
			"details": false,
			"sdfgi": true,
			"shadows": true,
			"fog": true,
			"render_scale": 1.0,
		},
		{
			"id": "sdfgi_off",
			"details": true,
			"sdfgi": false,
			"shadows": true,
			"fog": true,
			"render_scale": 1.0,
		},
		{
			"id": "render_scale_075",
			"details": true,
			"sdfgi": true,
			"shadows": true,
			"fog": true,
			"render_scale": 0.75,
		},
	]
	for variant in variants:
		await _run_variant(variant)


func _run_variant(variant: Dictionary) -> void:
	_apply_variant(variant)
	var bounds := TerrainSurface.world_bounds()
	var center := bounds.get_center()
	var size := bounds.size
	var warmup_pose := {
		"target": center,
		"distance": 900.0,
		"yaw": -0.72,
		"pitch": 0.72,
	}
	_apply_pose(warmup_pose)
	await _wait_seconds(1.5)

	var phases := _phase_definitions(center, size)
	var phase_results: Array[Dictionary] = []
	for phase in phases:
		PerformanceProbe.reset_capture()
		await _run_phase(phase)
		var snapshot: Dictionary = PerformanceProbe.report_snapshot()
		snapshot["phase_id"] = str(phase.get("id", "phase"))
		snapshot["duration_seconds"] = float(phase.get("duration", 0.0))
		phase_results.append(snapshot)

	_variant_results.append({
		"id": str(variant.get("id", "variant")),
		"settings": variant.duplicate(true),
		"phases": phase_results,
		"summary": _summarize_variant(phase_results),
	})


func _phase_definitions(center: Vector2, size: Vector2) -> Array[Dictionary]:
	var x_span := size.x * 0.30
	var z_span := size.y * 0.30
	return [
		{
			"id": "near_pan_horizontal",
			"duration": 4.5,
			"from": {"target": center + Vector2(-x_span, -z_span * 0.15), "distance": 620.0, "yaw": -0.72, "pitch": 0.66},
			"to": {"target": center + Vector2(x_span, z_span * 0.15), "distance": 620.0, "yaw": -0.72, "pitch": 0.66},
		},
		{
			"id": "near_pan_vertical",
			"duration": 4.5,
			"from": {"target": center + Vector2(x_span * 0.12, -z_span), "distance": 720.0, "yaw": -0.28, "pitch": 0.64},
			"to": {"target": center + Vector2(-x_span * 0.12, z_span), "distance": 720.0, "yaw": -0.28, "pitch": 0.64},
		},
		{
			"id": "near_orbit",
			"duration": 4.5,
			"from": {"target": center, "distance": 850.0, "yaw": -1.35, "pitch": 0.67},
			"to": {"target": center, "distance": 850.0, "yaw": 1.85, "pitch": 0.78},
		},
		{
			"id": "zoom_out",
			"duration": 4.5,
			"from": {"target": center, "distance": 480.0, "yaw": -0.72, "pitch": 0.60},
			"to": {"target": center, "distance": 6200.0, "yaw": -0.72, "pitch": 0.86},
		},
		{
			"id": "far_pan_diagonal",
			"duration": 4.5,
			"from": {"target": center + Vector2(-x_span, -z_span), "distance": 5200.0, "yaw": -0.92, "pitch": 0.84},
			"to": {"target": center + Vector2(x_span, z_span), "distance": 5200.0, "yaw": -0.12, "pitch": 0.84},
		},
		{
			"id": "far_orbit",
			"duration": 4.5,
			"from": {"target": center, "distance": 6100.0, "yaw": -1.20, "pitch": 0.88},
			"to": {"target": center, "distance": 6100.0, "yaw": 2.10, "pitch": 0.88},
		},
		{
			"id": "zoom_in",
			"duration": 4.5,
			"from": {"target": center + Vector2(x_span * 0.15, -z_span * 0.12), "distance": 6200.0, "yaw": 0.35, "pitch": 0.88},
			"to": {"target": center + Vector2(x_span * 0.15, -z_span * 0.12), "distance": 480.0, "yaw": 0.35, "pitch": 0.60},
		},
		{
			"id": "combined_stress",
			"duration": 6.0,
			"mode": "combined",
			"center": center,
			"size": size,
		},
	]


func _run_phase(phase: Dictionary) -> void:
	var duration := maxf(0.1, float(phase.get("duration", 1.0)))
	var started_usec := Time.get_ticks_usec()
	while true:
		var elapsed := float(Time.get_ticks_usec() - started_usec) / 1000000.0
		var t := clampf(elapsed / duration, 0.0, 1.0)
		if str(phase.get("mode", "linear")) == "combined":
			_apply_combined_pose(phase, t)
		else:
			var from_pose: Dictionary = phase.get("from", {})
			var to_pose: Dictionary = phase.get("to", {})
			_apply_pose(_interpolate_pose(from_pose, to_pose, t))
		if t >= 1.0:
			break
		await get_tree().process_frame
	await get_tree().process_frame


func _interpolate_pose(from_pose: Dictionary, to_pose: Dictionary, t: float) -> Dictionary:
	var smooth := t * t * (3.0 - 2.0 * t)
	var from_target: Vector2 = from_pose.get("target", Vector2.ZERO)
	var to_target: Vector2 = to_pose.get("target", from_target)
	return {
		"target": from_target.lerp(to_target, smooth),
		"distance": lerpf(float(from_pose.get("distance", 900.0)), float(to_pose.get("distance", 900.0)), smooth),
		"yaw": lerpf(float(from_pose.get("yaw", -0.72)), float(to_pose.get("yaw", -0.72)), smooth),
		"pitch": lerpf(float(from_pose.get("pitch", 0.72)), float(to_pose.get("pitch", 0.72)), smooth),
	}


func _apply_combined_pose(phase: Dictionary, t: float) -> void:
	var center: Vector2 = phase.get("center", Vector2.ZERO)
	var size: Vector2 = phase.get("size", Vector2(10000.0, 10000.0))
	var angle := t * TAU * 1.35
	var target := center + Vector2(cos(angle) * size.x * 0.22, sin(angle * 0.82) * size.y * 0.22)
	var distance := lerpf(560.0, 2800.0, 0.5 + 0.5 * sin(t * TAU * 2.0 - PI * 0.5))
	_apply_pose({
		"target": target,
		"distance": distance,
		"yaw": -0.8 + t * TAU * 1.25,
		"pitch": 0.58 + 0.24 * (0.5 + 0.5 * sin(t * TAU)),
	})


func _apply_pose(pose: Dictionary) -> void:
	if not is_instance_valid(_camera_rig):
		return
	if _camera_rig.has_method("apply_benchmark_pose"):
		_camera_rig.call(
			"apply_benchmark_pose",
			pose.get("target", Vector2.ZERO),
			float(pose.get("distance", 900.0)),
			float(pose.get("yaw", -0.72)),
			float(pose.get("pitch", 0.72))
		)


func _apply_variant(variant: Dictionary) -> void:
	var current: Dictionary = PerformanceProbe.report_snapshot().get("toggles", {})
	if bool(current.get("natural_details", true)) != bool(variant.get("details", true)):
		PerformanceProbe.toggle_natural_details()
	if bool(current.get("sdfgi", true)) != bool(variant.get("sdfgi", true)):
		PerformanceProbe.toggle_sdfgi()
	if bool(current.get("shadows", true)) != bool(variant.get("shadows", true)):
		PerformanceProbe.toggle_shadows()
	if bool(current.get("volumetric_fog", true)) != bool(variant.get("fog", true)):
		PerformanceProbe.toggle_volumetric_fog()
	var current_scale := float(current.get("render_scale_3d", 1.0))
	var desired_scale := float(variant.get("render_scale", 1.0))
	if absf(current_scale - desired_scale) > 0.01:
		PerformanceProbe.toggle_render_scale()


func _summarize_variant(phases: Array[Dictionary]) -> Dictionary:
	var worst_phase := ""
	var worst_p99 := 0.0
	var worst_max := 0.0
	var p95_sum := 0.0
	var gpu_mean_sum := 0.0
	var rebuild_count := 0
	for phase in phases:
		var frame: Dictionary = phase.get("frame_ms", {})
		var p99 := float(frame.get("p99", 0.0))
		if p99 >= worst_p99:
			worst_p99 = p99
			worst_phase = str(phase.get("phase_id", ""))
		worst_max = maxf(worst_max, float(frame.get("max", 0.0)))
		p95_sum += float(frame.get("p95", 0.0))
		gpu_mean_sum += float((phase.get("render_gpu_ms", {}) as Dictionary).get("mean", 0.0))
		var spans: Dictionary = phase.get("spans", {})
		for metric_name in ["ground_cover_rebuild_ms", "landscape_detail_rebuild_ms", "riparian_detail_rebuild_ms"]:
			rebuild_count += int((spans.get(metric_name, {}) as Dictionary).get("count_total", 0))
	var count := maxi(1, phases.size())
	return {
		"worst_phase": worst_phase,
		"worst_frame_p99_ms": worst_p99,
		"worst_single_frame_ms": worst_max,
		"mean_of_phase_p95_ms": p95_sum / float(count),
		"mean_of_phase_gpu_ms": gpu_mean_sum / float(count),
		"detail_rebuild_count": rebuild_count,
	}


func _finish_suite() -> void:
	_apply_variant({"details": true, "sdfgi": true, "shadows": true, "fog": true, "render_scale": 1.0})
	var report := {
		"benchmark_version": BENCHMARK_VERSION,
		"captured_at": Time.get_datetime_string_from_system(),
		"seed": BENCHMARK_SEED,
		"engine": Engine.get_version_info(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"viewport_size": _viewport_size_dict(),
		"simulation_paused": true,
		"variants": _variant_results.duplicate(true),
	}
	_write_reports(report)
	if is_instance_valid(_camera_rig) and _camera_rig.has_method("set_benchmark_controlled"):
		_camera_rig.call("set_benchmark_controlled", false)
	_running = false
	_scene_root = null
	_camera_rig = null
	GameStore.suppress_persistence = true
	GameStore.reset_state(false, BENCHMARK_SEED, false)
	await get_tree().process_frame
	get_tree().change_scene_to_file(MENU_SCENE)


func _write_reports(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REPORT_DIRECTORY))
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	_last_report_json = "%s/benchmark_%s.json" % [REPORT_DIRECTORY, timestamp]
	_last_report_markdown = "%s/benchmark_%s.md" % [REPORT_DIRECTORY, timestamp]
	var json_file := FileAccess.open(_last_report_json, FileAccess.WRITE)
	if json_file != null:
		json_file.store_string(JSON.stringify(report, "\t"))
		json_file.close()
	var markdown_file := FileAccess.open(_last_report_markdown, FileAccess.WRITE)
	if markdown_file != null:
		markdown_file.store_string(_markdown_report(report))
		markdown_file.close()
	print("[PerfBenchmark] JSON: %s" % _last_report_json)
	print("[PerfBenchmark] Markdown: %s" % _last_report_markdown)


func _markdown_report(report: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("# I Like Transit — Performance Benchmark")
	lines.append("")
	lines.append("- Benchmark version: `%s`" % str(report.get("benchmark_version", 0)))
	lines.append("- Captured: `%s`" % str(report.get("captured_at", "")))
	lines.append("- Seed: `%s`" % str(report.get("seed", 0)))
	lines.append("- Renderer: `%s`" % str(report.get("rendering_method", "")))
	lines.append("- GPU: `%s`" % str(report.get("video_adapter", "")))
	var viewport: Dictionary = report.get("viewport_size", {})
	lines.append("- Viewport: `%sx%s`" % [str(viewport.get("x", 0)), str(viewport.get("y", 0))])
	lines.append("")
	lines.append("## Variant summary")
	lines.append("")
	lines.append("| Variant | Mean phase p95 | Worst p99 | Worst frame | Worst phase | Detail rebuilds |")
	lines.append("| --- | ---: | ---: | ---: | --- | ---: |")
	for variant_value in report.get("variants", []):
		var variant: Dictionary = variant_value
		var summary: Dictionary = variant.get("summary", {})
		lines.append("| %s | %.2f ms | %.2f ms | %.2f ms | %s | %d |" % [
			str(variant.get("id", "")),
			float(summary.get("mean_of_phase_p95_ms", 0.0)),
			float(summary.get("worst_frame_p99_ms", 0.0)),
			float(summary.get("worst_single_frame_ms", 0.0)),
			str(summary.get("worst_phase", "")),
			int(summary.get("detail_rebuild_count", 0)),
		])
		lines.append("")
		lines.append("### %s" % str(variant.get("id", "")))
		lines.append("")
		lines.append("| Phase | p50 | p95 | p99 | max | GPU mean | Ground rebuild p95 | Landscape p95 | Riparian p95 |")
		lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
		for phase_value in variant.get("phases", []):
			var phase: Dictionary = phase_value
			var frame: Dictionary = phase.get("frame_ms", {})
			var gpu: Dictionary = phase.get("render_gpu_ms", {})
			var spans: Dictionary = phase.get("spans", {})
			lines.append("| %s | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f |" % [
				str(phase.get("phase_id", "")),
				float(frame.get("p50", 0.0)),
				float(frame.get("p95", 0.0)),
				float(frame.get("p99", 0.0)),
				float(frame.get("max", 0.0)),
				float(gpu.get("mean", 0.0)),
				float((spans.get("ground_cover_rebuild_ms", {}) as Dictionary).get("p95", 0.0)),
				float((spans.get("landscape_detail_rebuild_ms", {}) as Dictionary).get("p95", 0.0)),
				float((spans.get("riparian_detail_rebuild_ms", {}) as Dictionary).get("p95", 0.0)),
			])
	return "\n".join(lines) + "\n"


func _viewport_size_dict() -> Dictionary:
	var viewport := get_viewport()
	var size := viewport.get_visible_rect().size if viewport != null else Vector2.ZERO
	return {"x": size.x, "y": size.y}


func _wait_seconds(seconds: float) -> void:
	var started_usec := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - started_usec) / 1000000.0 < seconds:
		await get_tree().process_frame
