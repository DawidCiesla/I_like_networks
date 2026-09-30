import {
  ECONOMY,
  UPGRADES,
  getAddStopACost,
  getAddStopBCost,
  getUpgradeCost,
  getVehiclePurchaseCost,
} from './model.js';

export function buildFirstLine(state) {
  if (state.corridorA.lineBuilt) {
    return { ok: false, reason: 'already-built' };
  }

  if (state.money < ECONOMY.firstLineBuildCost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= ECONOMY.firstLineBuildCost;
  state.corridorA.lineBuilt = true;

  return { ok: true };
}

export function buildTerminalA(state) {
  if (!state.corridorA.lineBuilt) {
    return { ok: false, reason: 'line-required' };
  }

  if (state.terminalA.built) {
    return { ok: false, reason: 'already-built' };
  }

  if (state.money < ECONOMY.terminalBuildCost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= ECONOMY.terminalBuildCost;
  state.terminalA.built = true;

  return { ok: true };
}

export function buildInterchange(state) {
  if (!state.terminalA.built) {
    return { ok: false, reason: 'terminal-required' };
  }

  if (state.interchange.built) {
    return { ok: false, reason: 'already-built' };
  }

  if (state.money < ECONOMY.interchangeBuildCost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= ECONOMY.interchangeBuildCost;
  state.interchange.built = true;
  state.terminalA.queuePassengers = 0;
  state.terminalA.currentAbandonmentPpm = 0;

  return { ok: true };
}

export function buildCorridorB(state) {
  if (!state.interchange.built) {
    return { ok: false, reason: 'interchange-required' };
  }

  if (state.corridorB.built) {
    return { ok: false, reason: 'already-built' };
  }

  if (state.money < ECONOMY.corridorBBuildCost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= ECONOMY.corridorBBuildCost;
  state.corridorB.built = true;

  return { ok: true };
}

export function buildStationB(state) {
  if (!state.interchange.built) {
    return { ok: false, reason: 'interchange-required' };
  }

  if (state.stationB.built) {
    return { ok: false, reason: 'already-built' };
  }

  if (state.money < ECONOMY.stationBBuildCost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= ECONOMY.stationBBuildCost;
  state.stationB.built = true;

  return { ok: true };
}

export function addStopA(state) {
  if (!state.terminalA.built) {
    return { ok: false, reason: 'terminal-required' };
  }

  if (state.corridorA.stopCount >= ECONOMY.maxStopsA) {
    return { ok: false, reason: 'stop-limit' };
  }

  const cost = getAddStopACost(state);

  if (state.money < cost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= cost;
  state.corridorA.stopCount += 1;

  return { ok: true, cost };
}

export function addStopB(state) {
  if (!state.corridorB.built) {
    return { ok: false, reason: 'corridor-required' };
  }

  if (state.corridorB.stopCount >= ECONOMY.maxStopsB) {
    return { ok: false, reason: 'stop-limit' };
  }

  const cost = getAddStopBCost(state);

  if (state.money < cost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= cost;
  state.corridorB.stopCount += 1;

  return { ok: true, cost };
}

export function addVehicle(state, corridorKey) {
  const corridor =
    corridorKey === 'corridorA'
      ? state.corridorA
      : corridorKey === 'corridorB'
        ? state.corridorB
        : null;

  if (!corridor) {
    return { ok: false, reason: 'unknown-corridor' };
  }

  if (
    corridorKey === 'corridorA'
    && !state.corridorA.lineBuilt
  ) {
    return { ok: false, reason: 'line-required' };
  }

  if (
    corridorKey === 'corridorB'
    && !state.corridorB.built
  ) {
    return { ok: false, reason: 'corridor-required' };
  }

  if (
    corridor.fleetCount
    >= ECONOMY.maxVehiclesPerLine
  ) {
    return { ok: false, reason: 'fleet-limit' };
  }

  const cost = getVehiclePurchaseCost(
    state,
    corridorKey,
  );

  if (state.money < cost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= cost;
  corridor.fleetCount += 1;

  return { ok: true, cost };
}

export function buyUpgrade(state, type) {
  const config = UPGRADES[type];

  if (!config) {
    return { ok: false, reason: 'unknown-upgrade' };
  }

  if (
    (type === 'terminalA' || type === 'waitingArea')
    && !state.terminalA.built
  ) {
    return { ok: false, reason: 'terminal-required' };
  }

  if (
    type === 'interchange'
    && !state.interchange.built
  ) {
    return { ok: false, reason: 'interchange-required' };
  }

  if (
    type === 'stationB'
    && !state.stationB.built
  ) {
    return { ok: false, reason: 'station-b-required' };
  }

  const cost = getUpgradeCost(state, type);

  if (state.money < cost) {
    return { ok: false, reason: 'insufficient-funds' };
  }

  state.money -= cost;

  if (type === 'catchmentA') {
    state.corridorA.demandLevel += 1;
    state.corridorA.demandPerStopPpm += config.delta;
  } else if (type === 'terminalA') {
    state.terminalA.level += 1;
    state.terminalA.platformCapacityPpm += config.delta;
  } else if (type === 'waitingArea') {
    state.terminalA.waitingLevel += 1;
    state.terminalA.waitingCapacityPassengers += config.delta;
  } else if (type === 'stationA') {
    state.stationA.level += 1;
    state.stationA.capacityPpm += config.delta;
  } else if (type === 'interchange') {
    state.interchange.level += 1;
    state.interchange.transferCapacityPpm += config.delta;
  } else if (type === 'stationB') {
    state.stationB.level += 1;
    state.stationB.capacityPpm += config.delta;
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
