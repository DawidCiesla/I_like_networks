# I Like Networks

A network-management incremental game prototype. You begin with a single client and server, then grow toward increasingly large and autonomous infrastructure.

## Current development status

**Phase 3 — Routers and Multiple Networks**

The current build expands the Phase 2 LAN into the first routed multi-network topology.

Implemented now:

- router installation after the first switched LAN,
- automatic routing table,
- LAN A and LAN B source networks,
- Server A and Server B destination networks,
- routed core capacity and router queue,
- per-destination downstream queues,
- independent server-network bottlenecks,
- branch-client expansion,
- router, branch-uplink and secondary-server upgrades,
- visible route table and per-destination throughput,
- Phase 2 congestion mechanics before router installation,
- versioned local save with Phase 1/2 migration,
- dependency-free simulation tests.

See [`docs/phase-3.md`](docs/phase-3.md) for the current phase gate.

## Run locally

Requires Node.js 20+.

```bash
npm run dev
```

Open:

```text
http://127.0.0.1:5173
```

No package installation is required for the current prototype.

## Tests

```bash
npm test
npm run check
```

## Architecture

The game is separated into independent layers:

```text
simulation state + rules
        ↓
     main loop
      ↙   ↘
 renderer   HUD
```

The visual packet animation is not the simulation itself. Traffic is represented as aggregate flows, which keeps later scaling to large networks possible without simulating every real packet as a separate logical object.
