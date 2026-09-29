# Interaction Model — Additive Transport Map and Contextual Upgrades

## Problem

A single global control panel does not scale with the game.

As more lines, stops, stations and transport modes are unlocked, a global list would grow until it obscures the map. It would also make the game feel menu-driven instead of spatial.

The transport map must remain stable. Building a new interchange, line or destination must not arbitrarily relocate infrastructure the player has already built.

## Rules

### 1. Existing infrastructure does not move because of an unlock

Stops, stations and hubs receive stable world coordinates.

A newly unlocked transport element is inserted into or attached to the existing layout without moving older elements.

Example:

```text
Before interchange:

Stop ---- [future interchange position] ---- Central Station

After interchange:

Stop -------- Central Interchange ---------- Central Station
```

The existing corridor geometry remains recognizable.

### 2. Expansion is additive

New services create new branches.

```text
                           Central Station
                                 /
Northside ---- Central Interchange
                                 \
                                  Harbor Station
                    /
               Riverside
```

Riverside and Harbor Station are added without rebuilding Northside or Central Station.

### 3. BUILD contains only genuinely new infrastructure

The BUILD menu lists infrastructure that has not yet been created.

Once an item is built, it disappears from BUILD.

Examples:

- Bus Line 1,
- Northside Terminal,
- Central Interchange,
- Bus Line 2,
- Harbor Station.

Stop expansion and capacity upgrades do not belong in the global BUILD list.

### 4. Upgrades are contextual

Clicking a map element opens its Inspector.

Examples:

#### Bus Line 1
- add stop,
- expand passenger catchment,
- add buses / increase frequency.

#### Northside Terminal
- platform throughput,
- waiting capacity.

#### Central Interchange
- transfer capacity,
- service board,
- passenger waiting diagnostics.

#### Central Station
- platform / arrival capacity.

#### Bus Line 2
- add stop,
- add buses / increase frequency.

#### Harbor Station
- destination capacity.

Only relevant controls are shown.

### 5. The map is the primary interface

The player should identify a problem spatially first and click the relevant transport element second.

The Inspector supplements the map instead of replacing it.

### 6. Selection is persistent but lightweight

The selected stop, line, station or hub receives a small dashed outline.

Closing the Inspector removes the selection.

### 7. Future phases must follow the same model

Contracts, failures, timetables, fleets, multimodal transfers and later systems must not reintroduce one giant global upgrade menu.

New functionality should be attached to:

- a selected map object,
- a compact dedicated overlay,
- or BUILD when it represents genuinely new infrastructure.

### 8. New transport modes are additive

Introducing tram, metro, rail, ferry or air transport should add new infrastructure or parallel services.

A bus line must not disappear simply because a higher-capacity transport mode becomes available.

Example:

```text
A ───── B   Bus Line
A ═════ B   Metro Line
```

Both services can coexist and compete for passenger demand.
