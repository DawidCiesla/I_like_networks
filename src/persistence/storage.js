import {
  ECONOMY,
  GAME_VERSION,
  createInitialState,
} from '../simulation/model.js';

const SAVE_KEY = 'i-like-transit.save';
const T0_SAVE_KEY = 'i-like-transit.phaseT0.save';
const NETWORK_SAVE_KEY = 'i-like-networks.phase1.save';

const clamp = (value, min, max) =>
  Math.min(max, Math.max(min, value));

function copyCommon(previous, next) {
  next.money = Number.isFinite(previous.money)
    ? previous.money
    : next.money;

  next.elapsedSeconds = Number.isFinite(previous.elapsedSeconds)
    ? previous.elapsedSeconds
    : 0;

  next.simulationSpeed = [0, 1, 2, 4].includes(previous.simulationSpeed)
    ? previous.simulationSpeed
    : 1;

  if (previous.stats) {
    next.stats.lifetimeRevenue =
      previous.stats.lifetimeRevenue ?? 0;

    next.stats.lifetimePassengers =
      previous.stats.lifetimePassengers
      ?? previous.stats.lifetimeDataMb
      ?? 0;
  }

  return next;
}

function migrateT1(previous) {
  const next = copyCommon(
    previous,
    createInitialState(),
  );

  if (previous.corridorA) {
    next.line1.stopCount = clamp(
      previous.corridorA.stopCount ?? 1,
      1,
      ECONOMY.maxLine1Stops,
    );

    next.line1.built = Boolean(
      previous.corridorA.lineBuilt
      && next.line1.stopCount >= 2,
    );

    next.line1.fleetCount =
      next.line1.built
        ? clamp(
          previous.corridorA.fleetCount ?? 1,
          1,
          ECONOMY.maxVehiclesPerLine,
        )
        : 0;

    next.line1.catchmentLevel =
      previous.corridorA.demandLevel ?? 0;

    next.line1.demandPerStopPpm =
      2.2
      + next.line1.catchmentLevel * 0.5;
  }

  if (previous.terminalA) {
    next.line1.waitingCapacityPassengers =
      previous.terminalA.waitingCapacityPassengers
      ?? next.line1.waitingCapacityPassengers;

    next.line1.queuePassengers =
      previous.terminalA.queuePassengers ?? 0;

    next.line1.currentAbandonmentPpm =
      previous.terminalA.currentAbandonmentPpm ?? 0;

    next.line1.totalAbandonedPassengers =
      previous.terminalA.totalAbandonedPassengers ?? 0;
  }

  if (previous.corridorB?.built) {
    next.line2.built = true;

    next.line2.stopCount = clamp(
      previous.corridorB.stopCount ?? 2,
      2,
      ECONOMY.maxLine2Stops,
    );

    next.line2.fleetCount = clamp(
      previous.corridorB.fleetCount ?? 1,
      1,
      ECONOMY.maxVehiclesPerLine,
    );

    next.line2.queuePassengers =
      previous.corridorB.queuePassengers ?? 0;

    next.line2.currentAbandonmentPpm =
      previous.corridorB.currentAbandonmentPpm ?? 0;

    next.line2.totalAbandonedPassengers =
      previous.corridorB.totalAbandonedPassengers ?? 0;
  }

  const totalFleet =
    next.line1.fleetCount
    + next.line2.fleetCount;

  next.depot.built = Boolean(
    previous.interchange?.built
    || totalFleet > 1,
  );

  if (next.depot.built) {
    next.depot.garageSlots = Math.max(
      4,
      totalFleet,
    );
  }

  return next;
}

function migrateTransportT0(previous) {
  return migrateT1(previous);
}

function migrateLegacyNetwork(previous) {
  const next = copyCommon(
    previous,
    createInitialState(),
  );

  const legacyStops =
    previous.client?.count ?? 1;

  next.line1.stopCount = clamp(
    legacyStops,
    1,
    ECONOMY.maxLine1Stops,
  );

  next.line1.built = Boolean(
    previous.linkBuilt
    && next.line1.stopCount >= 2,
  );

  next.line1.fleetCount =
    next.line1.built
      ? clamp(
        Math.max(
          1,
          Math.ceil(
            (previous.link?.capacityMbps ?? 20)
            / 20,
          ),
        ),
        1,
        ECONOMY.maxVehiclesPerLine,
      )
      : 0;

  if (previous.switch) {
    next.line1.waitingCapacityPassengers =
      previous.switch.bufferMb
      ?? next.line1.waitingCapacityPassengers;

    next.line1.queuePassengers =
      previous.switch.queueMb ?? 0;
  }

  if (previous.branch?.built) {
    next.line2.built = true;

    next.line2.stopCount = clamp(
      previous.branch.clientCount ?? 2,
      2,
      ECONOMY.maxLine2Stops,
    );

    next.line2.fleetCount = 1;
  }

  const totalFleet =
    next.line1.fleetCount
    + next.line2.fleetCount;

  next.depot.built = Boolean(
    previous.router?.built
    || totalFleet > 1,
  );

  next.depot.garageSlots = Math.max(
    4,
    totalFleet,
  );

  return next;
}

function parseStored(raw) {
  if (!raw) return null;

  const parsed = JSON.parse(raw);

  if (parsed.version === GAME_VERSION) {
    return parsed;
  }

  if (parsed.version === 5) {
    return migrateT1(parsed);
  }

  if (parsed.version === 4) {
    return migrateTransportT0(parsed);
  }

  if ([1, 2, 3].includes(parsed.version)) {
    return migrateLegacyNetwork(parsed);
  }

  return null;
}

export function loadState() {
  try {
    const current = parseStored(
      localStorage.getItem(SAVE_KEY),
    );

    if (current) return current;

    const t0 = parseStored(
      localStorage.getItem(T0_SAVE_KEY),
    );

    if (t0) return t0;

    const legacy = parseStored(
      localStorage.getItem(NETWORK_SAVE_KEY),
    );

    if (legacy) return legacy;

    return createInitialState();
  } catch {
    return createInitialState();
  }
}

export function saveState(state) {
  localStorage.setItem(
    SAVE_KEY,
    JSON.stringify(state),
  );
}

export function clearSave() {
  localStorage.removeItem(SAVE_KEY);
  localStorage.removeItem(T0_SAVE_KEY);
  localStorage.removeItem(NETWORK_SAVE_KEY);
}
