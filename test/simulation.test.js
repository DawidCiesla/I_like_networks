import test from 'node:test';
import assert from 'node:assert/strict';

import {
  ECONOMY,
  STATION_UPGRADE,
  advanceSimulation,
  canBuildDepot,
  canUnlockLine2,
  canUnlockLine3,
  canUnlockLine4,
  createInitialState,
  getBottleneck,
  getGarageUsed,
  getLastFareEventValue,
  getLineCapacityPpm,
  getLineCycleMinutes,
  getLineDemandPpm,
  getLineHeadwayMinutes,
  getLineOnboardPassengers,
  getLineWaitingPassengers,
  getNextStopCost,
  getRouteLengthKm,
  getStationLevel,
  getStationServedLines,
  getStationUpgradeCost,
  getStationWaitingCapacity,
  getStopWaitingPassengers,
} from '../src/simulation/model.js';

import {
  addVehicle,
  buildDepot,
  buildLine2,
  buildLine3,
  buildLine4,
  buildNextStop,
  buyUpgrade,
  upgradeStation,
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

test('bus simulation uses the authored world-scale segment lengths', () => {
  const state =
    createInitialState();

  buildNextStop(
    state,
    'line1',
  );

  assert.ok(
    Math.abs(
      getRouteLengthKm(
        state,
        'line1',
      ) - 0.368,
    ) < 1e-9,
  );

  buildNextStop(
    state,
    'line1',
  );

  assert.ok(
    Math.abs(
      getRouteLengthKm(
        state,
        'line1',
      )
      - 1.042856688271599,
    ) < 1e-9,
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


function stabilizeLine(
  state,
  lineKey,
) {
  let guard = 0;

  while (
    getLineCapacityPpm(
      state,
      lineKey,
    )
    < getLineDemandPpm(
      state,
      lineKey,
    )
    && guard < 20
  ) {
    if (
      getGarageUsed(state)
      >= state.depot.garageSlots
    ) {
      assert.equal(
        buyUpgrade(
          state,
          'depot',
        ).ok,
        true,
      );
    }

    assert.equal(
      addVehicle(
        state,
        lineKey,
      ).ok,
      true,
    );

    guard += 1;
  }

  assert.ok(
    guard < 20,
    `${lineKey} failed to stabilize`,
  );
}

test('individual station upgrade affects only that physical station', () => {
  const state =
    createInitialState();

  state.money = 10_000;

  buildNextStop(
    state,
    'line1',
  );

  const demandBefore =
    getLineDemandPpm(
      state,
      'line1',
    );

  const cycleBefore =
    getLineCycleMinutes(
      state,
      'line1',
    );

  const capacityBefore =
    getStationWaitingCapacity(
      state,
      'market-square',
    );

  const cost =
    getStationUpgradeCost(
      state,
      'market-square',
    );

  assert.equal(
    upgradeStation(
      state,
      'market-square',
    ).ok,
    true,
  );

  assert.equal(
    state.money,
    10_000
      - ECONOMY.line1StopBaseCost
      - cost,
  );

  assert.equal(
    getStationLevel(
      state,
      'market-square',
    ),
    1,
  );

  assert.equal(
    getStationLevel(
      state,
      'old-town',
    ),
    0,
  );

  assert.ok(
    getStationWaitingCapacity(
      state,
      'market-square',
    )
    > capacityBefore,
  );

  assert.ok(
    getLineDemandPpm(
      state,
      'line1',
    )
    > demandBefore,
  );

  assert.ok(
    getLineCycleMinutes(
      state,
      'line1',
    )
    < cycleBefore,
  );
});

test('station upgrades stop at Hub level', () => {
  const state =
    createInitialState();

  state.money = 100_000;

  buildNextStop(
    state,
    'line1',
  );

  for (
    let level = 0;
    level
      < STATION_UPGRADE.maxLevel;
    level += 1
  ) {
    assert.equal(
      upgradeStation(
        state,
        'market-square',
      ).ok,
      true,
    );
  }

  assert.equal(
    getStationLevel(
      state,
      'market-square',
    ),
    STATION_UPGRADE.maxLevel,
  );

  assert.equal(
    upgradeStation(
      state,
      'market-square',
    ).reason,
    'upgrade-limit',
  );
});

test('Lines 3 and 4 unlock sequentially and share real interchanges', () => {
  const state =
    createInitialState();

  state.money = 1_000_000;

  while (
    state.line1.stopCount
    < ECONOMY.maxLine1Stops
  ) {
    buildNextStop(
      state,
      'line1',
    );
  }

  buildDepot(state);
  stabilizeLine(
    state,
    'line1',
  );

  if (
    getGarageUsed(state)
    >= state.depot.garageSlots
  ) {
    buyUpgrade(
      state,
      'depot',
    );
  }

  assert.equal(
    canUnlockLine2(state),
    true,
  );

  assert.equal(
    buildLine2(state).ok,
    true,
  );

  assert.equal(
    canUnlockLine3(state),
    false,
  );

  while (
    state.line2.stopCount
    < ECONOMY.maxLine2Stops
  ) {
    buildNextStop(
      state,
      'line2',
    );
  }

  stabilizeLine(
    state,
    'line2',
  );

  if (
    getGarageUsed(state)
    >= state.depot.garageSlots
  ) {
    buyUpgrade(
      state,
      'depot',
    );
  }

  assert.equal(
    canUnlockLine3(state),
    true,
  );

  assert.equal(
    buildLine3(state).ok,
    true,
  );

  assert.deepEqual(
    getStationServedLines(
      state,
      'university',
    ),
    [
      'line1',
      'line3',
    ],
  );

  while (
    state.line3.stopCount
    < ECONOMY.maxLine3Stops
  ) {
    buildNextStop(
      state,
      'line3',
    );
  }

  stabilizeLine(
    state,
    'line3',
  );

  if (
    getGarageUsed(state)
    >= state.depot.garageSlots
  ) {
    buyUpgrade(
      state,
      'depot',
    );
  }

  assert.equal(
    canUnlockLine4(state),
    true,
  );

  assert.equal(
    buildLine4(state).ok,
    true,
  );

  assert.deepEqual(
    getStationServedLines(
      state,
      'harbor',
    ),
    [
      'line2',
      'line4',
    ],
  );

  while (
    state.line4.stopCount
    < ECONOMY.maxLine4Stops
  ) {
    assert.equal(
      buildNextStop(
        state,
        'line4',
      ).ok,
      true,
    );
  }

  assert.deepEqual(
    getStationServedLines(
      state,
      'central',
    ),
    [
      'line1',
      'line4',
    ],
  );

  const universityLevel =
    getStationLevel(
      state,
      'university',
    );

  assert.equal(
    upgradeStation(
      state,
      'university',
    ).ok,
    true,
  );

  assert.equal(
    getStationLevel(
      state,
      'university',
    ),
    universityLevel + 1,
  );
});
