# Region loading

Region rendering uses a bounded disk cache in `user://region_visual_cache`.
Terrain and water store mesh arrays; vegetation stores base tree placements.
Materials and current city occupancy are applied again after loading. Cache
misses, invalid entries, and unavailable storage fall back to generation.
The cache retains at most eight entries / 256 MiB, with a 64 MiB entry limit.

Keys include renderer kind, geometry revision, map identity/generator version,
seed, terrain edits, bounds, and resolution. Increment the renderer's
`GEOMETRY_REVISION` when changing sampling, mesh attributes, or placement rules.
Materials do not need invalidation because they are assigned after loading.

On a cold progressive regional terrain build, `TerrainMeshBuilder` submits
between one and four row batches to `WorkerThreadPool` (at most CPU count minus
one, with a minimum of one). Each batch owns its terrain sampler, memoization
caches, and terrain edit data. Workers only calculate packed vertex, color, and
UV arrays. Results are joined in row order, preserving deterministic geometry.
The main thread creates rendering resources, indices, and normals, and updates
scene nodes. Leaving the scene signals cancellation and joins outstanding tasks.

Water, vegetation placement, city simulation, and gameplay remain on the main
thread. Loading work yields between small batches; yielding is not parallelism.
Terrain, water, and vegetation load flags gate simulation startup. Disk IO and
cache reconstruction also currently run on the main thread. Chunk streaming
and terrain LOD are not implemented by this change.

The renderers expose `cache_hit`, `build_duration_ms`, and startup progress;
terrain additionally exposes `worker_count` after its build. `[RegionLoad]`
log entries report each renderer's wall time, including frame waits. Concurrent
renderer times overlap and must not be added as total startup time.

Validation scripts:

- `res://scripts/debug/terrain_sampler_test.gd`: independent concurrent samplers
  and compatibility with the static terrain API.
- `res://scripts/debug/terrain_mesh_builder_test.gd`: exact mesh-array equality
  against the original renderer, including terrain edits.
- `res://scripts/debug/region_visual_cache_test.gd`: round trips, invalidation,
  corrupt entries, and bounded retention.
- `res://scripts/debug/startup_rendering_test.gd`: loading gate, frame yielding,
  reference geometry, and repeat renderer builds from an isolated disk cache.

Observed editor-runtime run on 2026-10-10 (existing starter-region save):

| Renderer | First build | Disk-cache reload |
| --- | ---: | ---: |
| Terrain | 155,217 ms, 4 workers | 53 ms |
| Water | 174,490 ms | 20 ms |
| Vegetation | 184,024 ms | 6,260 ms |

All three cache-hit flags were true on the second run, loading finished, and
GameStore processing resumed. These are observed renderer wall times in a
local debug session, with some headless verification overlapping the first
run; they are not isolated benchmarks or end-to-end launch timings.
