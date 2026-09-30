# Living City Diorama

## Goal

I Like Transit should not look like a transport diagram floating on an empty background.

The transport network should exist inside a city that visibly grows around it.

The intended visual hierarchy is:

```text
city blocks
→ streets
→ sidewalks / crossings
→ stops
→ route markings
→ buses
→ passengers
```

Transport is part of the city rather than the entire city.

## Bus streets

Bus routes run on ordinary streets.

The authored route geometry from `transportLayout.js` is reused as the street centerline.

The city layer adds:

- asphalt surface,
- street edges,
- sidewalks,
- road markings,
- pedestrian crossings.

The Bus Era renderer then adds only a narrow colored service marking and route-number markers.

This replaces the previous rail-like sleeper treatment.

## Progressive city growth

City density is tied to infrastructure milestones.

### Stage 0
One starting stop.

- small Old Town settlement,
- low-rise houses,
- sparse streets.

### Stage 1
Line 1 reaches Market Square.

- more houses,
- small shops,
- denser local streets.

### Stage 2
City Park opens.

- park space,
- trees,
- townhouses,
- Bus Depot district becomes meaningful.

### Stage 3
University opens.

- apartment blocks,
- campus-style buildings,
- denser cross streets.

### Stage 4
Central opens.

- denser mixed-use development,
- larger blocks,
- first clearly urban center.

### Stage 5
Line 2 opens toward Riverside.

- a second development corridor appears.

### Stage 6
Museum area opens.

- additional mixed-use blocks,
- more road traffic.

### Stage 7
Harbor opens.

- industrial buildings and warehouses,
- the Central district can contain taller buildings / towers.

## Buildings

Buildings are deterministic visual objects.

Current visual categories:

- detached house,
- townhouse,
- shop,
- apartment block,
- mid-rise block,
- tower,
- campus building,
- workshop,
- warehouse.

The city layer may replace low-density building profiles with denser profiles as the global city stage rises.

This creates the impression that the city is developing rather than merely revealing static scenery.

## Parks and trees

City Park receives a real green space and tree sprites.

Future phases can add:

- plazas,
- parking lots,
- sports grounds,
- riverbanks,
- pedestrian streets,
- industrial yards.

## Ambient traffic

Ordinary cars move along visible streets.

This traffic is currently visual only.

It deliberately does not affect bus travel time yet.

A later traffic phase can promote ambient traffic into real simulation:

```text
population growth
→ more cars
→ congestion
→ bus delay
→ bus lanes / tram / metro become valuable
```

## Tram foundation

The street layer is intentionally separated from bus rendering.

A future tram line should be able to reuse the same street and add:

- embedded rails,
- overhead wires,
- tram stops,
- tram vehicles.

The city does not need to be redrawn when tram technology unlocks.

## Architecture

```text
transportLayout.js
        ↓
cityRenderer.js
        ↓
transportRenderer.js
```

`transportLayout.js`
owns route/station coordinates.

`cityRenderer.js`
owns streets, buildings, parks and ambient traffic.

`transportRenderer.js`
owns stops, service markings, buses and passenger feedback.

Simulation code must remain independent from all screen coordinates.

## Current limitation

City growth is currently visual and milestone-driven.

Buildings do not yet:

- generate their own passenger demand,
- have residents or jobs,
- change land value,
- react to accessibility,
- pay taxes,
- create road congestion.

Those are natural later extensions once the visual city layer is established.
