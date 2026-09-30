# Transport T1 — Fleet, Frequency and Travel Time

## Goal

Replace abstract line-capacity upgrades with an explicit public-transport service model.

A transport line should no longer have a manually upgraded throughput number. Its carrying capacity must emerge from:

- vehicle type,
- vehicle capacity,
- number of vehicles,
- route length,
- stop count,
- dwell time,
- turnaround time.

This phase establishes the operating model needed before adding tram, metro, rail and other transport modes.

## Core line model

Each line has:

- a transport mode,
- a fleet count,
- a stop count,
- a passenger demand rate,
- a route length derived from expansion.

For a bus line:

```text
one-way time =
driving time + dwell time at served points
```

```text
cycle time =
2 × one-way time + terminal turnaround
```

```text
headway =
cycle time / fleet size
```

```text
frequency =
60 / headway
```

```text
line capacity =
vehicle capacity / headway
```

Equivalent form:

```text
line capacity =
vehicle capacity × fleet size / cycle time
```

## Bus baseline

T1 uses the standard bus as the only active vehicle type.

Baseline operating characteristics:

- capacity: 40 passengers,
- cruising speed: 30 km/h,
- dwell time: 0.25 min per serviced point,
- turnaround time: 1 min,
- starter fleet: 2 buses,
- maximum prototype fleet: 8 buses.

These values are gameplay parameters and can be rebalanced later.

## Route expansion

Adding a stop does two things at once:

1. increases the passenger catchment and demand,
2. increases the effective route length and service cycle.

Therefore a new stop can make an otherwise healthy line overcrowded.

This is intentional.

The player should learn that network expansion and service capacity must be developed together.

## Fleet purchases

The Line Inspector now contains an explicit **Buy another bus** action.

Each purchased vehicle:

- increases fleet count by one,
- reduces headway,
- increases frequency,
- increases line passenger capacity,
- appears visually on the map.

Vehicle purchase cost escalates with fleet size.

The first line and Line 2 both include two starter buses as part of their construction cost.

## Visible vehicles

The number of buses rendered on a line corresponds to the actual fleet count in simulation state.

The renderer no longer estimates vehicle count from aggregate throughput.

This creates a direct visual connection:

```text
buy bus
→ bus appears
→ headway falls
→ capacity rises
→ passenger queue drains
```

## Passenger queues at source lines

T0 still simplified one important case: when a line was overloaded before Central Interchange, excess demand could be capped before reaching the queue model.

T1 fixes this.

Passenger demand enters a source waiting queue before being served by the line.

### Line 1

Passengers wait at Northside Terminal.

Service capacity is limited by the slower of:

- terminal platform throughput,
- Line 1 vehicle service capacity.

### Line 2

Passengers wait at the Riverside source corridor.

Service capacity is limited by Line 2 vehicle service capacity.

If a waiting area is exhausted, additional passengers abandon the trip.

## Waiting time

Average passenger waiting time now contains two components.

### Scheduled wait

For a regular service:

```text
average scheduled wait ≈ headway / 2
```

The network-level scheduled wait is demand-weighted across active lines.

### Congestion wait

Passengers already accumulated in queues add additional waiting time.

Thus adding a vehicle can improve passenger experience even before a visible queue becomes severe.

## Service board

Central Interchange exposes a service board with:

- destination,
- line number and mode,
- current headway.

This is the first step toward later timetable and transfer mechanics.

## Balance intent

A fresh Line 1 begins healthy.

Adding another stop increases demand and cycle time enough that the player is encouraged to add another bus.

This creates the intended loop:

```text
build service
→ earn fare revenue
→ expand catchment
→ service becomes strained
→ buy vehicle
→ restore frequency
→ expand again
```

## Transport mode foundation

The domain catalog already includes provisional operating parameters for:

- bus,
- tram,
- metro,
- rail,
- ferry,
- air.

Only buses are unlocked in T1.

Future transport modes should reuse the same generic fleet/headway model while adding mode-specific infrastructure and operating constraints.

## Save migration

Game-state version is incremented to version 5.

T0 saves are migrated by converting the former abstract line capacity into an approximate fleet size, capped to the T1 prototype fleet limit.

Older network-prototype saves remain supported through the existing compatibility adapter.

The current canonical save key is:

```text
i-like-transit.save
```

Legacy keys are still read for migration.

## T1 validation gate

Before moving to T2, verify:

1. A fresh Line 1 starts with exactly two visible buses.
2. Line capacity is derived from the fleet model rather than stored directly.
3. Adding a bus visibly adds one vehicle.
4. Adding a bus reduces headway.
5. Adding a bus increases passenger capacity.
6. Adding a stop increases route time.
7. Adding a stop can create a real line bottleneck.
8. An overloaded Line 1 accumulates passengers at Northside.
9. An overloaded Line 2 accumulates passengers at Riverside.
10. Adding enough vehicles drains a line queue.
11. Average scheduled wait falls as frequency improves.
12. The service board shows live headway.
13. T0 saves migrate without crashing.
14. Existing map geometry remains additive and stable.

## Deferred to later phases

T1 does not yet include:

- different bus models,
- operating costs,
- driver/staff costs,
- manual timetables,
- bunching,
- road congestion,
- passenger route choice,
- passenger-specific destinations,
- transfer penalties,
- tram infrastructure,
- metro infrastructure,
- rail infrastructure.

Those should be layered onto this fleet/service foundation in subsequent phases.
