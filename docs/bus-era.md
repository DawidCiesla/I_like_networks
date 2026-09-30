# Bus Era — Four-Line Network Progression

## Goal

The Bus Era is the first complete progression layer of I Like Transit.

The player grows one visible transport network directly on the 3D city map:

```text
one owned stop
→ Line 1
→ Bus Depot
→ larger Line 1 fleet
→ Line 2
→ Line 3
→ Line 4
→ interconnected bus network
→ upgrade busy stations into hubs
```

Expansion is additive. Existing roads, stations and lines never move just because later content unlocks.

## Fresh start

A fresh save contains:

- $100,
- Old Town as the only owned stop,
- no active route,
- no buses,
- no depot,
- Lines 2–4 locked.

Market Square appears as the first ghost stop.

Buying it starts Line 1 and grants one starter bus.

## Line 1

Stops:

1. Old Town
2. Market Square
3. City Park
4. University
5. Central

The third stop creates the first intentional capacity pressure and unlocks the Bus Depot.

The player learns:

```text
longer route
→ longer cycle
→ worse headway
→ waiting passengers
→ more buses
```

Line 1 must be completed and operationally stable before Line 2 becomes available.

## Bus Depot

The Bus Depot is a separate physical facility.

It:

- stores the shared bus fleet,
- is the only place additional buses can be purchased,
- limits the total number of buses,
- starts with four slots,
- gains four additional slots per garage expansion.

Each new bus line includes one starter bus, but it still requires a free garage slot.

## Line 2

Line 2 branches from the existing City Park station.

Stops:

1. City Park
2. Riverside
3. Museum
4. Harbor

City Park is not duplicated. It becomes a real interchange shared by Lines 1 and 2.

Line 3 unlocks only after Line 2 is complete, stable and the depot has room for its starter bus.

## Line 3

Line 3 branches from University.

Stops:

1. University
2. North Quarter
3. Hillcrest
4. Northgate
5. Meadow End

University becomes an interchange shared by Lines 1 and 3.

The route leaves the existing Line 1 corridor immediately instead of overlapping it.

Line 3 opens several new northern districts and pushes city growth into new terrain.

## Line 4

Line 4 begins at Harbor.

Stops:

1. Harbor
2. Docklands
3. Eastgate
4. Stadium
5. Central

Harbor is shared by Lines 2 and 4.

The final Line 4 extension does not create a second Central station. It reconnects the route into the existing Central interchange shared with Line 1.

This creates the first larger network loop.

## Physical station model

A station is a persistent city object identified independently from the line that serves it.

Examples:

```text
City Park
  ├─ Line 1
  └─ Line 2

University
  ├─ Line 1
  └─ Line 3

Harbor
  ├─ Line 2
  └─ Line 4

Central
  ├─ Line 1
  └─ Line 4
```

A shared interchange has one upgrade level and one physical 3D object.

## Station upgrades

Each built station is upgraded individually.

Progression:

```text
Stop
→ Shelter
→ Station
→ Hub
```

Current levels:

| Level | Name | Waiting capacity |
| --- | --- | ---: |
| 0 | Stop | 45 pax / line |
| 1 | Shelter | 70 pax / line |
| 2 | Station | 105 pax / line |
| 3 | Hub | 150 pax / line |

A local station upgrade:

- increases waiting capacity,
- slightly reduces dwell time,
- slightly expands local passenger demand / catchment,
- changes the physical station model in 3D.

It does not upgrade every stop on the line.

This means the player can spend money where pressure actually appears.

## Map-first interaction

The map is the build interface.

Clickable objects include:

- future stops,
- future line branches,
- the Bus Depot,
- existing stations,
- connection halos around existing interchanges.

Clicking an existing station opens its own Inspector.

Clicking a future stop opens the purchase Inspector for that line extension.

When a line is about to connect to an already existing station, the map shows a larger **CONNECT** halo rather than placing a duplicate ghost station on top of it.

## Passenger economy

Passengers are generated at individual stops with specific destinations.

Money is credited only when a passenger reaches the destination and leaves the bus.

Station upgrades therefore interact with actual passenger flow rather than passive income.

## City relationship

The full Bus Era master plan now contains 15 districts.

New line construction opens new city growth corridors:

- Line 1 establishes the initial core,
- Line 2 expands toward Riverside / Museum / Harbor,
- Line 3 opens the northern neighborhoods,
- Line 4 opens Docklands / Eastgate / Stadium and reconnects to Central.

Terrain constraints remain active for all districts.

Docklands intentionally uses a more compact industrial parcel pattern than residential districts.

## Unlock contract

The sequential unlock rule is:

```text
complete current line
+ keep current line capacity >= demand
+ own Bus Depot
+ have one free garage slot
= next line becomes available
```

This currently applies to Line 2, Line 3 and Line 4.

## Bus Era validation gate

Before introducing trams, verify:

1. Reset starts with exactly one owned stop.
2. Buying Market Square activates Line 1.
3. The starter bus appears physically.
4. Passenger revenue is paid on arrival.
5. City Park creates natural early capacity pressure.
6. Bus Depot is required for additional buses.
7. Garage capacity applies across all lines.
8. Existing route geometry never moves during expansion.
9. Line 2 branches from the existing City Park station.
10. Line 3 branches from the existing University station.
11. Line 4 branches from the existing Harbor station.
12. Line 4 reconnects to the existing Central station.
13. Shared stations render once rather than once per line.
14. Clicking a station opens that physical station's Inspector.
15. Station upgrades affect only the selected physical station.
16. Station upgrade level is shared across every line serving the interchange.
17. Stop → Shelter → Station → Hub visibly changes the 3D station.
18. All four lines can be completed and stabilized without exceeding per-line fleet limits.
19. New districts grow around Lines 3 and 4 without accidental road overlaps.
20. Reset reliably returns to the one-stop state.

## Deferred

The Bus Era still intentionally does not include:

- tram,
- metro,
- rail,
- simulated car congestion,
- traffic lights,
- manual timetables,
- multiple bus vehicle models,
- route-choice AI between alternative passenger paths.

Those systems should build on the four-line bus network rather than replace it.
