import { GAME_VERSION, createInitialState } from '../simulation/model.js';

const SAVE_KEY = 'i-like-networks.phase1.save';

function migrateVersion1(previous) {
  const next = createInitialState();
  next.money = Number.isFinite(previous.money) ? previous.money : next.money;
  next.elapsedSeconds = Number.isFinite(previous.elapsedSeconds) ? previous.elapsedSeconds : 0;
  next.simulationSpeed = [0, 1, 2, 4].includes(previous.simulationSpeed) ? previous.simulationSpeed : 1;
  next.linkBuilt = Boolean(previous.linkBuilt);

  if (previous.client) {
    next.client.trafficMbps = previous.client.trafficMbps ?? next.client.trafficMbps;
    next.client.level = previous.client.level ?? 0;
  }
  if (previous.link) {
    next.link.capacityMbps = previous.link.capacityMbps ?? next.link.capacityMbps;
    next.link.level = previous.link.level ?? 0;
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

export function loadState() {
  try {
    const raw = localStorage.getItem(SAVE_KEY);
    if (!raw) return createInitialState();
    const parsed = JSON.parse(raw);
    if (parsed.version === GAME_VERSION) return parsed;
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
