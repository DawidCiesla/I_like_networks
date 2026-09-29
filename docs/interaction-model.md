# Interaction Model — Additive Map and Contextual Upgrades

## Problem

A single global control panel does not scale with the game.

As more devices, networks and upgrades are unlocked, a global list grows until it obscures the map. It also makes the network feel like a menu-driven game instead of a spatial system.

The map must also remain spatially stable. Buying a router or another network must not reorganize previously built infrastructure.

## Rules

### 1. Existing infrastructure never moves because of an unlock

Nodes receive stable world coordinates.

A new device is inserted into or attached to the existing topology without relocating old devices.

Example:

```text
Before router:

LAN A ---- [future router position] ---- Server A

After router:

LAN A ----------- ROUTER --------------- Server A
```

The line geometry remains the same.

### 2. Expansion is additive

New networks create new branches.

```text
                         Server A
                            /
LAN A ---- Switch ---- Router
                            \
                             Server B
                   /
              LAN B
```

LAN B and Server B are added without rebuilding LAN A or Server A.

### 3. BUILD only contains new infrastructure

The BUILD menu lists only infrastructure that has not yet been created.

Once an item is built, it disappears from BUILD.

Examples:

- Ethernet
- Switch
- Router
- LAN B
- Server B

Client expansion and upgrades do not belong in the global BUILD list.

### 4. Upgrades are contextual

Clicking a map element opens its Inspector.

Examples:

#### LAN A
- add client,
- Client NIC,
- LAN A uplink.

#### Switch
- switch fabric,
- switch buffer while that buffer is part of the active simulation.

#### Router
- router core,
- routing table,
- router diagnostics.

#### Server A
- Server A capacity.

#### LAN B
- add client,
- LAN B uplink.

#### Server B
- Server B capacity.

Only relevant controls are shown.

### 5. The map is the primary interface

The player should first identify the element spatially and then click it.

The Inspector supplements the map instead of replacing it.

### 6. Selection is persistent but lightweight

The selected device receives a small dashed outline.

Closing the Inspector removes that selection.

### 7. Future phases must follow the same model

Contracts, failures, data centers and later systems should not reintroduce one giant global upgrade menu.

New functionality should be attached to:

- a selected map object,
- a compact dedicated overlay,
- or the BUILD menu when it represents genuinely new infrastructure.
