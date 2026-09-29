# I Like Networks

A network-management incremental game prototype. You begin with a single client and server, then grow toward increasingly large and autonomous infrastructure.

## Current development status

**Phase 2 — Switches and Bottlenecks**

The current build adds the first optimization layer on top of the Phase 1 traffic loop.

Implemented now:

- client → switch → server topology,
- up to four clients,
- aggregate traffic demand,
- switch fabric capacity,
- finite queue buffer,
- queueing latency,
- packet drops after buffer saturation,
- bottleneck identification,
- upgrades for client demand, switch fabric, buffer, uplink and server,
- congestion visualization directly on the map,
- pause / 1× / 2× / 4× speed,
- pan + zoom,
- versioned local save with Phase 1 migration,
- dependency-free simulation tests.

See [`docs/phase-2.md`](docs/phase-2.md) for the current phase gate.

## Run locally

Requires Node.js 20+.

```bash
npm run dev
```

Open:

```text
http://127.0.0.1:5173
```

No package installation is required for Phase 1.

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
