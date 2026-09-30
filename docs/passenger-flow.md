# Passenger Flow and Fare Economy

## Goal

The game must not behave like a passive clicker where every owned stop produces money per second.

Revenue must be a consequence of actual passenger transport.

The core causal chain is:

```text
passenger appears at an origin stop
→ waits for the correct direction
→ bus arrives
→ passenger boards
→ passenger travels inside that physical bus
→ bus reaches the destination
→ passenger alights
→ fare revenue is credited
```

If no passenger completes a trip, no fare revenue is generated.

## Passenger generation

Every active stop generates passenger demand.

Generated passengers receive a destination among the other currently built stops on that line.

Demand is stored as an origin-destination matrix:

```text
waitingByStop[origin][destination]
```

This means a passenger waiting at Old Town for Central is distinct from a passenger waiting at Old Town for Market Square.

The simulation remains aggregate rather than instantiating thousands of individual passenger objects.

## Waiting

Passengers remain at their origin stop until a bus travelling in the correct direction has room for them.

Each stop has finite waiting capacity.

If the waiting area fills, excess passengers abandon their trip.

Waiting passengers are rendered directly beside their stop.

## Physical buses

Every purchased bus exists as a simulated vehicle.

A vehicle stores:

- its current stop,
- its next stop,
- direction,
- whether it is dwelling or travelling,
- progress through the current segment,
- passenger load by destination.

The rendered bus position comes from this simulation state. The renderer no longer moves decorative buses independently of gameplay.

## Boarding

At the end of a stop dwell, the bus boards passengers whose destination lies ahead in its current direction.

Boarding is limited by vehicle capacity.

A boarding event is emitted and visualized on the map.

No money is earned when passengers board.

## Alighting

When the bus reaches a stop:

1. passengers whose destination is that stop leave the bus,
2. their trip is marked complete,
3. fare revenue is added to the player's balance,
4. lifetime transported-passenger statistics increase,
5. an alighting event is emitted,
6. a visible fare popup appears at that stop.

The fare formula is currently:

```text
arrival revenue =
passengers alighting × fare per passenger
```

The current base fare is $12 per completed passenger trip.

## No passive fare tick

Money is not calculated from:

```text
pax/min × fare × frame time
```

The balance therefore remains unchanged while:

- passengers are merely waiting,
- passengers are boarding,
- a bus is travelling between stops.

The balance changes only at a completed arrival event.

## UI

The top resource display shows the **last arrival fare**, not an estimated passive income-per-second value.

Line inspectors expose:

- fleet,
- passengers currently onboard,
- passengers waiting,
- headway,
- one-way travel time,
- theoretical service capacity,
- passenger demand,
- recent completed arrivals,
- average wait.

## Visual feedback

The map communicates the passenger cycle directly:

- small people appear beside stops,
- buses display their onboard load,
- boarding passengers move toward the vehicle/stop center,
- alighting passengers move away,
- completed arrivals create a one-time green `+$...` popup.

This feedback is intentionally spatial. The player should understand why money increased by watching the route.

## Simulation speed

Transport time is accelerated relative to wall-clock time.

At 1× speed:

```text
1 real second = 0.25 game minutes
```

This keeps physical trips visible while avoiding multi-minute real-world waits for the first fare.

The existing 2× and 4× controls multiply this simulation rate.

## Capacity

Theoretical line capacity remains useful for planning.

Because buses serve both directions, the estimate is:

```text
capacity ≈
vehicle capacity × fleet size × 2 / full cycle time
```

Actual delivered passengers still depend on:

- where passengers are waiting,
- their destinations,
- vehicle direction,
- free seats,
- actual bus arrivals.

## Persistence

Passenger queues, onboard loads and bus positions are persisted.

Short-lived visual events are cleared when a save is loaded so old BOARD / EXIT animations are not replayed after refreshing the page.

## Validation rules

The following must remain true:

1. A fresh game produces no money.
2. Building a service does not immediately produce passive revenue.
3. Passengers become visible at stops.
4. A bus can contain a non-zero passenger load.
5. Money does not change while the bus is between stops.
6. Money changes when passengers alight.
7. The fare change equals the number of alighting passengers times the fare.
8. Buying another bus creates another physical simulated vehicle.
9. Vehicle count in simulation and renderer stays synchronized.
10. Reset still returns to a clean one-stop state.
