# 3D World and Terrain

## Goal

The game world is now a real 3D city rather than a flat transport diagram.

The simulation remains deterministic and map-first, but the same persistent city objects are visualized as terrain-aware 3D infrastructure.

The rendering contract is:

```text
persistent city / transport simulation
        ↓
world coordinates in metres
        ↓
deterministic terrain height + biome
        ↓
3D roads / buildings / vehicles / nature
        ↓
orbitable camera
```

## Runtime

The browser renderer uses Three.js.

The application stays a native ES-module web application.

The development server exposes the locally installed `three` package through an import map in `index.html`.

Local startup therefore requires:

```bash
npm install
npm run dev
```

## Coordinate system

The simulation continues to use its existing 2D planning coordinates:

```text
city.x
city.y
```

The 3D renderer maps them to:

```text
Three X = city.x
Three Z = city.y
Three Y = terrain height
```

One city unit remains approximately one metre.

This lets the road topology, parcels and transport layout remain independent of the renderer while gaining a vertical dimension.

## Deterministic terrain

`src/world/terrainModel.js` owns terrain generation.

Terrain is generated from:

- persistent city seed,
- broad low-frequency height noise,
- smaller terrain detail,
- a large smooth ridge component,
- deterministic moisture,
- deterministic forest potential.

The same city seed always creates the same landscape.

### Height

`terrainHeight(seed, x, z)` returns terrain elevation in metres.

The first terrain version deliberately uses smooth, buildable hills rather than dramatic mountains.

### Slope

`terrainSlopeDegrees(seed, x, z)` estimates local slope by finite differences.

Slope is simulation data, not merely visual shading.

### Biomes

Current visual biomes:

- grassland,
- meadow,
- forest,
- hillside.

Biomes change terrain colour and forest density. Their terrain colours blend across slope, moisture and forest-potential gradients, with slight seeded low-frequency variation to avoid hard green patches. The forest score reuses the already sampled moisture and slope values when classifying and colouring a terrain point.

## Terrain-aware urban planning

Terrain is now part of city generation.

### Collector choice

When a district can expand to either side of its arterial, the generator evaluates both collector candidates.

The terrain score includes:

- average slope,
- maximum slope,
- forest pressure.

The district's authored morphology remains preferred unless terrain is genuinely worse there.

This avoids a small noise difference completely reorganizing the city while still allowing meaningful terrain adaptation.

### Street rejection

Generated city roads can be rejected if the terrain becomes too steep.

The road topology rules still apply afterwards:

- snapping,
- intersection validation,
- corridor collision,
- reservations.

Terrain never bypasses topology.

### Parcel suitability

Every candidate parcel receives persistent terrain metadata:

- `terrainSlopeDegrees`,
- `forestPotential`.

Steep parcels are rejected.

Forest pressure raises `developmentOrder`, making easy open land develop first and wooded land later.

This provides the first genuine interaction between natural geography and city growth.

## Terrain mesh

The 3D renderer creates one adaptive grid covering the complete authored Bus Era plus a large natural margin.

Every terrain vertex samples:

- height,
- biome colour.

The mesh uses smooth normals and receives shadows.

Roads and buildings sample the exact same height function, so the visual world and simulation terrain cannot drift apart.

## Roads in 3D

Roads are generated as terrain-following ribbon meshes from the semantic road polylines.

At every sample:

1. calculate road tangent,
2. calculate left/right normal,
3. offset by road width,
4. query terrain elevation,
5. generate triangle strip vertices.

Separate meshes are created for:

- sidewalk / verge,
- road surface.

Road classes keep distinct physical widths:

- arterial,
- collector,
- local,
- service.

Real compiled junctions receive shared sidewalk and road disks so T-junctions and crossroads read as one continuous paved surface.

Completed arterials and collectors receive dashed center lines. The renderer batches each road class into one mesh, keeps the markings above the sampled terrain, and trims them near junctions. Local and service streets stay unmarked at this scale. Narrow raised curb strips follow the same semantic road polylines, stop before active junctions (including junctions inside a semantic road), and are batched by road class alongside lane markings. Pedestrian crosswalks use the compiled graph edges to mark visible built road arms at active junctions.

### Construction

A constructing road renders only the prefix corresponding to its persistent construction progress.

This makes road building visibly advance across the landscape.

## Buildings in 3D

Buildings are persistent simulation objects with physical dimensions.

A building profile now stores:

```text
kind
floors
density
heightMeters
```

Typical examples:

- house: ~7.5 m,
- townhouse: ~9 m,
- shop: ~6.5 m,
- apartments / mid-rises: floor-based,
- towers: taller floor-based structures,
- warehouses: broad low structures.

The actual values are stored when the project is created.

### Orientation

When construction starts, the simulation finds the building parcel's frontage road.

The nearest frontage segment determines persistent `rotationRadians`.

Buildings therefore face the street and retain exactly the same orientation after save / reload.

The Godot renderer resolves which side of that frontage contains the parcel and turns the selected model's configured front toward the road. Each model has an explicit local front-side setting because the GLBs do not encode semantic frontage metadata. This is derived at render time; save data and the simulation's frontage angle remain unchanged.

### Foundations

Godot samples the final rotated building footprint on a grid no wider than 8 m. The platform top sits 0.7 m above the highest sample, matching the existing model-to-ground clearance; its underside reaches the lowest sample. A shared `BoxMesh` and one `MultiMeshInstance3D` render every foundation. A building gets its foundation when construction begins, and construction progress only changes the building visual, not the platform.

### Building models

The Godot asset library selects Kenney variants using `kind`, `floors` and `density`. It keeps each model's existing windows, entrance and roof geometry, including pitched residential roofs, flat commercial roofs and industrial roof features. The renderer does not add separate window or roof nodes, so the detailed GLBs remain the facade and roof source.

### Construction animation

A building under construction grows vertically according to `constructionProgress`.

Completed low-rise residential buildings receive a simple pitched roof.

This is intentionally a stylized foundation; architectural variation can be layered on later without changing simulation state.

## Forests and natural land

Forests are generated deterministically from forest potential.

Rendering uses instanced meshes for performance:

- trunk instance,
- crown instance.

Trees exist before development.

They disappear locally when:

- a road is built / under construction,
- a building occupies the site,
- a protected non-park facility reserves the site.

This makes development visibly clear the landscape instead of spawning on top of trees.

Park reservations may retain trees.

## Vehicles

### Stations

Shared station IDs still produce one selectable station. Their visual tier now progresses from a route-marked platform and sign (Stop), through a roofed shelter (Shelter), to an enclosed station (Station) and a larger multi-canopy interchange (Hub). The four tiers reuse cached low-poly meshes; ghost stations use translucent materials and keep the purchase label.

### Buses

Each simulation bus has one persistent `MeshInstance3D` using shared low-poly bus geometry. The model has a route-colored body, dark side/front windows and four wheels, all in two mesh surfaces.

Its position and heading are read from the same transport route interpolation used by gameplay.

The maximum fleet is 32 buses. Each bus keeps one renderer node and reuses the shared mesh; its transform is updated without rebuilding geometry.

### Ambient cars

Ambient traffic appears as completed development grows.

Cars:

- use built arterial / collector geometry,
- sample real terrain height,
- move along lanes rather than through open space,
- pause when simulation time is paused.

Ambient traffic is currently visual only. It does not yet contribute congestion.

## Performance strategy

The 3D foundation avoids rebuilding the entire scene every frame.

Persistent groups:

- terrain,
- nature,
- roads,
- buildings,
- transport,
- dynamic vehicles.

Terrain is rebuilt only when the city seed changes.

Roads / buildings / forests are rebuilt only when relevant city construction state changes.

Vehicle meshes are pooled and reused each frame rather than recreated.

Trees use instancing.

## Camera

The default camera is perspective / orbit based.

Controls:

- left drag: rotate,
- right drag: pan,
- mouse wheel: zoom,
- touch: rotate / pinch-pan.

The polar angle is limited so the camera cannot go underneath the terrain.

## Passenger simulation and route scale

Visible route geometry is now also used as the balancing reference for bus travel.

Bus Era segment distances are approximately:

```text
Line 1:
368 m
675 m
755 m
835 m

Line 2:
707 m
691 m
803 m
```

The average Bus Era operating speed is currently 18 km/h.

This keeps visual motion, route length and gameplay headway in the same scale.

## Current limitations

This milestone does not yet implement:

- terrain flattening / retaining walls under large buildings,
- rivers or coastlines,
- bridges and tunnels,
- true road-grade constraints for authored transport arterials,
- traffic simulation / congestion,
- traffic lights,
- procedural building façades,
- LOD / chunk streaming,
- tram rails,
- pedestrians,
- day / night cycle.

These should build on the current terrain and graph rather than introduce a parallel coordinate system.

## Next architecture steps

Recommended progression:

1. terrain-conforming parcel foundations,
2. building façade / roof archetypes,
3. actual road traffic routing on `graphEdges`,
4. congestion and intersection control,
5. tram tracks embedded in road ribbons,
6. river / water constraints and bridges,
7. district-scale procedural expansion beyond the authored Bus Era,
8. LOD / chunking for a much larger city.


## Performance architecture

The first 3D prototype rebuilt the complete road, building and forest scene whenever construction crossed a progress bucket. That caused visible frame-time spikes even when the final scene was not especially large.

The renderer now uses incremental invalidation.

### Roads

Every semantic road has a cached scene object.

Only the road whose visual state changed is regenerated:

```text
hidden
→ planned
→ constructing progress bucket
→ built
```

Already built roads remain untouched.

Junction meshes are rebuilt only when the set of fully built roads changes.

### Buildings

Building meshes are created once.

Construction animation changes the Y scale and position of the existing mesh rather than allocating new geometry every frame.

A building changes material / roof structure only when its state changes from constructing to built.

### Nature

Forest noise and tree placement are evaluated once per city seed.

Trees remain in persistent instanced meshes.

When development expands, the renderer only updates instance matrices to hide trees occupied by a road or building. Forest geometry and noise are not regenerated.

Tree shadows are disabled; their large number made the shadow pass disproportionately expensive.

### Shadows

The directional-light shadow map is 1024×1024 and uses PCF filtering.

`shadowMap.autoUpdate` is disabled.

A new shadow map is requested only when a shadow-casting building / facility changes enough to matter. Dynamic buses and ambient cars do not cast shadows.

### Resolution

Rendering resolution is adaptive to viewport area.

Large QHD / 4K canvases render at approximately 1× device-independent pixel resolution and do not request MSAA. Smaller displays can use a modest pixel ratio up to 1.35.

CSS / HUD resolution is unaffected.

### Simulation cadence

Passenger vehicles continue updating with the visual frame loop.

The comparatively expensive city-development layer is fixed to:

```text
5 updates / second
```

Its accumulated time is preserved, so construction duration and city growth remain consistent.

HUD DOM writes are limited to 10 Hz.

Autosaves are scheduled during browser idle time and the periodic interval is increased from 2 seconds to about 12 seconds. Player purchases still schedule a save immediately.

### Frame cap

The game performs at most 60 full simulation / render frames per second.

This has no effect on a normal 60 Hz display but prevents a 144 / 165 Hz monitor from forcing the complete WebGL scene to be rendered 144 / 165 times per second.
