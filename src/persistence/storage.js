import {
  createInitialCityState,
} from '../city/cityModel.js';

import {
  ECONOMY,
  GAME_VERSION,
  createInitialState,
  ensureCityRuntime,
  ensureLineRuntime,
  initializeLineService,
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

function seedLegacyQueue(line, amount) {
  if (
    !Number.isFinite(amount)
    || amount <= 0
    || line.stopCount < 2
  ) {
    return;
  }

  line.waitingByStop[0][line.stopCount - 1] = amount;
  line.queuePassengers = amount;
}

function restoreBusEraLine(
  next,
  previousLine,
  lineKey,
  {
    minStops,
    maxStops,
  },
) {
  if (!previousLine) return;

  const line = next[lineKey];

  line.stopCount = clamp(
    previousLine.stopCount ?? minStops,
    minStops,
    maxStops,
  );

  line.demandPerStopPpm =
    previousLine.demandPerStopPpm
    ?? line.demandPerStopPpm;

  line.waitingCapacityPassengers =
    previousLine.waitingCapacityPassengers
    ?? line.waitingCapacityPassengers;

  line.shelterLevel =
    previousLine.shelterLevel ?? 0;

  line.catchmentLevel =
    previousLine.catchmentLevel ?? 0;

  line.totalAbandonedPassengers =
    previousLine.totalAbandonedPassengers ?? 0;

  const built = Boolean(previousLine.built);

  if (built && line.stopCount >= 2) {
    const fleetCount = clamp(
      previousLine.fleetCount ?? 1,
      1,
      ECONOMY.maxVehiclesPerLine,
    );

    initializeLineService(
      next,
      lineKey,
      fleetCount,
    );

    seedLegacyQueue(
      line,
      previousLine.queuePassengers ?? 0,
    );
  }
}

function migrateBusEraV6(previous) {
  const next = copyCommon(
    previous,
    createInitialState(),
  );

  if (
    Number.isFinite(
      previous.city?.seed,
    )
  ) {
    next.city =
      createInitialCityState(
        previous.city.seed,
      );
  }

  restoreBusEraLine(
    next,
    previous.line1,
    'line1',
    {
      minStops: 1,
      maxStops: ECONOMY.maxLine1Stops,
    },
  );

  restoreBusEraLine(
    next,
    previous.line2,
    'line2',
    {
      minStops: 0,
      maxStops: ECONOMY.maxLine2Stops,
    },
  );

  if (previous.depot) {
    next.depot.built =
      Boolean(previous.depot.built);

    next.depot.garageSlots =
      previous.depot.garageSlots
      ?? next.depot.garageSlots;

    next.depot.level =
      previous.depot.level ?? 0;
  }

  next.depot.garageSlots = Math.max(
    next.depot.garageSlots,
    next.line1.fleetCount
      + next.line2.fleetCount,
  );

  return next;
}

function migrateTransportV5(previous) {
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

    next.line1.demandPerStopPpm =
      previous.corridorA.demandPerStopPpm
      ?? next.line1.demandPerStopPpm;

    if (
      previous.corridorA.lineBuilt
      && next.line1.stopCount >= 2
    ) {
      initializeLineService(
        next,
        'line1',
        clamp(
          previous.corridorA.fleetCount ?? 1,
          1,
          ECONOMY.maxVehiclesPerLine,
        ),
      );
    }
  }

  if (previous.terminalA) {
    next.line1.waitingCapacityPassengers =
      previous.terminalA.waitingCapacityPassengers
      ?? next.line1.waitingCapacityPassengers;

    seedLegacyQueue(
      next.line1,
      previous.terminalA.queuePassengers ?? 0,
    );
  }

  if (previous.corridorB?.built) {
    next.line2.stopCount = clamp(
      previous.corridorB.stopCount ?? 2,
      2,
      ECONOMY.maxLine2Stops,
    );

    next.line2.demandPerStopPpm =
      previous.corridorB.demandPerStopPpm
      ?? next.line2.demandPerStopPpm;

    initializeLineService(
      next,
      'line2',
      clamp(
        previous.corridorB.fleetCount ?? 1,
        1,
        ECONOMY.maxVehiclesPerLine,
      ),
    );

    seedLegacyQueue(
      next.line2,
      previous.corridorB.queuePassengers ?? 0,
    );
  }

  const totalFleet =
    next.line1.fleetCount
    + next.line2.fleetCount;

  next.depot.built = Boolean(
    previous.interchange?.built
    || totalFleet > 1,
  );

  next.depot.garageSlots = Math.max(
    4,
    totalFleet,
  );

  return next;
}

function migrateOlder(previous) {
  const next = copyCommon(
    previous,
    createInitialState(),
  );

  const stopCount = clamp(
    previous.client?.count ?? 1,
    1,
    ECONOMY.maxLine1Stops,
  );

  next.line1.stopCount = stopCount;

  if (
    previous.linkBuilt
    && stopCount >= 2
  ) {
    initializeLineService(
      next,
      'line1',
      clamp(
        Math.max(
          1,
          Math.ceil(
            (previous.link?.capacityMbps ?? 20)
            / 20,
          ),
        ),
        1,
        ECONOMY.maxVehiclesPerLine,
      ),
    );
  }

  if (previous.switch) {
    next.line1.waitingCapacityPassengers =
      previous.switch.bufferMb
      ?? next.line1.waitingCapacityPassengers;

    seedLegacyQueue(
      next.line1,
      previous.switch.queueMb ?? 0,
    );
  }

  if (previous.branch?.built) {
    next.line2.stopCount = clamp(
      previous.branch.clientCount ?? 2,
      2,
      ECONOMY.maxLine2Stops,
    );

    initializeLineService(
      next,
      'line2',
      1,
    );
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

  if (
    parsed.version === 8
    || parsed.version === 7
    || parsed.version === 6
  ) {
    return migrateBusEraV6(parsed);
  }

  if (parsed.version === 5 || parsed.version === 4) {
    return migrateTransportV5(parsed);
  }

  if ([1, 2, 3].includes(parsed.version)) {
    return migrateOlder(parsed);
  }

  return null;
}

function prepareLoadedState(state) {
  ensureLineRuntime(state, 'line1');
  ensureLineRuntime(state, 'line2');
  ensureCityRuntime(state);

  for (const lineKey of ['line1', 'line2']) {
    state[lineKey].passengerEvents = [];
    state[lineKey].lastPassengerEvent = null;
  }

  return state;
}

export function loadState() {
  try {
    const current = parseStored(
      localStorage.getItem(SAVE_KEY),
    );

    if (current) {
      return prepareLoadedState(current);
    }

    const t0 = parseStored(
      localStorage.getItem(T0_SAVE_KEY),
    );

    if (t0) {
      return prepareLoadedState(t0);
    }

    const legacy = parseStored(
      localStorage.getItem(NETWORK_SAVE_KEY),
    );

    if (legacy) {
      return prepareLoadedState(legacy);
    }

    return prepareLoadedState(
      createInitialState(),
    );
  } catch {
    return prepareLoadedState(
      createInitialState(),
    );
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
