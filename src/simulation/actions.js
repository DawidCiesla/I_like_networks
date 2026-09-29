import { ECONOMY, UPGRADES, getAddClientCost, getUpgradeCost } from './model.js';

export function buildEthernet(state) {
  if (state.linkBuilt) return { ok: false, reason: 'already-built' };
  if (state.money < ECONOMY.ethernetBuildCost) return { ok: false, reason: 'insufficient-funds' };
  state.money -= ECONOMY.ethernetBuildCost;
  state.linkBuilt = true;
  return { ok: true };
}

export function buildSwitch(state) {
  if (!state.linkBuilt) return { ok: false, reason: 'link-required' };
  if (state.switch.built) return { ok: false, reason: 'already-built' };
  if (state.money < ECONOMY.switchBuildCost) return { ok: false, reason: 'insufficient-funds' };
  state.money -= ECONOMY.switchBuildCost;
  state.switch.built = true;
  return { ok: true };
}

export function addClient(state) {
  if (!state.switch.built) return { ok: false, reason: 'switch-required' };
  if (state.client.count >= ECONOMY.maxClients) return { ok: false, reason: 'client-limit' };
  const cost = getAddClientCost(state);
  if (state.money < cost) return { ok: false, reason: 'insufficient-funds' };
  state.money -= cost;
  state.client.count += 1;
  return { ok: true, cost };
}

export function buyUpgrade(state, type) {
  const config = UPGRADES[type];
  if (!config) return { ok: false, reason: 'unknown-upgrade' };
  if (type === 'link' && !state.linkBuilt) return { ok: false, reason: 'link-required' };
  if ((type === 'switch' || type === 'buffer') && !state.switch.built) return { ok: false, reason: 'switch-required' };
  const cost = getUpgradeCost(state, type);
  if (state.money < cost) return { ok: false, reason: 'insufficient-funds' };

  state.money -= cost;
  if (type === 'client') {
    state.client.level += 1;
    state.client.trafficMbps += config.delta;
  } else if (type === 'link') {
    state.link.level += 1;
    state.link.capacityMbps += config.delta;
  } else if (type === 'switch') {
    state.switch.level += 1;
    state.switch.capacityMbps += config.delta;
  } else if (type === 'buffer') {
    state.switch.bufferLevel += 1;
    state.switch.bufferMb += config.delta;
  } else if (type === 'server') {
    state.server.level += 1;
    state.server.capacityMbps += config.delta;
  }
  return { ok: true, cost };
}

export function setSimulationSpeed(state, speed) {
  if (![0, 1, 2, 4].includes(speed)) return { ok: false, reason: 'invalid-speed' };
  state.simulationSpeed = speed;
  return { ok: true };
}
