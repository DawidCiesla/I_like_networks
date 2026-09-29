import { ECONOMY, UPGRADES, getUpgradeCost } from './model.js';

export function buildEthernet(state) {
  if (state.linkBuilt) return { ok: false, reason: 'already-built' };
  if (state.money < ECONOMY.ethernetBuildCost) return { ok: false, reason: 'insufficient-funds' };
  state.money -= ECONOMY.ethernetBuildCost;
  state.linkBuilt = true;
  return { ok: true };
}

export function buyUpgrade(state, type) {
  const config = UPGRADES[type];
  if (!config) return { ok: false, reason: 'unknown-upgrade' };
  if (type === 'link' && !state.linkBuilt) return { ok: false, reason: 'link-required' };
  const cost = getUpgradeCost(state, type);
  if (state.money < cost) return { ok: false, reason: 'insufficient-funds' };

  state.money -= cost;
  state[type].level += 1;
  if (type === 'client') state.client.trafficMbps += config.delta;
  if (type === 'link') state.link.capacityMbps += config.delta;
  if (type === 'server') state.server.capacityMbps += config.delta;
  return { ok: true, cost };
}

export function setSimulationSpeed(state, speed) {
  if (![0, 1, 2, 4].includes(speed)) return { ok: false, reason: 'invalid-speed' };
  state.simulationSpeed = speed;
  return { ok: true };
}
