import test from 'node:test';
import assert from 'node:assert/strict';

import {
  advanceSimulation,
  createInitialState,
  getAbandonmentPercent,
  getAddStopBCost,
  getBottleneck,
  getCorridorBDemandPpm,
  getDeliveredPassengersPpm,
  getInterchangeIngressPpm,
  getServiceBoard,
} from '../src/simulation/model.js';

import {
  addStopB,
  buildCorridorB,
  buildFirstLine,
  buildInterchange,
  buildStationB,
  buildTerminalA,
  buyUpgrade,
} from '../src/simulation/actions.js';

function fundedState() {
  const state = createInitialState();
  state.money = 10_000;
  buildFirstLine(state);
  buildTerminalA(state);
  return state;
}

test('no passenger service runs before Line 1 is built', () => {
  const state = createInitialState();

  assert.equal(getDeliveredPassengersPpm(state), 0);
});

test('starting Line 1 begins passenger transport and earns fare revenue', () => {
  const state = createInitialState();

  assert.equal(buildFirstLine(state).ok, true);
  assert.equal(getDeliveredPassengersPpm(state), 10);

  const before = state.money;

  advanceSimulation(state, 0.25);

  assert.ok(state.money > before);
  assert.ok(state.stats.lifetimePassengers > 0);
});

test('Northside Terminal requires Line 1', () => {
  const state = createInitialState();

  assert.equal(
    buildTerminalA(state).reason,
    'line-required',
  );

  state.money = 10_000;
  buildFirstLine(state);

  assert.equal(buildTerminalA(state).ok, true);
  assert.equal(state.terminalA.built, true);
});

test('Central Interchange requires the terminal', () => {
  const state = createInitialState();
  state.money = 10_000;

  buildFirstLine(state);

  assert.equal(
    buildInterchange(state).reason,
    'terminal-required',
  );

  buildTerminalA(state);

  assert.equal(buildInterchange(state).ok, true);
});

test('Line 2 adds a second source corridor and service-board entry', () => {
  const state = fundedState();

  buildInterchange(state);
  buildCorridorB(state);

  assert.equal(state.corridorB.built, true);
  assert.ok(getCorridorBDemandPpm(state) > 0);

  assert.ok(
    getServiceBoard(state).some(
      (service) => service.destination === 'Riverside',
    ),
  );
});

test('adding a Line 2 stop increases passenger demand', () => {
  const state = fundedState();

  buildInterchange(state);
  buildCorridorB(state);

  const beforeDemand = getCorridorBDemandPpm(state);
  const beforeCost = getAddStopBCost(state);

  assert.equal(addStopB(state).ok, true);
  assert.ok(getCorridorBDemandPpm(state) > beforeDemand);
  assert.ok(getAddStopBCost(state) > beforeCost);
});

test('Harbor Station creates a second delivered passenger stream', () => {
  const state = fundedState();

  buildInterchange(state);
  buildCorridorB(state);
  buildStationB(state);

  for (let index = 0; index < 20; index += 1) {
    advanceSimulation(state, 0.25);
  }

  assert.ok(state.interchange.lastDeliveredPpm.primary > 0);
  assert.ok(state.interchange.lastDeliveredPpm.secondary > 0);

  assert.ok(
    getServiceBoard(state).some(
      (service) => service.destination === 'Harbor Station',
    ),
  );
});

test('interchange becomes a bottleneck when combined passenger flow is too high', () => {
  const state = fundedState();

  buildInterchange(state);
  buildCorridorB(state);

  state.corridorA.stopCount = 4;
  state.corridorA.demandPerStopPpm = 25;
  state.corridorA.lineCapacityPpm = 200;
  state.terminalA.platformCapacityPpm = 200;

  state.corridorB.stopCount = 4;
  state.corridorB.demandPerStopPpm = 20;
  state.corridorB.lineCapacityPpm = 200;

  state.interchange.transferCapacityPpm = 40;

  assert.equal(getBottleneck(state), 'interchange');
  assert.ok(getInterchangeIngressPpm(state) > 40);

  for (let index = 0; index < 30; index += 1) {
    advanceSimulation(state, 0.25);
  }

  assert.ok(state.interchange.queuePassengers > 0);
});

test('Central Station can bottleneck without blocking Harbor Station queue', () => {
  const state = fundedState();

  buildInterchange(state);
  buildCorridorB(state);
  buildStationB(state);

  state.corridorA.stopCount = 4;
  state.corridorA.demandPerStopPpm = 20;
  state.corridorA.lineCapacityPpm = 200;
  state.terminalA.platformCapacityPpm = 200;

  state.corridorB.lineCapacityPpm = 200;
  state.interchange.transferCapacityPpm = 200;

  state.stationA.capacityPpm = 20;
  state.stationB.capacityPpm = 200;

  assert.equal(getBottleneck(state), 'station-a');

  for (let index = 0; index < 40; index += 1) {
    advanceSimulation(state, 0.25);
  }

  assert.ok(
    state.interchange.destinationQueuesPassengers.primary > 0,
  );

  assert.equal(
    state.interchange.destinationQueuesPassengers.secondary,
    0,
  );
});

test('passengers leave the queue after waiting capacity is exhausted', () => {
  const state = fundedState();

  buildInterchange(state);
  buildCorridorB(state);

  state.corridorA.stopCount = 4;
  state.corridorA.demandPerStopPpm = 30;
  state.corridorA.lineCapacityPpm = 300;
  state.terminalA.platformCapacityPpm = 300;

  state.corridorB.stopCount = 4;
  state.corridorB.demandPerStopPpm = 30;
  state.corridorB.lineCapacityPpm = 300;

  state.interchange.transferCapacityPpm = 10;
  state.interchange.waitingCapacityPassengers = 1;

  for (let index = 0; index < 60; index += 1) {
    advanceSimulation(state, 0.25);
  }

  assert.ok(state.interchange.totalAbandonedPassengers > 0);
  assert.ok(getAbandonmentPercent(state) > 0);
});

test('adding buses increases Line 1 capacity', () => {
  const state = fundedState();

  const before = state.corridorA.lineCapacityPpm;

  assert.equal(buyUpgrade(state, 'lineA').ok, true);
  assert.ok(state.corridorA.lineCapacityPpm > before);
});
