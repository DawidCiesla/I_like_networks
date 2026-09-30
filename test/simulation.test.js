import test from 'node:test';
import assert from 'node:assert/strict';

import {
  ECONOMY,
  advanceSimulation,
  canBuildDepot,
  canUnlockLine2,
  createInitialState,
  getBottleneck,
  getGarageUsed,
  getIncomePerSecond,
  getLineCapacityPpm,
  getLineDemandPpm,
  getLineHeadwayMinutes,
  getNextStopCost,
} from '../src/simulation/model.js';

import {
  addVehicle,
  buildDepot,
  buildLine2,
  buildNextStop,
  buyUpgrade,
} from '../src/simulation/actions.js';

test('fresh game starts with one owned stop and no active service', () => {
  const state = createInitialState();

  assert.equal(state.line1.stopCount, 1);
  assert.equal(state.line1.built, false);
  assert.equal(state.line1.fleetCount, 0);
  assert.equal(getIncomePerSecond(state), 0);
  assert.equal(getNextStopCost(state, 'line1'), 40);
});

test('buying the second stop starts Line 1 with one starter bus', () => {
  const state = createInitialState();

  assert.equal(
    buildNextStop(state, 'line1').ok,
    true,
  );

  assert.equal(state.line1.stopCount, 2);
  assert.equal(state.line1.built, true);
  assert.equal(state.line1.fleetCount, 1);
  assert.ok(getLineCapacityPpm(state, 'line1') > 0);
  assert.ok(getLineDemandPpm(state, 'line1') > 0);
});

test('Line 1 earns fare revenue after the first segment opens', () => {
  const state = createInitialState();
  buildNextStop(state, 'line1');

  const before = state.money;

  for (let index = 0; index < 20; index += 1) {
    advanceSimulation(state, 0.25);
  }

  assert.ok(state.money > before);
  assert.ok(state.stats.lifetimePassengers > 0);
});

test('each purchased stop extends the line and raises the next stop cost', () => {
  const state = createInitialState();
  state.money = 10_000;

  const first = getNextStopCost(state, 'line1');
  buildNextStop(state, 'line1');

  const second = getNextStopCost(state, 'line1');
  buildNextStop(state, 'line1');

  assert.equal(state.line1.stopCount, 3);
  assert.ok(second > first);
  assert.equal(canBuildDepot(state), true);
});

test('the third stop creates the first natural fleet bottleneck', () => {
  const state = createInitialState();
  state.money = 10_000;

  buildNextStop(state, 'line1');
  buildNextStop(state, 'line1');

  assert.equal(state.line1.stopCount, 3);
  assert.equal(getBottleneck(state), 'line-1');

  for (let index = 0; index < 240; index += 1) {
    advanceSimulation(state, 0.25);
  }

  assert.ok(state.line1.queuePassengers > 0);
});

test('additional buses cannot be purchased before the depot exists', () => {
  const state = createInitialState();
  state.money = 10_000;

  buildNextStop(state, 'line1');
  buildNextStop(state, 'line1');

  assert.equal(
    addVehicle(state, 'line1').reason,
    'depot-required',
  );
});

test('building the depot unlocks bus purchases that reduce headway', () => {
  const state = createInitialState();
  state.money = 10_000;

  buildNextStop(state, 'line1');
  buildNextStop(state, 'line1');
  buildDepot(state);

  const before =
    getLineHeadwayMinutes(state, 'line1');

  assert.equal(
    addVehicle(state, 'line1').ok,
    true,
  );

  assert.equal(state.line1.fleetCount, 2);

  assert.ok(
    getLineHeadwayMinutes(state, 'line1')
      < before,
  );

  assert.equal(getBottleneck(state), 'none');
});

test('garage slots limit the total fleet across all lines', () => {
  const state = createInitialState();
  state.money = 100_000;

  buildNextStop(state, 'line1');
  buildNextStop(state, 'line1');
  buildDepot(state);

  while (
    getGarageUsed(state)
    < state.depot.garageSlots
  ) {
    addVehicle(state, 'line1');
  }

  assert.equal(
    addVehicle(state, 'line1').reason,
    'garage-full',
  );

  const beforeSlots = state.depot.garageSlots;

  assert.equal(
    buyUpgrade(state, 'depot').ok,
    true,
  );

  assert.ok(
    state.depot.garageSlots > beforeSlots,
  );
});

test('Line 2 unlocks only after Line 1 reaches its full route and is stable', () => {
  const state = createInitialState();
  state.money = 100_000;

  while (
    state.line1.stopCount
    < ECONOMY.maxLine1Stops
  ) {
    buildNextStop(state, 'line1');
  }

  assert.equal(canUnlockLine2(state), false);

  buildDepot(state);

  while (
    getLineCapacityPpm(state, 'line1')
    < getLineDemandPpm(state, 'line1')
  ) {
    addVehicle(state, 'line1');
  }

  assert.equal(canUnlockLine2(state), true);
});

test('opening Line 2 creates a new branch with one starter bus', () => {
  const state = createInitialState();
  state.money = 100_000;

  while (
    state.line1.stopCount
    < ECONOMY.maxLine1Stops
  ) {
    buildNextStop(state, 'line1');
  }

  buildDepot(state);

  while (
    getLineCapacityPpm(state, 'line1')
    < getLineDemandPpm(state, 'line1')
  ) {
    addVehicle(state, 'line1');
  }

  assert.equal(buildLine2(state).ok, true);
  assert.equal(state.line2.built, true);
  assert.equal(state.line2.stopCount, 2);
  assert.equal(state.line2.fleetCount, 1);
});

test('Line 2 can also be extended stop by stop from the map progression', () => {
  const state = createInitialState();
  state.money = 100_000;

  while (
    state.line1.stopCount
    < ECONOMY.maxLine1Stops
  ) {
    buildNextStop(state, 'line1');
  }

  buildDepot(state);

  while (
    getLineCapacityPpm(state, 'line1')
    < getLineDemandPpm(state, 'line1')
  ) {
    addVehicle(state, 'line1');
  }

  buildLine2(state);

  const before =
    state.line2.stopCount;

  assert.equal(
    buildNextStop(state, 'line2').ok,
    true,
  );

  assert.equal(
    state.line2.stopCount,
    before + 1,
  );
});
