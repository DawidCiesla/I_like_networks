# Phase 1 — First Network

## Goal

Validate the smallest playable loop before adding switches, queues, failures, contracts or advanced routing.

## Implemented vertical slice

- one client node generating network demand,
- one server node with finite capacity,
- a player-built Ethernet link,
- real-time aggregate throughput calculation,
- animated packet-flow visualization,
- income generated from successfully serviced traffic,
- three upgrade tracks: client demand, Ethernet capacity and server capacity,
- pause / 1× / 2× / 4× simulation controls,
- lightweight local save,
- pan and zoom camera,
- dependency-free Node test suite.

## Deliberately not included yet

The following belong to later phases and are intentionally absent:

- switches,
- queues,
- packet loss,
- congestion penalties,
- multiple routes,
- routing algorithms,
- contracts and SLA,
- failures,
- data centers,
- cybersecurity.

## Phase gate

Before Phase 2, verify:

1. A new player understands that demand flows from the client to the server.
2. Connecting Ethernet gives immediate visual and economic feedback.
3. Increasing client demand creates a visible reason to improve capacity.
4. The network can be read primarily from the map rather than only from the side panel.
5. The loop remains interesting for at least 10–20 minutes with only these mechanics.
