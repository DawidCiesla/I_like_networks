# Phase 2 — Switches and Bottlenecks

## Goal

Turn the Phase 1 flow visualizer into the first real optimization problem.

The player should be able to grow a LAN until demand exceeds one of the network capacities, observe the resulting queue directly on the map, identify the bottleneck and fix it.

## New mechanics

- installable Ethernet switch,
- up to four connected clients,
- aggregate client demand,
- switch fabric capacity,
- finite switch buffer,
- persistent queue simulation,
- queueing latency,
- packet drops when the buffer is full,
- explicit bottleneck detection,
- switch fabric upgrades,
- buffer upgrades,
- visual congestion states on the network map.

## Congestion model

Traffic enters the switch as an aggregate flow.

The effective arrival rate is limited by the switch fabric:

```text
arrival = min(total client demand, switch capacity)
```

The service rate is limited by the slower downstream component:

```text
service = min(uplink capacity, server capacity)
```

When arrival exceeds service, excess traffic accumulates in the switch buffer.

Once the buffer is full, additional traffic is dropped.

The queue also adds latency:

```text
queue delay ~= queued data / service rate
```

## Visual feedback

The map should communicate congestion without requiring the player to read the stats panel.

- blue uplink: normal,
- yellow uplink: significant queue,
- red uplink: packet drops,
- visible queue blocks near the switch,
- red dropped-packet particles when the buffer overflows.

## Intentionally deferred

Phase 2 still does **not** include:

- alternate routes,
- routers,
- dynamic routing,
- redundancy,
- failures,
- contracts or SLA,
- data centers,
- cybersecurity.

Those remain later phases.

## Phase gate

Before Phase 3, verify all of the following:

1. A player understands why adding clients increases total demand.
2. The first queue is visually obvious.
3. The player can identify whether the bottleneck is the switch, uplink or server.
4. Increasing the correct capacity drains the queue.
5. Increasing the wrong capacity does not magically solve every problem.
6. Packet drops occur only after the queue buffer is exhausted.
7. The switched network remains readable with four clients.
8. The Phase 1 save migrates into Phase 2 without losing money or purchased upgrades.

## Automated coverage

The simulation tests cover:

- Ethernet activation,
- switch dependency,
- adding clients,
- aggregate demand,
- queue growth,
- latency growth,
- packet drops,
- bottleneck identification,
- queue draining after a capacity fix,
- switch and buffer upgrade cost escalation,
- simulation speed multipliers.
