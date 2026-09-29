import {
  GAME_VERSION,
  createInitialState,
} from '../simulation/model.js';

const SAVE_KEY = 'i-like-transit.phaseT0.save';
const LEGACY_SAVE_KEY = 'i-like-networks.phase1.save';

function migrateNetworkState(previous) {
  const next = createInitialState();

  next.money = Number.isFinite(previous.money)
    ? previous.money
    : next.money;

  next.elapsedSeconds = Number.isFinite(previous.elapsedSeconds)
    ? previous.elapsedSeconds
    : 0;

  next.simulationSpeed = [0, 1, 2, 4].includes(previous.simulationSpeed)
    ? previous.simulationSpeed
    : 1;

  next.corridorA.lineBuilt = Boolean(previous.linkBuilt);

  if (previous.client) {
    next.corridorA.stopCount = previous.client.count ?? 1;
    next.corridorA.demandPerStopPpm =
      previous.client.trafficMbps
      ?? next.corridorA.demandPerStopPpm;
    next.corridorA.demandLevel =
      previous.client.level
      ?? 0;
  }

  if (previous.link) {
    next.corridorA.lineCapacityPpm =
      previous.link.capacityMbps
      ?? next.corridorA.lineCapacityPpm;
    next.corridorA.lineLevel =
      previous.link.level
      ?? 0;
  }

  if (previous.switch) {
    next.terminalA.built = Boolean(previous.switch.built);
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
    next.interchange.built = Boolean(previous.router.built);
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
        previous.router.routeQueuesMb.primary ?? 0;
      next.interchange.destinationQueuesPassengers.secondary =
        previous.router.routeQueuesMb.secondary ?? 0;
    }

    if (previous.router.routeDropsMbps) {
      next.interchange.destinationAbandonmentPpm.primary =
        previous.router.routeDropsMbps.primary ?? 0;
      next.interchange.destinationAbandonmentPpm.secondary =
        previous.router.routeDropsMbps.secondary ?? 0;
    }

    if (previous.router.lastThroughputMbps) {
      next.interchange.lastDeliveredPpm.primary =
        previous.router.lastThroughputMbps.primary ?? 0;
      next.interchange.lastDeliveredPpm.secondary =
        previous.router.lastThroughputMbps.secondary ?? 0;
    }
  }

  if (previous.branch) {
    next.corridorB.built = Boolean(previous.branch.built);
    next.corridorB.stopCount =
      previous.branch.clientCount
      ?? next.corridorB.stopCount;
    next.corridorB.demandPerStopPpm =
      previous.branch.clientTrafficMbps
      ?? next.corridorB.demandPerStopPpm;
    next.corridorB.lineCapacityPpm =
      previous.branch.linkCapacityMbps
      ?? next.corridorB.lineCapacityPpm;
    next.corridorB.lineLevel =
      previous.branch.level
      ?? 0;
  }

  if (previous.secondaryServer) {
    next.stationB.built = Boolean(previous.secondaryServer.built);
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

  if ([1, 2, 3].includes(parsed.version)) {
    return migrateNetworkState(parsed);
  }

  return null;
}

export function loadState() {
  try {
    const current = parseStored(localStorage.getItem(SAVE_KEY));
    if (current) return current;

    const legacy = parseStored(localStorage.getItem(LEGACY_SAVE_KEY));
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
  localStorage.removeItem(LEGACY_SAVE_KEY);
}
