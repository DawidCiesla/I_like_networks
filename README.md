# I Like Transit

A passenger-transport incremental / management game prototype inspired by the clarity and map-first progression of games such as *I Like Trains*, but designed around multiple transport modes rather than trains alone.

## Current development status

**Bus Era — natural early-game progression**

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
```

Implemented now:

- one owned stop at fresh start,
- future stops shown directly on the map,
- clicking a ghost stop opens its purchase Inspector,
- buying a stop physically extends the existing line,
- routes use authored transit-map geometry with long straights and rounded bends rather than direct diagonals,
- bus corridors are rendered as real city streets with sidewalks, road edges and markings,
- buses follow the exact same street geometry visible on the map,
- the city grows around new stops: houses, shops, apartments, campus buildings, industrial areas and later taller central buildings,
- ambient road traffic increases as the city expands,
- old stops and previously built route segments never move when the line grows,
- the second stop starts Line 1 with one starter bus,
- line length, cycle time, headway and capacity grow naturally with expansion,
- the third stop unlocks a separate Bus Depot building,
- additional buses can only be purchased from the Bus Depot,
- garage capacity limits the total fleet,
- the depot itself can be expanded,
- line upgrades unlock progressively,
- passengers are generated at specific stops with real destinations,
- waiting passengers are visible at individual stops,
- buses carry an explicit onboard passenger load,
- passengers visibly board and alight,
- **money is credited only when passengers reach their destination and leave the bus**,
- fare income appears as discrete arrival payments instead of passive per-second income,
- overloaded services accumulate waiting passengers,
- Line 2 unlocks only after Line 1 reaches its full route, is operationally stable and the depot has a free vehicle slot,
- Line 2 then grows with the same map-first pattern,
- reset returns to the true one-stop fresh start,
- saves from T1 and earlier prototypes are migrated.

The global BUILD panel is no longer the primary expansion interface. The map is.

See [`docs/bus-era.md`](docs/bus-era.md) for the progression contract, [`docs/passenger-flow.md`](docs/passenger-flow.md) for the trip-based passenger economy, [`docs/map-layout.md`](docs/map-layout.md) for route-layout rules, and [`docs/living-city.md`](docs/living-city.md) for the city-growth layer.

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

Requires Node.js 20+.

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
