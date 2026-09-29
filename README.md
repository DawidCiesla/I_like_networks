# I Like Networks

A network-management incremental game prototype. You begin with a single client and server, then grow toward increasingly large and autonomous infrastructure.

## Current development status

**Phase 1 — First Network**

The current build is intentionally small and exists to validate the core loop before adding switches, congestion, routing, contracts and failures.

Implemented now:

- client → Ethernet → server flow,
- live aggregate throughput,
- animated packet visualization,
- money earned from serviced traffic,
- upgrades for traffic generation, link capacity and server capacity,
- pause / 1× / 2× / 4× speed,
- pan + zoom,
- local browser save,
- dependency-free simulation tests.

See [`docs/phase-1.md`](docs/phase-1.md) for the phase gate and intentionally deferred mechanics.

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
