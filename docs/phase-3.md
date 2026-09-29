# Phase 3 — Routers and Multiple Networks

## Goal

Move from a single LAN optimization problem to a routed multi-network topology.

The player should understand that a switch connects devices inside one LAN, while a router connects different IP networks and forwards traffic toward destination networks.

## New mechanics

- installable router,
- routed core throughput limit,
- router buffer,
- automatic routing table,
- second client network: LAN B,
- second destination network: Server B,
- separate LAN A and LAN B uplinks,
- separate Server A and Server B destination capacities,
- traffic distribution across two server networks,
- per-destination route queues,
- router-core bottlenecks,
- downstream destination bottlenecks,
- Phase 2 save migration.

## Topology

After the router is installed, the topology becomes:

```text
LAN A ─┐                  ┌─ Server A network
       ├── Router ────────┤
LAN B ─┘                  └─ Server B network
```

LAN B and Server B are unlocked separately.

## Addressing

The phase uses readable fixed subnets:

```text
LAN A         10.0.1.0/24
LAN B         10.0.2.0/24
Server Net A  10.0.10.0/24
Server Net B  10.0.20.0/24
```

The player does not manually configure IP addresses yet.

## Routing

Routing is automatic in Phase 3.

The router learns/installs a direct route whenever a new network is built.

There are no alternative paths yet, so routing is intentionally deterministic.

The routing table is visible in the UI and shows:

- destination subnet,
- outgoing port / next hop,
- active destination traffic.

## Capacity model

Traffic from LAN A is limited by:

```text
LAN A demand
→ switch fabric
→ LAN A uplink
```

Traffic from LAN B is limited by:

```text
LAN B demand
→ LAN B uplink
```

Both flows then share:

```text
router core capacity
```

After routing, traffic is split between Server A and Server B destination networks.

Each destination has its own downstream queue and service capacity.

This allows one server network to be congested without automatically blocking the other one.

## Visual feedback

The map is reorganized when the router is installed.

- LAN A appears in the upper-left,
- LAN B appears in the lower-left,
- router is centered,
- Server A appears upper-right,
- Server B appears lower-right,
- LAN traffic uses distinct colors,
- each server route has its own traffic flow,
- router queue remains visible near the core,
- inactive future links are shown as ghost routes.

## Intentionally deferred

Phase 3 does not yet include:

- multiple alternative routes to the same destination,
- manual static route configuration,
- dynamic routing protocols,
- redundancy,
- failover,
- random link failures,
- SLA contracts,
- data centers,
- cybersecurity.

Those belong to later phases.

## Phase gate

Before Phase 4, verify:

1. The difference between switch and router is visually understandable.
2. Building LAN B visibly adds a new source network.
3. Building Server B visibly adds a new destination network.
4. The routing table changes when networks are unlocked.
5. Traffic reaches both destination networks.
6. A router-core bottleneck produces a router queue.
7. A Server A bottleneck can queue Server A traffic without blocking Server B.
8. Upgrading the correct component clears the corresponding bottleneck.
9. The full four-network topology remains readable at normal zoom.
10. Phase 2 saves migrate without losing existing money or upgrades.

## Automated coverage

The simulation tests cover:

- router prerequisites,
- initial routing table,
- LAN B route creation,
- branch-client demand,
- Server B destination routing,
- router-core congestion,
- independent destination bottlenecks,
- router upgrades,
- Phase 2 behavior before router installation.
