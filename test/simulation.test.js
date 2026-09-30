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
  getLastFareEventValue,
  getLineCapacityPpm,
  getLineDemandPpm,
  getLineHeadwayMinutes,
  getLineOnboardPassengers,
  getLineWaitingPassengers,
  getNextStopCost,
  getStopWaitingPassengers,
} from '../src/simulation/model.js';

import {
  addVehicle,
  buildDepot,
  buildLine2,
  buildNextStop,
  buyUpgrade,
} from '../src/simulation/actions.js';

function advanceFor(state, realSeconds, step = 0.1) {
  const iterations = Math.ceil(realSeconds / step);

  for (let index = 0; index < iterations; index += 1) {
    advanceSimulation(state, step);
  }
}

test('fresh game starts with one stop and no passive income', () => {
  const state = createInitialState();

  assert.equal(state.line1.stopCount, 1);
  assert.equal(state.line1.built, false);
  assert.equal(state.line1.fleetCount, 0);
  assert.equal(state.money, ECONOMY.startingMoney);
  assert.equal(getLastFareEventValue(state), 0);
  assert.equal(getNextStopCost(state, 'line1'), 40);

  advanceFor(state, 10);

  assert.equal(state.money, ECONOMY.startingMoney);
});

test('buying the second stop creates one physical starter bus', () => {
  const state = createInitialState();

  assert.equal(
    buildNextStop(state, 'line1').ok,
    true,
  );

  assert.equal(state.line1.stopCount, 2);
  assert.equal(state.line1.built, true);
  assert.equal(state.line1.fleetCount, 1);
  assert.equal(state.line1.vehicles.length, 1);
  assert.equal(state.line1.vehicles[0].phase, 'dwell');
});

test('passengers accumulate at stops before the bus carries them', () => {
  const state = createInitialState();
  buildNextStop(state, 'line1');

  advanceFor(state, 1.5);

  assert.ok(
    getStopWaitingPassengers(
      state,
      'line1',
      0,
    ) > 0,
  );

  assert.ok(
    getStopWaitingPassengers(
      state,
      'line1',
      1,
    ) > 0,
  );

  assert.equal(state.stats.lifetimePassengers, 0);
});

test('money does not increase while passengers are only waiting or travelling', () => {
  const state = createInitialState();
  buildNextStop(state, 'line1');

  const afterPurchase = state.money;

  advanceFor(state, 8);

  assert.equal(state.money, afterPurchase);
  assert.equal(state.stats.lifetimeRevenue, 0);
});

test('fare revenue is credited only when passengers alight at a destination', () => {
  const state = createInitialState();
  buildNextStop(state, 'line1');

  const afterPurchase = state.money;

  advanceFor(state, 12);

  assert.ok(state.money > afterPurchase);
  assert.ok(state.stats.lifetimePassengers > 0);
  assert.ok(state.stats.lifetimeRevenue > 0);
  assert.ok(getLastFareEventValue(state) > 0);

  const moneyAfterArrival = state.money;

  advanceFor(state, 0.5);

  assert.equal(state.money, moneyAfterArrival);
});

test('bus actually carries passengers between stations', () => {
  const state = createInitialState();
  buildNextStop(state, 'line1');

  advanceFor(state, 4);

  assert.equal(
    state.line1.vehicles[0].phase,
    'travel',
  );

  assert.ok(
    getLineOnboardPassengers(
      state,
      'line1',
    ) > 0,
  );
});

test('boarding and alighting are emitted as explicit passenger events', () => {
  const state = createInitialState();
  buildNextStop(state, 'line1');

  advanceFor(state, 4);

  assert.ok(
    state.line1.passengerEvents.some(
      (event) => event.type === 'board',
    ),
  );

  advanceFor(state, 8);

  assert.ok(
    state.line1.passengerEvents.some(
      (event) =>
        event.type === 'alight'
        && event.fare > 0,
    ),
  );
});

test('the third stop creates a natural single-bus capacity problem', () => {
  const state = createInitialState();
  state.money = 10_000;

  buildNextStop(state, 'line1');
  buildNextStop(state, 'line1');

  assert.equal(state.line1.stopCount, 3);
  assert.equal(getBottleneck(state), 'line-1');

  advanceFor(state, 30);

  assert.ok(
    getLineWaitingPassengers(
      state,
      'line1',
    ) > 0,
  );

  assert.equal(canBuildDepot(state), true);
});

test('building the depot and buying a second bus improves headway', () => {
  const state = createInitialState();
  state.money = 10_000;

  buildNextStop(state, 'line1');
  buildNextStop(state, 'line1');

  assert.equal(
    addVehicle(state, 'line1').reason,
    'depot-required',
  );

  assert.equal(buildDepot(state).ok, true);

  const before =
    getLineHeadwayMinutes(
      state,
      'line1',
    );

  assert.equal(
    addVehicle(state, 'line1').ok,
    true,
  );

  assert.equal(state.line1.vehicles.length, 2);

  assert.ok(
    getLineHeadwayMinutes(
      state,
      'line1',
    ) < before,
  );

  assert.equal(getBottleneck(state), 'none');
});

test('garage capacity limits physical vehicles across all lines', () => {
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

  const beforeSlots =
    state.depot.garageSlots;

  assert.equal(
    buyUpgrade(state, 'depot').ok,
    true,
  );

  assert.ok(
    state.depot.garageSlots
    > beforeSlots,
  );
});

test('Line 2 requires a complete stable Line 1 and a free garage slot', () => {
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
    if (
      getGarageUsed(state)
      >= state.depot.garageSlots
    ) {
      buyUpgrade(state, 'depot');
    }

    addVehicle(state, 'line1');
  }

  if (
    getGarageUsed(state)
    >= state.depot.garageSlots
  ) {
    assert.equal(
      canUnlockLine2(state),
      false,
    );

    buyUpgrade(state, 'depot');
  }

  assert.equal(canUnlockLine2(state), true);
  assert.equal(buildLine2(state).ok, true);
  assert.equal(state.line2.vehicles.length, 1);
});
