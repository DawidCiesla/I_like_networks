# Godot Runtime

## Status

The migration is complete for the current Bus Era.

**Godot 4.7 is the primary runtime of I Like Transit.**

The older Three.js/browser implementation remains in the repository only as:

- a legacy reference build,
- a regression source for historical behavior,
- a one-click exporter for browser saves created before the migration.

The Godot runtime no longer requires Node.js, Three.js or a pre-generated JS city fixture to start a new game.

## Current native feature set

The Godot build now owns the full playable Bus Era loop:

- one-stop fresh start,
- Lines 1–4,
- Bus Depot,
- shared physical interchanges,
- individual station upgrades,
- exact origin → destination passenger queues,
- real boarding / dwell / travel / alighting phases,
- onboard passenger loads,
- fare credited only after destination arrival,
- waiting-capacity overflow and abandonment,
- native save/load,
- browser-save import,
- native deterministic terrain,
- native procedural 15-district city master-plan generation,
- native road graph / junction compilation,
- transport-driven district activation,
- road construction dependencies,
- parcels,
- construction projects,
- procedural building height / orientation,
- progressive city growth,
- vegetation clearing,
- visible waiting passengers,
- boarding/alighting visual effects,
- visible buses,
- ambient car traffic,
- orbit/pan/zoom camera,
- map-first building and station interaction,
- responsive pixel-style HUD with resources, objective, line legend and contextual inspector.

## Runtime architecture

The authoritative state lives outside rendering nodes:

```text
GameStore
├─ transport state
├─ passenger state
├─ economy
├─ station state
├─ depot
├─ city runtime
└─ persistence
        ↓
CityPlanGenerator
RoadTopology
TerrainModel
TransportLayout
        ↓
render-only layers
├─ TerrainRenderer
├─ VegetationRenderer
├─ CityRenderer
├─ NetworkRenderer
├─ PassengerRenderer
└─ TrafficRenderer
```

Renderers never own gameplay state.

## Native procedural city generation

New games call:

```gdscript
CityPlanGenerator.generate(seed)
```

directly in Godot.

The generator creates:

- 15 district definitions,
- transport arterials,
- collectors,
- local/service streets,
- protected reservations,
- blocks,
- buildable parcels,
- a compiled road graph,
- real junction records.

Terrain affects:

- preferred district growth direction,
- parcel viability,
- forest pressure.

The generator guarantees a minimum viable local street network and parcel set even on difficult seeds.

The old file:

```text
godot/data/master_plan_284731.json
```

is no longer used by the runtime.

It is retained only as a golden regression fixture for the historical default-seed JS generator.

## Passenger simulation

Each line stores a full waiting matrix:

```text
origin stop × destination stop
```

Vehicles store:

- current stop,
- next stop,
- travel direction,
- phase,
- phase time remaining,
- passengers by destination,
- total onboard load.

Vehicle phase progression is:

```text
dwell
→ boarding
→ travel
→ alight at destination
→ dwell
```

Revenue is created only by alighting passengers.

The renderer consumes passenger events but does not alter passenger counts.

## Visible passengers

Each built station shows a compact crowd representation based on real waiting passengers.

The visualization is deliberately capped, so a queue of hundreds of passengers does not create hundreds of scene nodes.

Board/alight events create short 3D transfer effects.

Fare-producing alight events also display a world-space income popup.

## Ambient traffic

Ambient cars are generated only on fully built arterial/collector roads.

Car count scales with completed city buildings and is capped.

Traffic is decorative in the current Bus Era and does not affect travel times yet.

It is implemented as a separate renderer so a later congestion simulation can replace its motion source without changing the road/city model.

## Kenney city-kit visuals

Curated Kenney City Kit GLB models provide visual variants for residential, commercial, industrial and civic buildings. The asset library chooses variants from `kind`, `floors` and `density`, fits the complete model uniformly inside the parcel footprint and profile height, and aligns its configured front with the frontage road. Since the GLBs do not encode semantic frontage metadata, the local front-side mapping is explicit per model and should be checked when adding or replacing assets. The imported assets already carry their facade and roof features, so the renderer keeps those details without adding duplicate window or roof geometry. If an imported scene has no usable geometry, the renderer falls back to the existing procedural block.

Building platforms use the final rotated model footprint plus a small edge margin. Terrain samples are spaced at most 8 m apart; the shared platform level is 0.7 m above the highest sample and its lower edge reaches the lowest sample. All foundations share one `BoxMesh` in a single `MultiMeshInstance3D`; they appear as construction starts and stay fixed while the building grows. This path changes render geometry only and does not alter terrain, city simulation or save data.

The suburban kit's small and large trees are batched into two `MultiMeshInstance3D` nodes while retaining the existing terrain and city-clearance rules. A render-only low-frequency mask groups them into deterministic groves and clearings; it does not change terrain biomes or city planning.

Terrain colours now blend across moisture, forest-potential and slope gradients with a small deterministic surface variation; biome classification and city-growth thresholds are unchanged. The Roads kit currently supplies roadside lights. They are placed only along completed arterial/collector roads and rendered through one `MultiMeshInstance3D`; semantic road geometry and junction shapes remain generated from the city road graph. Completed arterials and collectors also get dashed center lines; narrow raised curb strips follow built and constructing semantic roads, stop before active junctions (including intersections inside a semantic road), and are batched by road class. Crosswalks are batched from graph edges for built arms at active junctions. These details rebuild only when road state changes. Shared station IDs render once, with tier-specific Stop, Shelter, Station and Hub meshes. Buses use shared low-poly geometry with route-colored bodies, dark windows and four wheels. The HUD uses a shared Theme plus reusable stat and line-legend row scenes; the inspector scrolls, and the layout moves to a bottom dock on narrow viewports. Each imported kit subset keeps its own `License.txt` and texture atlas under `godot/assets/kenney/`.

## Save files

Godot currently stores:

```text
user://save_godot_v2.json
```

The save includes:

- money,
- elapsed time,
- simulation speed,
- city seed,
- all four lines,
- OD waiting matrices,
- vehicle phase state,
- onboard passengers,
- station levels,
- depot,
- lifetime statistics,
- generated city plan,
- road/project state,
- buildings and development progress.

Existing Godot v2 saves remain compatible.

## Importing the old browser save

The legacy browser build has a button:

```text
EXPORT SAVE FOR GODOT
```

It downloads:

```text
i-like-transit-browser-save-v12.json
```

In Godot press:

```text
IMPORT WEB SAVE
```

and select that file.

The importer preserves:

- money,
- elapsed time,
- simulation speed,
- Lines 1–4,
- stop progress,
- fleets,
- waiting OD matrices,
- vehicle state,
- passenger events,
- station upgrades,
- Bus Depot,
- lifetime revenue/passengers,
- city seed,
- roads/districts/parcels,
- buildings,
- active construction projects.

After import the state is immediately saved in the native Godot format.

## Run

Install Godot 4.7.

From the repository root:

```bash
godot --path godot
```

or open:

```text
godot/project.godot
```

in the Godot editor.

No third-party Godot addons are required.

## Controls

- left mouse drag — orbit,
- right mouse drag — pan,
- mouse wheel — zoom,
- `F` — reset camera,
- `Space` — pause/resume,
- click station — inspect / upgrade,
- click ghost stop — extend line,
- click ghost branch — open new line,
- click Bus Depot — buy buses / expand garage.

## Headless validation

Run:

```bash
godot --headless --path godot --script res://scripts/debug/self_test.gd
```

or:

```bash
npm run godot:test
```

The self-test checks:

- shared physical interchanges,
- route geometry,
- terrain determinism,
- arrival-only fare behavior,
- local station upgrades,
- historical golden fixture integrity,
- native procedural plans across multiple seeds,
- city growth runtime,
- browser v12 save conversion.

## Legacy web build

The browser build still runs with:

```bash
npm install
npm run dev
```

It is no longer the primary runtime.

Its remaining migration-specific purpose is to export old localStorage progress through **EXPORT SAVE FOR GODOT**.

## Future development

New gameplay should be implemented in Godot first.

The next transport families can build on the native model:

- tram,
- metro,
- rail,
- ferry,
- air.

The legacy Three.js renderer should not receive new gameplay systems unless required for a regression comparison.
