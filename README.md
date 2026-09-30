# I Like Transit

A passenger-transport incremental / management game prototype inspired by the clarity and map-first progression of games such as *I Like Trains*, but designed around multiple transport modes rather than trains alone.

## Current development status

**Bus Era — Godot migration in progress**

A native Godot 4.6 port now lives in `godot/` alongside the existing browser build. The browser version remains the gameplay reference until feature parity is reached.

The current Godot milestone already includes deterministic terrain, vegetation, all four Bus Era route geometries, shared physical stations, the Bus Depot, local station upgrades, exact origin→destination passenger queues, real boarding/alighting vehicle phases, arrival-only fare revenue, the canonical 15-district city plan, incremental road/building growth, visible buses, map picking, a city-builder camera, HUD/Inspector and native saves.

See [`docs/godot-port.md`](docs/godot-port.md) for the migration/parity contract.

**Current browser build — 3D living-city foundation**

The current build focuses on making the first minutes of the game feel like a real incremental transport game rather than a systems sandbox.

The player now starts with only one owned stop.

Progression happens directly on the map:

```text
first stop
→ buy second stop
→ Line 1 opens with one bus
→ earn fare revenue
→ extend the line
→ service becomes strained
→ Bus Depot unlocks
→ buy more buses
→ extend Line 1 further
→ stabilize Line 1
→ Bus Line 2 unlocks
→ extend and stabilize Line 2
→ Bus Line 3 unlocks at University
→ extend and stabilize Line 3
→ Bus Line 4 unlocks at Harbor
→ close the network back into Central
→ upgrade busy physical stations into hubs
```

Implemented now:

- the default game world is rendered in real-time 3D with Three.js,
- the 3D renderer uses incremental scene updates instead of rebuilding the whole city during construction,
- large QHD / 4K viewports use a reduced render pixel ratio and skip MSAA,
- shadow maps update on demand rather than every frame,
- city-development logic runs at a fixed 5 Hz while vehicle motion remains frame-smooth,
- the main render loop is capped at 60 FPS, preventing 120–165 Hz displays from multiplying GPU work,
- orbit camera: left-drag rotates, right-drag pans, mouse wheel zooms,
- deterministic height-field terrain generated from the persistent city seed,
- terrain contains grassland, meadow, forest and hillside biomes,
- forests are rendered with instanced low-poly trees,
- roads conform vertically to the terrain surface,
- city planning evaluates slope and forest pressure before accepting development,
- collectors can prefer the easier side of a transport corridor when terrain strongly favors it,
- steep parcels are rejected and wooded parcels develop more slowly,
- buildings persist real height in metres and a street-facing orientation,
- building construction visibly grows upward in 3D,
- houses receive simple pitched roofs while denser buildings become taller blocks / towers,
- ambient 3D car traffic grows with the number of completed buildings,
- buses are physical 3D vehicles moving along the same geometry as their route,
- one owned stop at fresh start,
- future stops shown directly on the map,
- clicking a ghost stop opens its purchase Inspector,
- buying a stop physically extends the existing line,
- routes use authored transit-map geometry with long straights and rounded bends rather than direct diagonals,
- Bus Era now uses approximately real-world city scale: one world unit ≈ one metre and neighboring stops are roughly 350–850 m apart,
- bus corridors are rendered as real city streets with sidewalks, road edges and markings,
- buses follow the exact same street geometry visible on the map,
- the city has a persistent deterministic master plan stored in the save,
- roads, districts, blocks and parcels exist as real simulation objects rather than renderer decorations,
- every local street has explicit parent-road dependencies and construction grows outward from already connected streets,
- road planning is intersection-aware: candidates snap to the network, split at real crossings, reject acute crossings and reject overlapping / near-parallel corridors,
- the persistent city stores a compiled junction graph so crossings become real graph nodes rather than visual line overlaps,
- roads are generated hierarchically as arterial → collector → local streets,
- predefined infrastructure uses protected reservations, so later parcels can never invade the Bus Depot or City Park site,
- each new stop activates a district but does not instantly spawn a finished neighborhood,
- secondary streets are constructed over time,
- parcels start individual construction projects only after accessibility and development pressure become sufficient,
- buildings visibly progress from construction site to completed structure,
- building lots are validated against all present and future roads, stops, the depot and other parcels,
- every valid parcel stores persistent street frontage,
- houses, shops, apartments, campus buildings, industrial areas and later taller central buildings appear progressively,
- ambient road traffic increases as the city expands and follows built arterials / collectors,
- map labels and passenger counters stay compact so transport remains readable,
- junction rendering closes road surfaces into seamless T-junctions and crossroads instead of overlapping strokes,
- old stops and previously built route segments never move when the line grows,
- the second stop starts Line 1 with one starter bus,
- line length, cycle time, headway and capacity grow naturally with expansion,
- the third stop unlocks a separate Bus Depot building,
- additional buses can only be purchased from the Bus Depot,
- garage capacity limits the total fleet,
- the depot itself can be expanded,
- every physical stop has its own upgrade path: Stop → Shelter → Station → Hub,
- station upgrades increase local waiting capacity, slightly reduce dwell time and grow local catchment demand,
- shared interchanges are one physical station rather than duplicated per line,
- City Park serves Lines 1 + 2,
- University serves Lines 1 + 3,
- Harbor serves Lines 2 + 4,
- Central serves Lines 1 + 4,
- station upgrades are selected directly from the map,
- passengers are generated at specific stops with real destinations,
- waiting passengers are visible at individual stops,
- buses carry an explicit onboard passenger load,
- passengers visibly board and alight,
- **money is credited only when passengers reach their destination and leave the bus**,
- fare income appears as discrete arrival payments instead of passive per-second income,
- overloaded services accumulate waiting passengers,
- Line 2 unlocks only after Line 1 reaches its full route, is operationally stable and the depot has a free vehicle slot,
- Line 2 then grows with the same map-first pattern,
- Line 3 branches from University toward North Quarter, Hillcrest, Northgate and Meadow End,
- Line 4 branches from Harbor through Docklands, Eastgate and Stadium before reconnecting to the existing Central interchange,
- the Bus Era city master plan now contains 15 districts with terrain-aware growth around all four routes,
- the depot supports the larger fleet with +4 garage slots per upgrade,
- reset returns to the true one-stop fresh start,
- saves from T1 and earlier prototypes are migrated.

The global BUILD panel is no longer the primary expansion interface. The map is.

See [`docs/bus-era.md`](docs/bus-era.md) for the progression contract, [`docs/passenger-flow.md`](docs/passenger-flow.md) for the trip-based passenger economy, [`docs/map-layout.md`](docs/map-layout.md) for route-layout rules, [`docs/living-city.md`](docs/living-city.md) for the visual city layer, [`docs/city-generation-system.md`](docs/city-generation-system.md) for persistent city simulation, [`docs/road-topology.md`](docs/road-topology.md) for street-graph invariants, and [`docs/3d-world.md`](docs/3d-world.md) for the 3D terrain/rendering contract.

## Planned transport families

The domain model still contains the long-term transport families:

- bus,
- tram,
- metro,
- rail,
- ferry,
- air.

The current phase deliberately stays bus-only. New modes should be introduced only after the bus-era progression itself feels satisfying.

## Core interaction rule

Infrastructure is additive.

A purchase should normally mean clicking something spatially meaningful on the map:

- a future stop,
- a future facility,
- a future branch,
- or an existing object to inspect / upgrade it.

Existing lines and stations do not teleport when new content is unlocked.

## Run locally

### Godot port

Requires Godot 4.6.

```bash
godot --path godot
```

Headless parity smoke test:

```bash
godot --headless --path godot --script res://scripts/debug/self_test.gd
```

Regenerate the canonical default-seed city fixture from the browser generator:

```bash
npm run godot:fixture
```

### Browser reference build

Requires Node.js 20+.

Install dependencies once:

```bash
npm install
```

Then start the local server:

```bash
npm run dev
```

Open:

```text
http://127.0.0.1:5173
```

## Tests

```bash
npm test
npm run check
```
