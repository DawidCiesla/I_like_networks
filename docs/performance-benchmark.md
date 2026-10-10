# Regional performance benchmark V1

This harness exists to measure camera-movement stutter before changing rendering or simulation behavior.

## One-click benchmark from the main menu

Use `PERFORMANCE BENCHMARK` in the main menu. The benchmark:

1. creates a deterministic temporary region using seed `812733`,
2. disables persistence so the normal save file is not overwritten,
3. waits until terrain, water and vegetation loading is complete,
4. pauses simulation time to isolate camera/rendering work,
5. takes control of the camera and runs the same route every time,
6. executes four A/B variants,
7. writes JSON and Markdown reports to `user://performance_reports/`,
8. restores the default rendering toggles and returns to the main menu.

The main menu displays the absolute path to the latest Markdown report after the benchmark finishes.

### Automated camera phases

Every variant runs the same phases:

- `near_pan_horizontal` — low camera, long horizontal pan,
- `near_pan_vertical` — low camera, long vertical pan,
- `near_orbit` — close orbit around the regional center,
- `zoom_out` — close view to regional overview,
- `far_pan_diagonal` — diagonal movement at high altitude,
- `far_orbit` — wide regional orbit,
- `zoom_in` — regional overview back to close view,
- `combined_stress` — simultaneous pan, rotation and zoom changes.

Each phase is measured independently so the report identifies which camera operation produced the worst p95/p99 or rebuild spike.

### Automated A/B variants

The full suite runs:

1. `baseline` — natural details, SDFGI, shadows and volumetric fog enabled; render scale `1.00`,
2. `details_off` — procedural grass, landscape details and riparian reeds disabled,
3. `sdfgi_off` — baseline rendering with SDFGI disabled,
4. `render_scale_075` — baseline rendering at 3D render scale `0.75`.

Each variant receives a short warm-up before measurements begin.

## Report files

A completed run creates two files with the same timestamp:

- `benchmark_<timestamp>.json` — full machine-readable metrics,
- `benchmark_<timestamp>.md` — human-readable summary and per-phase tables.

The JSON report includes engine version, renderer, GPU adapter, viewport size, benchmark seed, active settings and all per-phase measurements.

## Runtime controls for manual investigation

The automated benchmark is the preferred comparison method. The original manual tools remain available for focused follow-up tests:

- `F9` — show/hide the performance overlay,
- `F10` — reset the current measurement window,
- `F11` — save the current measurement report as JSON,
- `Ctrl/Cmd + 1` — enable/disable procedural natural details,
- `Ctrl/Cmd + 2` — enable/disable SDFGI,
- `Ctrl/Cmd + 3` — enable/disable directional shadows,
- `Ctrl/Cmd + 4` — enable/disable volumetric fog,
- `Ctrl/Cmd + 5` — toggle 3D render scale between `1.00` and `0.75`.

The overlay is intentionally hidden by default. Enabling it adds a small amount of UI rendering work.

## Captured metrics

The probe stores:

- frame time statistics: mean, p50, p95, p99 and max,
- Godot process time,
- measured viewport render CPU time,
- measured viewport render GPU time,
- draw calls, rendered objects and primitives,
- rebuild timings and counts for:
  - `ground_cover_rebuild_ms`,
  - `landscape_detail_rebuild_ms`,
  - `riparian_detail_rebuild_ms`,
- regional simulation timings for:
  - `resident_transport_metrics_ms`,
  - `traffic_refresh_ms`,
  - `transit_traffic_apply_ms`,
- the active A/B toggle state.

Viewport GPU/CPU render timing uses Godot's measured render-time API and is enabled by `PerformanceProbe` at startup.

## Reading the results

For a 60 FPS target, a frame budget is about `16.7 ms`. Prioritize p95/p99 and isolated spikes over average FPS.

Initial investigation thresholds:

- frame p95 consistently above ~20 ms: visible instability is likely,
- frame p99 above ~30 ms: investigate spikes even if the average FPS looks good,
- any procedural `_rebuild` repeatedly above ~4–5 ms: strong candidate for tile streaming / work slicing,
- high GPU render time with details disabled: focus next on SDFGI, shadows, volumetric fog and 3D resolution,
- high `resident_transport_metrics_ms` or `traffic_refresh_ms` while the camera is stationary: investigate simulation invalidation/cache behavior separately from rendering.

Compare reports using the same executable/build, display mode and hardware. The automated route, seed and simulation state are otherwise fixed by the benchmark runner.