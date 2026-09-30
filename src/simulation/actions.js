import {
  ECONOMY,
  UPGRADES,
  canBuildDepot,
  canUnlockLine2,
  addVehicleToLineState,
  getGarageUsed,
  getNextStopCost,
  getUpgradeCost,
  getVehiclePurchaseCost,
  initializeLineService,
} from './model.js';

export function buildNextStop(state, lineKey) {
  const line =
    lineKey === 'line1'
      ? state.line1
      : lineKey === 'line2'
        ? state.line2
        : null;

  if (!line) {
    return { ok: false, reason: 'unknown-line' };
  }

  if (lineKey === 'line2' && !line.built) {
    return { ok: false, reason: 'line-required' };
  }

  const maxStops =
    lineKey === 'line1'
      ? ECONOMY.maxLine1Stops
      : ECONOMY.maxLine2Stops;

  if (line.stopCount >= maxStops) {
    return { ok: false, reason: 'stop-limit' };
  }

  const cost = getNextStopCost(
    state,
    lineKey,
  );

  if (state.money < cost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= cost;
  line.stopCount += 1;

  if (
    lineKey === 'line1'
    && !line.built
    && line.stopCount >= 2
  ) {
    initializeLineService(
      state,
      'line1',
      1,
    );
  }

  return { ok: true, cost };
}

export function buildDepot(state) {
  if (!canBuildDepot(state)) {
    return {
      ok: false,
      reason: state.depot.built
        ? 'already-built'
        : 'progress-required',
    };
  }

  if (state.money < ECONOMY.depotBuildCost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= ECONOMY.depotBuildCost;
  state.depot.built = true;

  return { ok: true };
}

export function buildLine2(state) {
  if (!canUnlockLine2(state)) {
    return { ok: false, reason: 'progress-required' };
  }

  if (state.money < ECONOMY.line2BuildCost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= ECONOMY.line2BuildCost;

  state.line2.stopCount = 2;

  initializeLineService(
    state,
    'line2',
    1,
  );

  return { ok: true };
}

export function addVehicle(state, lineKey) {
  const line =
    lineKey === 'line1'
      ? state.line1
      : lineKey === 'line2'
        ? state.line2
        : null;

  if (!line) {
    return { ok: false, reason: 'unknown-line' };
  }

  if (!state.depot.built) {
    return { ok: false, reason: 'depot-required' };
  }

  if (!line.built) {
    return { ok: false, reason: 'line-required' };
  }

  if (
    line.fleetCount
    >= ECONOMY.maxVehiclesPerLine
  ) {
    return { ok: false, reason: 'fleet-limit' };
  }

  if (
    getGarageUsed(state)
    >= state.depot.garageSlots
  ) {
    return { ok: false, reason: 'garage-full' };
  }

  const cost =
    getVehiclePurchaseCost(state);

  if (state.money < cost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= cost;

  addVehicleToLineState(
    state,
    lineKey,
  );

  return { ok: true, cost };
}

export function buyUpgrade(state, type) {
  const config = UPGRADES[type];

  if (!config) {
    return { ok: false, reason: 'unknown-upgrade' };
  }

  if (
    type === 'depot'
    && !state.depot.built
  ) {
    return { ok: false, reason: 'depot-required' };
  }

  if (
    (type === 'shelter2' || type === 'catchment2')
    && !state.line2.built
  ) {
    return { ok: false, reason: 'line-required' };
  }

  const cost =
    getUpgradeCost(state, type);

  if (state.money < cost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= cost;

  if (type === 'shelter1') {
    state.line1.shelterLevel += 1;
    state.line1.waitingCapacityPassengers +=
      config.delta;
  } else if (type === 'catchment1') {
    state.line1.catchmentLevel += 1;
    state.line1.demandPerStopPpm +=
      config.delta;
  } else if (type === 'depot') {
    state.depot.level += 1;
    state.depot.garageSlots +=
      config.delta;
  } else if (type === 'shelter2') {
    state.line2.shelterLevel += 1;
    state.line2.waitingCapacityPassengers +=
      config.delta;
  } else if (type === 'catchment2') {
    state.line2.catchmentLevel += 1;
    state.line2.demandPerStopPpm +=
      config.delta;
  }

  return { ok: true, cost };
}

export function setSimulationSpeed(state, speed) {
  if (![0, 1, 2, 4].includes(speed)) {
    return { ok: false, reason: 'invalid-speed' };
  }

  state.simulationSpeed = speed;

  return { ok: true };
}
