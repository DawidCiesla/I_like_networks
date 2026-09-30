# Transport Map Layout Rules

The visual network should read like a deliberately planned transit map rather than a set of direct point-to-point connections.

These rules are based on the visual language established by the reference screenshots.

## Route geometry

Lines should primarily use:

- long readable straight sections,
- horizontal and vertical alignment,
- occasional stepped offsets,
- rounded 90-degree bends,
- clear spacing between neighboring corridors.

Avoid connecting two stations with a raw diagonal merely because it is the shortest geometric path.

A route should look authored.

## Stable expansion

Every stop-to-stop segment has fixed geometry.

When a new stop is purchased:

- the previous route remains pixel-for-pixel unchanged,
- only the new segment becomes active,
- the camera does not reorganize the existing network,
- old stops never move.

This is enforced by keeping each route segment as an independent authored path.

## Branches

New lines should branch from an intentional interchange node.

For the current Bus Era:

- Line 1 is the primary corridor,
- City Park is the first shared interchange,
- Line 2 leaves City Park toward the lower-right side of the map,
- the two lines separate quickly so their colors remain readable.

A branch should not sit on top of the parent line for a long distance unless shared infrastructure is an explicit mechanic.

## Shared stations

A station served by multiple lines should visually communicate that fact.

City Park receives a two-color interchange ring once Line 2 opens.

Future multi-line stations should follow the same approach.

## Depots and facilities

Operational buildings should sit beside the passenger corridor rather than directly on top of it.

The Bus Depot therefore uses a short side spur from City Park.

This leaves the passenger network readable while still showing that the depot is physically connected to the system.

## Vehicle movement

Visible vehicles must follow the exact authored route geometry.

Rendering must never interpolate a hidden straight line between two stops while the visible route bends elsewhere.

The same route definition is used for:

- built track/road rendering,
- ghost future segments,
- vehicle position,
- vehicle direction.

## Visual density

Early Bus Era maps should remain sparse.

Leave empty space around the first two lines so later systems can grow naturally into the map.

Density should increase because the player builds more infrastructure, not because the initial layout is crowded.

## Current Bus Era layout

Line 1:

```text
Old Town ─ Market Square
                 │
                 ╰─ City Park ─────╮
                                   │
                              University ─────╮
                                             │
                                          Central
```

Line 2 branches from City Park and occupies a separate lower corridor:

```text
City Park
   │
   ╰──── Riverside
             │
             ╰──── Museum ─────╮
                               │
                            Harbor
```

The exact canvas coordinates are defined in:

```text
src/render/transportLayout.js
```

Simulation logic must not depend on those screen coordinates.
