# Transport Refactor — Phase T0

## Purpose

Phase T0 converts the existing network-management prototype into a passenger-transport game without discarding the simulation work already completed.

The goal is not to add a large amount of new content yet. The goal is to establish a clean transport-domain foundation before continuing normal feature phases.

## Core semantic mapping

The previous network concepts are replaced by transport concepts:

| Previous concept | Transport concept |
|---|---|
| traffic source | passenger-generating stop / district |
| link capacity | line passenger capacity |
| switch | local terminal |
| switch buffer | waiting area |
| router | transfer interchange |
| router throughput | interchange transfer capacity |
| server | passenger destination station |
| queue | waiting passengers |
| packet loss | passengers abandoning the queue |
| throughput | passengers delivered per minute |
| network route | passenger service / line |

The implementation now uses transport names directly instead of keeping network terminology under transport labels.

## Current playable topology

The T0 build contains two possible passenger corridors.

### Line 1

```text
Northside stops
      │
Northside Terminal
      │
Central Interchange
      │
Central Station
```

Line 1 uses buses.

### Line 2

After the interchange is built:

```text
Riverside stops
      │
Central Interchange
      │
Harbor Station
```

Line 2 also uses buses in T0.

Passengers from Riverside can initially transfer toward Central Station even before Harbor Station is built.

## Passenger demand

Each active stop generates passenger demand in passengers per minute.

For Line 1:

```text
demand A = number of stops × demand per stop
```

For Line 2:

```text
demand B = number of stops × demand per stop
```

Demand is aggregated. The simulation does not create an independent logical object for every passenger.

## Capacity chain

### Before the interchange

Line 1 is constrained by:

```text
passenger demand
→ Northside Terminal throughput
→ Line 1 capacity
→ Central Station capacity
```

### After the interchange

Line 1 and Line 2 feed a shared transfer hub:

```text
Line 1 ─┐
        ├─ Central Interchange ─┬─ Central Station
Line 2 ─┘                       └─ Harbor Station
```

Each stage can independently become a bottleneck.

## Waiting passengers

When incoming passenger demand exceeds service capacity, passengers accumulate in a waiting area.

Waiting passengers are represented explicitly in the simulation as aggregate queue counts.

The map shows waiting passengers visually near the active bottleneck.

## Queue abandonment

Waiting areas have finite capacity.

When a queue exceeds its available waiting space, excess passengers abandon the journey.

This replaces the previous packet-loss mechanic.

The UI exposes:

- waiting passenger count,
- average wait,
- percentage of passengers leaving the queue.

## Revenue

Revenue is generated only from successfully delivered passengers.

```text
revenue = delivered passengers × fare
```

Waiting or abandoning passengers generate no fare revenue.

## Transport modes

The domain model already defines the intended long-term transport families:

- bus,
- tram,
- metro,
- rail,
- ferry,
- air.

Only bus service is enabled in T0.

Future modes must receive different operational characteristics. They must not be implemented as simple cosmetic skins.

Examples of future differentiation:

- vehicle capacity,
- infrastructure cost,
- cruising speed,
- dwell time,
- achievable frequency,
- right-of-way / congestion behavior,
- station requirements,
- operating cost,
- range.

## Map behavior

The additive-map rule remains mandatory.

Building infrastructure must never arbitrarily relocate existing infrastructure.

Examples:

- building Central Interchange materializes it on the existing Line 1 corridor,
- opening Line 2 adds a new branch,
- building Harbor Station extends that branch,
- existing Line 1 stops stay where they were.

## Contextual upgrades

There is no global upgrade list.

### Line 1 Inspector

- add stop,
- expand catchment,
- add buses / increase frequency.

### Northside Terminal Inspector

- improve platform throughput,
- expand waiting space while that queue is active.

### Central Interchange Inspector

- increase transfer capacity,
- inspect service board,
- inspect waiting and abandonment.

### Central Station Inspector

- expand destination capacity.

### Line 2 Inspector

- add stop,
- add buses / increase frequency.

### Harbor Station Inspector

- expand destination capacity.

## Visual language

T0 keeps the established visual direction:

- near-black background,
- subtle cross-grid,
- high-contrast pixel-art infrastructure,
- colored service lines,
- compact edge UI,
- contextual panels,
- visible moving vehicles.

The previous packet dots are removed.

Moving objects on transport lines are now pixel-art buses.

## Save migration

Game-state version is incremented to version 4.

Saves from versions 1–3 are migrated into the transport model.

The migration preserves, where possible:

- money,
- elapsed time,
- simulation speed,
- infrastructure unlocks,
- capacities,
- upgrade levels,
- queues,
- secondary branch progression,
- lifetime revenue.

Old network throughput history is mapped into lifetime passenger progression only as a compatibility fallback.

## T0 validation gate

Before continuing to the next major gameplay phase, verify:

1. The build reads immediately as passenger transport, not computer networking.
2. Visible moving objects are buses, not generic packets.
3. Stops generate passenger demand.
4. Waiting passengers visibly accumulate when capacity is insufficient.
5. Improving the correct line/station clears the corresponding bottleneck.
6. Central Interchange clearly communicates transfers between services.
7. Existing Line 1 geometry does not move when the interchange is built.
8. Line 2 and Harbor Station are added as extensions rather than map replacements.
9. All upgrades remain contextual to the selected line/station/hub.
10. Existing version 1–3 saves migrate without crashing.

## What comes after T0

The next normal development phase should build on transport concepts only.

Strong candidates include:

- passenger trip destinations and route choice,
- service frequency and vehicle fleets,
- distinct vehicle classes,
- tram as the first non-bus mode,
- travel-time and transfer penalties,
- passenger satisfaction,
- operating costs and line profitability.

The next phase should not reintroduce network terminology into the simulation model.
