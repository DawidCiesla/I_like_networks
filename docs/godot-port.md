# Godot Port

## Status

The Godot port is being developed in parallel with the current browser / Three.js build.

The web version remains the gameplay reference until Godot reaches feature parity.

Current Godot milestone:

- Godot 4.6 project,
- deterministic terrain,
- terrain biomes,
- instanced vegetation,
- all four Bus Era route geometries,
- physical shared stations,
- local station levels,
- Bus Depot,
- visible bus vehicles,
- orbit / pan / zoom camera,
- map picking,
- Inspector / HUD,
- core four-line progression rules,
- native Godot save file.

Not yet at parity:

- exact per-passenger OD matrix simulation,
- waiting passengers rendered at stops,
- boarding / alighting visuals,
- the full 15-district city generator,
- road topology / junction graph,
- persistent parcels and construction projects,
- procedural 3D buildings,
- ambient car traffic,
- import of the browser localStorage save.

## Directory layout

```text
godot/
  project.godot
  scenes/
    main.tscn
  scripts/
    core/
      game_data.gd
      game_store.gd
    transport/
      transport_layout.gd
    world/
      terrain_model.gd
      terrain_renderer.gd
      vegetation_renderer.gd
    render/
      network_renderer.gd
    camera/
      city_camera.gd
    ui/
      hud.gd
    debug/
      self_test.gd
```

## Architecture

The port deliberately keeps simulation state separate from rendering.

```text
GameStore
   ↓
gameplay state / economy / progression
   ↓
TransportLayout + TerrainModel
   ↓
render-only Node3D layers
```

The intended final architecture is:

```text
simulation state
├─ passengers
├─ stations
├─ lines
├─ vehicles
├─ city
├─ roads
├─ parcels
└─ buildings

rendering
├─ terrain
├─ vegetation
├─ roads
├─ stations
├─ buildings
└─ vehicles
```

A renderer should never become the authoritative gameplay state.

## Run

Install Godot 4.6.

From the repository root:

```bash
godot --path godot
```

or open:

```text
godot/project.godot
```

in the editor.

The project has no third-party Godot addons.

## Headless self-test

```bash
godot --headless --path godot --script res://scripts/debug/self_test.gd
```

The current self-test validates:

- shared physical interchanges,
- all four route geometries,
- real-world stop spacing for Lines 3 and 4,
- deterministic terrain,
- sane slope / forest samples.

## Controls

- left mouse drag — orbit,
- right mouse drag — pan,
- mouse wheel — zoom,
- F — reset camera,
- Space — pause / resume,
- click a station — inspect / upgrade,
- click a ghost stop — extend its line,
- click a ghost new-line branch — open that line,
- click the Bus Depot — buy buses / expand garage.

## Save format

The initial Godot port writes:

```text
user://save_godot_v1.json
```

This is intentionally separate from the browser localStorage save.

The schema stores:

- money,
- elapsed time,
- speed,
- city seed,
- four line states,
- station levels,
- depot state,
- lifetime revenue / passengers.

A dedicated browser-save importer should be added once the Godot passenger and city models reach parity. Importing earlier would create misleading partially-compatible saves.

## Parity roadmap

### G0 — runtime foundation

Done in this milestone:

- project boot,
- camera,
- HUD,
- deterministic terrain,
- rendering split,
- native save.

### G1 — transport geometry and Bus Era shell

Done in this milestone:

- Lines 1–4,
- shared interchanges,
- Bus Depot,
- station upgrades,
- buses,
- map-first purchasing.

### G2 — exact passenger simulation

Next:

- waiting matrix per origin/destination,
- physical onboard loads,
- stop dwell phases,
- boarding / alighting,
- fare only on destination arrival,
- abandonment,
- exact parity tests against the JS model.

### G3 — persistent city model

Port:

- 15 districts,
- road construction projects,
- blocks,
- parcels,
- building projects,
- terrain pressure,
- protected reservations.

### G4 — topology

Port:

- snapping,
- real intersections,
- semantic roads,
- junction graph,
- corridor collision,
- parent / terminal connections.

### G5 — 3D city parity

Port:

- procedural roads,
- sidewalks,
- junction meshes,
- building heights / orientation,
- construction animation,
- forest clearing,
- ambient traffic.

### G6 — save migration

- JSON export path from web version,
- v12 browser save → Godot conversion,
- cross-runtime parity fixtures.

### G7 — switch primary runtime

Only after:

```text
Godot gameplay parity
+ deterministic parity fixtures
+ acceptable performance
+ save migration verified
```

Then the Three.js runtime can be retired.
