import {
  ECONOMY,
  LINE_KEYS,
  STATION_UPGRADE,
  UPGRADES,
  canBuildDepot,
  canUnlockLine2,
  canUnlockLine3,
  canUnlockLine4,
  addVehicleToLineState,
  getGarageUsed,
  getNextStopCost,
  getStationLevel,
  getStationUpgradeCost,
  getUpgradeCost,
  isStationBuilt,
  getVehiclePurchaseCost,
  initializeLineService,
} from './model.js';

export function buildNextStop(state, lineKey) {
  const line =
    LINE_KEYS.includes(lineKey)
      ? state[lineKey]
      : null;

  if (!line) {
    return { ok: false, reason: 'unknown-line' };
  }

  if (
    lineKey !== 'line1'
    && !line.built
  ) {
    return {
      ok: false,
      reason: 'line-required',
    };
  }

  const maxStops = {
    line1: ECONOMY.maxLine1Stops,
    line2: ECONOMY.maxLine2Stops,
    line3: ECONOMY.maxLine3Stops,
    line4: ECONOMY.maxLine4Stops,
  }[lineKey];

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

function buildNewLine(
  state,
  lineKey,
  {
    canUnlock,
    buildCost,
  },
) {
  if (!canUnlock(state)) {
    return {
      ok: false,
      reason: 'progress-required',
    };
  }

  if (state.money < buildCost) {
    return {
      ok: false,
      reason: 'insufficient-funds',
    };
  }

  state.money -= buildCost;

  state[lineKey].stopCount = 2;

  initializeLineService(
    state,
    lineKey,
    1,
  );

  return {
    ok: true,
    cost: buildCost,
  };
}

export function buildLine2(state) {
  return buildNewLine(
    state,
    'line2',
    {
      canUnlock: canUnlockLine2,
      buildCost:
        ECONOMY.line2BuildCost,
    },
  );
}

export function buildLine3(state) {
  return buildNewLine(
    state,
    'line3',
    {
      canUnlock: canUnlockLine3,
      buildCost:
        ECONOMY.line3BuildCost,
    },
  );
}

export function buildLine4(state) {
  return buildNewLine(
    state,
    'line4',
    {
      canUnlock: canUnlockLine4,
      buildCost:
        ECONOMY.line4BuildCost,
    },
  );
}

export function addVehicle(state, lineKey) {
  const line =
    LINE_KEYS.includes(lineKey)
      ? state[lineKey]
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

export function upgradeStation(
  state,
  stationId,
) {
  if (!isStationBuilt(
    state,
    stationId,
  )) {
    return {
      ok: false,
      reason: 'station-required',
    };
  }

  const level =
    getStationLevel(
      state,
      stationId,
    );

  if (
    level
    >= STATION_UPGRADE.maxLevel
  ) {
    return {
      ok: false,
      reason: 'upgrade-limit',
    };
  }

  const cost =
    getStationUpgradeCost(
      state,
      stationId,
    );

  if (state.money < cost) {
    return {
      ok: false,
      reason: 'insufficient-funds',
    };
  }

  state.money -= cost;

  if (!state.stations[stationId]) {
    state.stations[stationId] = {
      level: 0,
    };
  }

  state.stations[
    stationId
  ].level += 1;

  return {
    ok: true,
    cost,
    level:
      state.stations[
        stationId
      ].level,
  };
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
