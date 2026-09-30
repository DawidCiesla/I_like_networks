import {
  ECONOMY,
  GAME_VERSION,
  TRANSPORT_MODES,
  createInitialState,
  getLineCycleMinutes,
} from '../simulation/model.js';

const SAVE_KEY = 'i-like-transit.save';
const T0_SAVE_KEY = 'i-like-transit.phaseT0.save';
const NETWORK_SAVE_KEY = 'i-like-networks.phase1.save';

const clamp = (value, min, max) =>
  Math.min(max, Math.max(min, value));

function estimateFleetForLegacyCapacity(
  state,
  corridorKey,
  legacyCapacityPpm,
) {
  const corridor = state[corridorKey];
  const mode = TRANSPORT_MODES[corridor.mode];
  const cycle = getLineCycleMinutes(
    state,
    corridorKey,
  );

  const estimated = Math.ceil(
    legacyCapacityPpm
    * cycle
    / mode.vehicleCapacity,
  );

  return clamp(
    estimated,
    2,
    ECONOMY.maxVehiclesPerLine,
  );
}

function copyCommon(previous, next) {
  next.money = Number.isFinite(previous.money)
    ? previous.money
    : next.money;

  next.elapsedSeconds =
    Number.isFinite(previous.elapsedSeconds)
      ? previous.elapsedSeconds
      : 0;

  next.simulationSpeed =
    [0, 1, 2, 4].includes(previous.simulationSpeed)
      ? previous.simulationSpeed
      : 1;

  return next;
}

function migrateT0(previous) {
  const next = copyCommon(
    previous,
    createInitialState(),
  );

  if (previous.corridorA) {
    next.corridorA.lineBuilt =
      Boolean(previous.corridorA.lineBuilt);

    next.corridorA.mode =
      previous.corridorA.mode
      ?? next.corridorA.mode;

    next.corridorA.stopCount =
      previous.corridorA.stopCount
      ?? next.corridorA.stopCount;

    next.corridorA.demandPerStopPpm =
      previous.corridorA.demandPerStopPpm
      ?? next.corridorA.demandPerStopPpm;

    next.corridorA.demandLevel =
      previous.corridorA.demandLevel
      ?? 0;

    next.corridorA.fleetCount =
      estimateFleetForLegacyCapacity(
        next,
        'corridorA',
        previous.corridorA.lineCapacityPpm
          ?? 20,
      );
  }

  if (previous.terminalA) {
    next.terminalA = {
      ...next.terminalA,
      ...previous.terminalA,
    };
  }

  if (previous.stationA) {
    next.stationA = {
      ...next.stationA,
      ...previous.stationA,
    };
  }

  if (previous.interchange) {
    next.interchange = {
      ...next.interchange,
      ...previous.interchange,
      destinationQueuesPassengers: {
        ...next.interchange.destinationQueuesPassengers,
        ...(previous.interchange.destinationQueuesPassengers ?? {}),
      },
      destinationAbandonmentPpm: {
        ...next.interchange.destinationAbandonmentPpm,
        ...(previous.interchange.destinationAbandonmentPpm ?? {}),
      },
      lastDeliveredPpm: {
        ...next.interchange.lastDeliveredPpm,
        ...(previous.interchange.lastDeliveredPpm ?? {}),
      },
    };
  }

  if (previous.corridorB) {
    next.corridorB.built =
      Boolean(previous.corridorB.built);

    next.corridorB.mode =
      previous.corridorB.mode
      ?? next.corridorB.mode;

    next.corridorB.stopCount =
      previous.corridorB.stopCount
      ?? next.corridorB.stopCount;

    next.corridorB.demandPerStopPpm =
      previous.corridorB.demandPerStopPpm
      ?? next.corridorB.demandPerStopPpm;

    next.corridorB.fleetCount =
      estimateFleetForLegacyCapacity(
        next,
        'corridorB',
        previous.corridorB.lineCapacityPpm
          ?? 30,
      );
  }

  if (previous.stationB) {
    next.stationB = {
      ...next.stationB,
      ...previous.stationB,
    };
  }

  if (previous.stats) {
    next.stats.lifetimeRevenue =
      previous.stats.lifetimeRevenue
      ?? 0;

    next.stats.lifetimePassengers =
      previous.stats.lifetimePassengers
      ?? 0;
  }

  return next;
}

function migrateNetworkState(previous) {
  const next = copyCommon(
    previous,
    createInitialState(),
  );

  next.corridorA.lineBuilt =
    Boolean(previous.linkBuilt);

  if (previous.client) {
    next.corridorA.stopCount =
      previous.client.count
      ?? 1;

    next.corridorA.demandPerStopPpm =
      Math.max(
        1,
        Math.round(
          (previous.client.trafficMbps ?? 10)
          / 2.5,
        ),
      );

    next.corridorA.demandLevel =
      previous.client.level
      ?? 0;
  }

  if (previous.link) {
    next.corridorA.fleetCount =
      estimateFleetForLegacyCapacity(
        next,
        'corridorA',
        previous.link.capacityMbps
          ?? 20,
      );
  }

  if (previous.switch) {
    next.terminalA.built =
      Boolean(previous.switch.built);

    next.terminalA.platformCapacityPpm =
      previous.switch.capacityMbps
      ?? next.terminalA.platformCapacityPpm;

    next.terminalA.level =
      previous.switch.level
      ?? 0;

    next.terminalA.waitingCapacityPassengers =
      previous.switch.bufferMb
      ?? next.terminalA.waitingCapacityPassengers;

    next.terminalA.waitingLevel =
      previous.switch.bufferLevel
      ?? 0;

    next.terminalA.queuePassengers =
      previous.switch.queueMb
      ?? 0;

    next.terminalA.currentAbandonmentPpm =
      previous.switch.currentDropMbps
      ?? 0;

    next.terminalA.totalAbandonedPassengers =
      previous.switch.totalDroppedMb
      ?? 0;
  }

  if (previous.server) {
    next.stationA.capacityPpm =
      previous.server.capacityMbps
      ?? next.stationA.capacityPpm;

    next.stationA.level =
      previous.server.level
      ?? 0;
  }

  if (previous.router) {
    next.interchange.built =
      Boolean(previous.router.built);

    next.interchange.transferCapacityPpm =
      previous.router.capacityMbps
      ?? next.interchange.transferCapacityPpm;

    next.interchange.level =
      previous.router.level
      ?? 0;

    next.interchange.waitingCapacityPassengers =
      previous.router.bufferMb
      ?? next.interchange.waitingCapacityPassengers;

    next.interchange.queuePassengers =
      previous.router.queueMb
      ?? 0;

    next.interchange.currentAbandonmentPpm =
      previous.router.currentDropMbps
      ?? 0;

    next.interchange.totalAbandonedPassengers =
      previous.router.totalDroppedMb
      ?? 0;

    if (previous.router.routeQueuesMb) {
      next.interchange.destinationQueuesPassengers.primary =
        previous.router.routeQueuesMb.primary
        ?? 0;

      next.interchange.destinationQueuesPassengers.secondary =
        previous.router.routeQueuesMb.secondary
        ?? 0;
    }

    if (previous.router.routeDropsMbps) {
      next.interchange.destinationAbandonmentPpm.primary =
        previous.router.routeDropsMbps.primary
        ?? 0;

      next.interchange.destinationAbandonmentPpm.secondary =
        previous.router.routeDropsMbps.secondary
        ?? 0;
    }

    if (previous.router.lastThroughputMbps) {
      next.interchange.lastDeliveredPpm.primary =
        previous.router.lastThroughputMbps.primary
        ?? 0;

      next.interchange.lastDeliveredPpm.secondary =
        previous.router.lastThroughputMbps.secondary
        ?? 0;
    }
  }

  if (previous.branch) {
    next.corridorB.built =
      Boolean(previous.branch.built);

    next.corridorB.stopCount =
      previous.branch.clientCount
      ?? next.corridorB.stopCount;

    next.corridorB.demandPerStopPpm =
      Math.max(
        1,
        Math.round(
          (previous.branch.clientTrafficMbps ?? 8)
          / 2.5,
        ),
      );

    next.corridorB.fleetCount =
      estimateFleetForLegacyCapacity(
        next,
        'corridorB',
        previous.branch.linkCapacityMbps
          ?? 30,
      );
  }

  if (previous.secondaryServer) {
    next.stationB.built =
      Boolean(previous.secondaryServer.built);

    next.stationB.capacityPpm =
      previous.secondaryServer.capacityMbps
      ?? next.stationB.capacityPpm;

    next.stationB.level =
      previous.secondaryServer.level
      ?? 0;
  }

  if (previous.stats) {
    next.stats.lifetimeRevenue =
      previous.stats.lifetimeRevenue
      ?? 0;

    next.stats.lifetimePassengers =
      previous.stats.lifetimePassengers
      ?? previous.stats.lifetimeDataMb
      ?? 0;
  }

  return next;
}

function parseStored(raw) {
  if (!raw) return null;

  const parsed = JSON.parse(raw);

  if (parsed.version === GAME_VERSION) {
    return parsed;
  }

  if (parsed.version === 4) {
    return migrateT0(parsed);
  }

  if ([1, 2, 3].includes(parsed.version)) {
    return migrateNetworkState(parsed);
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
