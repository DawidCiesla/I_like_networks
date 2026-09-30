import test from 'node:test';
import assert from 'node:assert/strict';

import {
  advanceSimulation,
  createInitialState,
  getAbandonmentPercent,
  getAverageWaitMinutes,
  getBottleneck,
  getCorridorADemandPpm,
  getDeliveredPassengersPpm,
  getLineCapacityPpm,
  getLineHeadwayMinutes,
  getLineOneWayMinutes,
  getServiceBoard,
  getVehiclePurchaseCost,
} from '../src/simulation/model.js';

import {
  addStopA,
  addStopB,
  addVehicle,
  buildCorridorB,
  buildFirstLine,
  buildInterchange,
  buildStationB,
  buildTerminalA,
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

test('Line 1 starts with a real two-bus fleet', () => {
  const state = createInitialState();
  state.money = 10_000;

  assert.equal(buildFirstLine(state).ok, true);
  assert.equal(state.corridorA.fleetCount, 2);
  assert.ok(getLineHeadwayMinutes(state, 'corridorA') > 0);
  assert.ok(getLineCapacityPpm(state, 'corridorA') > 4);

  const before = state.money;
  advanceSimulation(state, 0.25);

  assert.ok(state.money > before);
  assert.ok(state.stats.lifetimePassengers > 0);
});

test('adding a stop lengthens the trip and can create a line bottleneck', () => {
  const state = fundedState();

  const beforeTravel =
    getLineOneWayMinutes(state, 'corridorA');

  const beforeHeadway =
    getLineHeadwayMinutes(state, 'corridorA');

  const beforeDemand =
    getCorridorADemandPpm(state);

  assert.equal(addStopA(state).ok, true);

  assert.ok(
    getLineOneWayMinutes(state, 'corridorA')
      > beforeTravel,
  );

  assert.ok(
    getLineHeadwayMinutes(state, 'corridorA')
      > beforeHeadway,
  );

  assert.ok(
    getCorridorADemandPpm(state)
      > beforeDemand,
  );

  assert.equal(getBottleneck(state), 'line-a');
});

test('buying a bus shortens headway and increases capacity', () => {
  const state = fundedState();
  addStopA(state);

  const beforeHeadway =
    getLineHeadwayMinutes(state, 'corridorA');

  const beforeCapacity =
    getLineCapacityPpm(state, 'corridorA');

  assert.equal(
    addVehicle(state, 'corridorA').ok,
    true,
  );

  assert.equal(state.corridorA.fleetCount, 3);

  assert.ok(
    getLineHeadwayMinutes(state, 'corridorA')
      < beforeHeadway,
  );

  assert.ok(
    getLineCapacityPpm(state, 'corridorA')
      > beforeCapacity,
  );

  assert.equal(getBottleneck(state), 'none');
});

test('vehicle purchase cost escalates with fleet size', () => {
  const state = fundedState();

  const firstCost =
    getVehiclePurchaseCost(state, 'corridorA');

  assert.equal(
    addVehicle(state, 'corridorA').ok,
    true,
  );

  const secondCost =
    getVehiclePurchaseCost(state, 'corridorA');

  assert.ok(secondCost > firstCost);
});

test('scheduled passenger wait drops when another bus is added', () => {
  const state = fundedState();

  const before = getAverageWaitMinutes(state);

  addVehicle(state, 'corridorA');

  const after = getAverageWaitMinutes(state);

  assert.ok(after < before);
});

test('overloaded Line 1 stores passengers in its source queue', () => {
  const state = fundedState();
  buildInterchange(state);
  addStopA(state);

  assert.equal(getBottleneck(state), 'line-a');

  for (let index = 0; index < 240; index += 1) {
    advanceSimulation(state, 0.25);
  }

  assert.ok(state.terminalA.queuePassengers > 0);
});

test('adding enough buses drains an overloaded Line 1 queue', () => {
  const state = fundedState();
  buildInterchange(state);
  addStopA(state);

  for (let index = 0; index < 240; index += 1) {
    advanceSimulation(state, 0.25);
  }

  const queued = state.terminalA.queuePassengers;

  addVehicle(state, 'corridorA');
  addVehicle(state, 'corridorA');

  for (let index = 0; index < 240; index += 1) {
    advanceSimulation(state, 0.25);
  }

  assert.ok(state.terminalA.queuePassengers < queued);
});

test('Line 2 also derives capacity from fleet and route length', () => {
  const state = fundedState();
  buildInterchange(state);
  buildCorridorB(state);

  const baseHeadway =
    getLineHeadwayMinutes(state, 'corridorB');

  assert.equal(state.corridorB.fleetCount, 2);

  addStopB(state);

  assert.ok(
    getLineHeadwayMinutes(state, 'corridorB')
      > baseHeadway,
  );

  assert.equal(getBottleneck(state), 'line-b');

  addVehicle(state, 'corridorB');
  addVehicle(state, 'corridorB');

  assert.ok(
    getLineCapacityPpm(state, 'corridorB')
      > state.corridorB.demandPerStopPpm
        * state.corridorB.stopCount,
  );
});

test('service board exposes fleet headway', () => {
  const state = fundedState();
  buildInterchange(state);
  buildCorridorB(state);

  const services = getServiceBoard(state);

  assert.equal(services.length, 2);
  assert.ok(services[0].headwayMinutes > 0);
  assert.equal(services[0].fleetCount, 2);
  assert.equal(services[1].fleetCount, 2);
});

test('Harbor Station creates a second delivered passenger stream', () => {
  const state = fundedState();
  buildInterchange(state);
  buildCorridorB(state);
  buildStationB(state);

  for (let index = 0; index < 120; index += 1) {
    advanceSimulation(state, 0.25);
  }

  assert.ok(
    state.interchange.lastDeliveredPpm.primary > 0,
  );

  assert.ok(
    state.interchange.lastDeliveredPpm.secondary > 0,
  );
});

test('passengers abandon a source queue only after waiting space is exhausted', () => {
  const state = fundedState();
  buildInterchange(state);
  addStopA(state);

  state.terminalA.waitingCapacityPassengers = 0.2;

  for (let index = 0; index < 240; index += 1) {
    advanceSimulation(state, 0.25);
  }

  assert.ok(
    state.terminalA.totalAbandonedPassengers > 0,
  );

  assert.ok(getAbandonmentPercent(state) > 0);
});
