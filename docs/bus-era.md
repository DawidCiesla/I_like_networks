# Bus Era — Natural Early-Game Progression

## Goal

Create the first genuinely game-like phase of I Like Transit.

The player should not begin by opening a menu and buying an entire transport system. Progress should emerge spatially from the map.

The intended rhythm is:

```text
own one stop
→ notice a nearby future stop
→ buy it
→ line appears
→ earn money
→ extend line
→ capacity pressure appears
→ unlock depot
→ add buses
→ continue expanding
→ unlock a second line
```

## Fresh start

A fresh save contains:

- $100,
- one owned stop: Old Town,
- no active line,
- no buses,
- no depot,
- no Line 2.

A ghost version of Market Square is visible nearby.

The player must click that ghost stop and buy it.

## First service

Buying Market Square:

- spends the stop purchase cost,
- increases Line 1 to two stops,
- activates Bus Line 1,
- grants one starter bus,
- starts passenger demand and fare revenue.

The line is drawn only between the stops that actually exist.

## Stop-by-stop growth

Line 1 contains five possible stops:

1. Old Town,
2. Market Square,
3. City Park,
4. University,
5. Central.

Only the next unbuilt stop is shown as a purchase opportunity.

Each stop:

- costs more than the previous stop,
- adds one physical segment to the existing line,
- increases passenger demand,
- lengthens route distance,
- increases one-way and cycle time,
- can worsen service headway.

This creates the first core economic tension.

## Depot unlock

After City Park becomes the third stop, the Bus Depot appears as a ghost building beside the route.

The depot must be purchased separately.

Before the depot exists:

- the player cannot buy additional buses.

After the depot exists:

- buses can be purchased for active lines,
- vehicles are assigned directly to a line,
- garage capacity becomes a shared fleet limit.

The depot initially has four garage slots.

The garage can be expanded by upgrade.

## Fleet progression

The first segment of each newly created bus line includes one starter bus.

Every later bus must be purchased through the Bus Depot.

Buying a bus:

- adds one visible vehicle to the line,
- reduces headway,
- increases frequency,
- increases line passenger capacity.

The player should be able to see the causal chain directly on the map.

## Natural bottleneck

The current balance intentionally makes the third stop slightly too much for a single Line 1 bus.

The desired learning moment is:

```text
build City Park
→ waiting passengers begin to accumulate
→ Bus Depot becomes available
→ build depot
→ buy second bus
→ queue clears
```

The player learns fleet management because the map creates a problem, not because a tutorial menu tells them to upgrade throughput.

## Progressive upgrades

Line upgrades are contextual and unlock over time.

### Early

Once a service exists:

- Improve stops
  - increases waiting capacity.

### Later

After a line has grown further:

- Expand catchment
  - increases passenger demand around the route.

These upgrades stay inside the selected line Inspector.

## Line 2 unlock

Bus Line 2 is not available at the start.

It appears only when:

- Bus Depot exists,
- Line 1 has reached all five stops,
- Line 1 has enough fleet capacity to meet its current demand.

When those conditions are met, a yellow ghost branch appears at City Park.

Clicking it allows the player to purchase Line 2.

Line 2 begins with:

- two stops,
- one starter bus,
- its own passenger demand and queue.

It then grows stop-by-stop using the same interaction model.

## Map-first interaction

The map is the build interface.

Future infrastructure is represented by ghost objects:

- dashed future segment,
- ghost stop,
- ghost Bus Depot,
- ghost Line 2 branch.

Clicking a ghost object opens a small contextual Inspector with:

- what will be built,
- what it changes,
- its cost,
- the purchase action.

The old global BUILD panel is intentionally removed from the primary loop.

## Additive geometry

Unlocking new systems does not reorganize previous infrastructure.

Examples:

- buying City Park extends the existing Line 1;
- building Bus Depot adds a small spur beside City Park;
- opening Line 2 adds a branch;
- Old Town and Market Square never move because something later was unlocked.

## Bus Era validation gate

Before adding tram or another mode, verify:

1. Fresh reset visibly starts with exactly one owned stop.
2. The next ghost stop is obvious and clickable.
3. Buying the second stop starts Line 1.
4. One visible starter bus appears.
5. Fare revenue begins only after service starts.
6. Buying another stop extends only the end of the existing line.
7. Earlier stations remain in place.
8. The third stop creates a mild service bottleneck.
9. The Bus Depot visibly unlocks after the third stop.
10. Additional buses cannot be purchased before the depot exists.
11. Buying a bus in the depot visibly adds it to Line 1.
12. The added bus reduces headway and clears the queue.
13. Garage slots limit fleet growth.
14. Line upgrades appear progressively rather than all at once.
15. Line 2 does not appear until Line 1 is complete and stable.
16. Line 2 appears as a new branch rather than replacing Line 1.
17. Reset reliably returns to the one-stop state.

## Deferred

This phase intentionally does not introduce:

- tram,
- metro,
- rail,
- road congestion,
- operating costs,
- multiple bus models,
- manual timetables,
- route-choice AI,
- detailed passenger destinations.

Those should come only after this progression loop feels good to play.
