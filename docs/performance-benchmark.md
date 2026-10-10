# Regional performance benchmark V1

This harness exists to measure camera-movement stutter before changing rendering or simulation behavior.

## Runtime controls

- `F9` — show/hide the performance overlay.
- `F10` — reset the current measurement window.
- `F11` — save the current measurement report as JSON under `user://performance_reports/`.
- `Ctrl/Cmd + 1` — enable/disable procedural natural details (grass, rocks/shrubs, riparian reeds).
- `Ctrl/Cmd + 2` — enable/disable SDFGI.
- `Ctrl/Cmd + 3` — enable/disable directional shadows.
- `Ctrl/Cmd + 4` — enable/disable volumetric fog.
- `Ctrl/Cmd + 5` — toggle 3D render scale between `1.00` and `0.75`. UI remains at native resolution.

The overlay is intentionally hidden by default. Enabling it adds a small amount of UI rendering work, so final comparison captures may be saved with the overlay hidden after confirming the active toggles.

## Captured metrics

The JSON report stores:

- frame time rolling statistics: mean, p50, p95, p99 and max,
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

## First benchmark matrix

Use the same save, camera start position, window size and simulation speed for every run.

For each configuration below, press `F10`, execute the same camera movement, stop moving, then press `F11`.

1. **Baseline** — all effects/details ON, render scale `1.00`.
2. **Natural details OFF** — `Ctrl/Cmd + 1`.
3. **SDFGI OFF** — restore details, `Ctrl/Cmd + 2`.
4. **Render scale 0.75** — restore SDFGI, `Ctrl/Cmd + 5`.
5. Optional isolation runs: shadows OFF and volumetric fog OFF.

Run the matrix twice:

- **near camera**: height low enough for all procedural details to be active,
- **far camera**: above the detail-renderer height cutoffs.

For each distance regime repeat three motions separately:

- pan,
- rotation,
- zoom.

## Reading the results

For a 60 FPS target, a frame budget is about `16.7 ms`. Prioritize p95/p99 and isolated spikes over average FPS.

Initial investigation thresholds:

- frame p95 consistently above ~20 ms: visible instability is likely,
- frame p99 above ~30 ms: investigate spikes even if the average FPS looks good,
- any procedural `_rebuild` repeatedly above ~4–5 ms: strong candidate for tile streaming / work slicing,
- high GPU render time with details disabled: focus next on SDFGI, shadows, volumetric fog and 3D resolution,
- high `resident_transport_metrics_ms` or `traffic_refresh_ms` while the camera is stationary: investigate simulation invalidation/cache behavior separately from rendering.

Do not compare captures made with different save states, simulation speeds, camera routes or window sizes.
