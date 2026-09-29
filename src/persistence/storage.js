import { GAME_VERSION, createInitialState } from '../simulation/model.js';

const SAVE_KEY = 'i-like-networks.phase1.save';

function copyLegacyBase(previous, next) {
  next.money = Number.isFinite(previous.money) ? previous.money : next.money;
  next.elapsedSeconds = Number.isFinite(previous.elapsedSeconds) ? previous.elapsedSeconds : 0;
  next.simulationSpeed = [0, 1, 2, 4].includes(previous.simulationSpeed)
    ? previous.simulationSpeed
    : 1;
  next.linkBuilt = Boolean(previous.linkBuilt);

  if (previous.client) {
    next.client.trafficMbps = previous.client.trafficMbps ?? next.client.trafficMbps;
    next.client.level = previous.client.level ?? 0;
    next.client.count = previous.client.count ?? 1;
  }

  if (previous.link) {
    next.link.capacityMbps = previous.link.capacityMbps ?? next.link.capacityMbps;
    next.link.level = previous.link.level ?? 0;
  }

  if (previous.switch) {
    next.switch.built = Boolean(previous.switch.built);
    next.switch.capacityMbps = previous.switch.capacityMbps ?? next.switch.capacityMbps;
    next.switch.level = previous.switch.level ?? 0;
    next.switch.bufferMb = previous.switch.bufferMb ?? next.switch.bufferMb;
    next.switch.bufferLevel = previous.switch.bufferLevel ?? 0;
    next.switch.queueMb = previous.switch.queueMb ?? 0;
    next.switch.currentDropMbps = previous.switch.currentDropMbps ?? 0;
    next.switch.totalDroppedMb = previous.switch.totalDroppedMb ?? 0;
  }

  if (previous.server) {
    next.server.capacityMbps = previous.server.capacityMbps ?? next.server.capacityMbps;
    next.server.level = previous.server.level ?? 0;
  }

  if (previous.stats) {
    next.stats.lifetimeRevenue = previous.stats.lifetimeRevenue ?? 0;
    next.stats.lifetimeDataMb = previous.stats.lifetimeDataMb ?? 0;
  }

  return next;
}

function migrateVersion1(previous) {
  return copyLegacyBase(previous, createInitialState());
}

function migrateVersion2(previous) {
  return copyLegacyBase(previous, createInitialState());
}

export function loadState() {
  try {
    const raw = localStorage.getItem(SAVE_KEY);
    if (!raw) return createInitialState();

    const parsed = JSON.parse(raw);

    if (parsed.version === GAME_VERSION) return parsed;
    if (parsed.version === 2) return migrateVersion2(parsed);
    if (parsed.version === 1) return migrateVersion1(parsed);

    return createInitialState();
  } catch {
    return createInitialState();
  }
}

export function saveState(state) {
  localStorage.setItem(SAVE_KEY, JSON.stringify(state));
}

export function clearSave() {
  localStorage.removeItem(SAVE_KEY);
}
