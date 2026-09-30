# Road Topology Core

## Purpose

City roads are no longer accepted because a polyline happens to fit visually.

Every road must be valid as part of one persistent street network.

The topology contract is:

```text
existing road network
→ choose an attachment
→ snap to the network
→ propose corridor
→ find crossings
→ trim / connect where appropriate
→ validate intersection angle
→ validate corridor clearance
→ validate protected reservations
→ accept semantic road
→ compile crossings into graph nodes
```

## Semantic roads versus graph edges

The city stores two related representations.

### Semantic road

A semantic road is the street the player sees:

```text
collector-market
local-market-cross-0-left
arterial-line1-1
```

It stores:

- stable road ID,
- road class,
- district,
- polyline,
- construction state,
- parent-road dependencies,
- optional terminal connection roads.

Semantic IDs remain stable even when a crossing occurs in the middle of the road.

### Compiled graph

After planning, every road crossing is compiled into a true graph.

The compiler:

1. finds all segment intersections,
2. inserts breakpoints on both roads,
3. creates a shared junction node,
4. splits the semantic road into graph edges,
5. retains the semantic `roadId` on every graph edge.

The persistent city therefore stores:

```text
state.city.nodes
state.city.graphEdges
state.city.junctions
state.city.roads
```

This avoids changing gameplay-facing road IDs while still giving future routing a proper graph.

## Snapping

A new road must start on an allowed parent road.

The topology layer finds the nearest projection onto that road and snaps the candidate start to it.

Current planning constants include approximately:

- node snap radius: 28 m,
- road snap radius: 32 m,
- minimum junction spacing: 68 m.

A road that cannot attach to its declared parent is rejected.

## Intersections

Perpendicular or reasonably angled crossings can become real junctions.

Very acute intersections are rejected because they produce unrealistic slivers and ambiguous corridors.

The current minimum intersection angle is about 32 degrees.

When a candidate reaches another existing road:

- the candidate can be trimmed to the first valid intersection,
- the end becomes a terminal connection,
- the graph compiler later inserts the junction into both roads.

## Parent road versus terminal connection

These are intentionally different concepts.

`parentRoadIds` describe construction ancestry.

The road must start from those already built roads.

`connectionRoadIds` describe roads reached at the far end.

A terminal connection does not automatically become a construction prerequisite.

This prevents a district from waiting for an unrelated future district only because the planned streets happen to connect later.

## Corridor collision

Road width is part of topology validation.

Approximate collision half-widths are currently:

- arterial: 21 m,
- collector: 15 m,
- local: 12 m,
- service: 10 m.

Two nearly parallel roads are rejected when the distance between their corridors is below the required clearance.

This prevents:

- duplicate streets,
- two streets occupying the same carriageway,
- almost-overlapping roads separated by only a few metres.

Roads that share an endpoint are not automatically exempt.

The validator distinguishes:

- natural continuation in opposite directions — allowed,
- two roads leaving the same node in the same direction — rejected.

## Road hierarchy

New district infrastructure follows:

```text
ARTERIAL
   ↓
COLLECTOR
   ↓
LOCAL CROSS STREET
   ↓
LOCAL SIDE / LOOP CONNECTION
```

### Arterial

Carries the main transport corridor and links districts.

### Collector

Leaves the arterial and forms the primary access into a district.

### Local

Forms the frontage and blocks used by normal development.

The hierarchy is persisted as road dependencies and also controls construction order.

## Construction invariant

A road project cannot start before every road in its `parentRoadIds` is built.

The renderer follows the same invariant.

A planned child street is not shown until its parent infrastructure exists.

Road construction therefore grows continuously from the connected network rather than materializing in a field.

## Parcel relationship

Every parcel stores a real `frontageRoadId`.

A building cannot begin construction until that exact frontage road is built.

Parcels are also rejected near compiled junctions so buildings do not crowd intersections.

## Protected corridors and sites

Road candidates are checked against persistent master-plan reservations.

The same topology layer can therefore protect:

- Bus Depot,
- parks,
- future tram depot,
- rail yards,
- stations,
- maintenance compounds,
- civic sites.

## Rendering

The renderer distinguishes:

- arterial,
- collector,
- local,
- service roads.

Built multi-road junctions receive a shared pavement node after individual road strokes are drawn.

This hides stroke seams and makes T-junctions / crossroads read as one continuous street surface.

## Future use

The compiled graph is intended to become the common infrastructure graph for:

- ambient and simulated car routing,
- congestion,
- traffic lights,
- bus travel time,
- bus lanes,
- tram tracks embedded in streets,
- road closures,
- construction detours,
- land accessibility calculations.

Future systems should route against `graphEdges` / `junctions`, not invent independent visual paths.
