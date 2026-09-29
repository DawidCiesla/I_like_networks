export const GAME_VERSION = 2;

export const ECONOMY = Object.freeze({
  startingMoney: 100,
  ethernetBuildCost: 40,
  switchBuildCost: 95,
  addClientBaseCost: 60,
  addClientCostGrowth: 1.5,
  maxClients: 4,
  revenuePerMbpsSecond: 0.16,
});

export const UPGRADES = Object.freeze({
  client: { baseCost: 25, costGrowth: 1.65, delta: 5 },
  link: { baseCost: 35, costGrowth: 1.7, delta: 20 },
  switch: { baseCost: 70, costGrowth: 1.75, delta: 25 },
  buffer: { baseCost: 55, costGrowth: 1.7, delta: 40 },
  server: { baseCost: 45, costGrowth: 1.7, delta: 15 },
});

export function createInitialState() {
  return {
    version: GAME_VERSION,
    money: ECONOMY.startingMoney,
    elapsedSeconds: 0,
    simulationSpeed: 1,
    linkBuilt: false,
    client: { trafficMbps: 10, level: 0, count: 1 },
    link: { capacityMbps: 20, level: 0 },
    switch: {
      built: false,
      capacityMbps: 35,
      level: 0,
      bufferMb: 80,
      bufferLevel: 0,
      queueMb: 0,
      currentDropMbps: 0,
      totalDroppedMb: 0,
    },
    server: { capacityMbps: 25, level: 0 },
    stats: { lifetimeRevenue: 0, lifetimeDataMb: 0 },
  };
}

export function getTotalDemandMbps(state) {
  return state.client.trafficMbps * state.client.count;
}

export function getSwitchIngressCapacityMbps(state) {
  return state.switch.built ? state.switch.capacityMbps : Number.POSITIVE_INFINITY;
}

export function getServiceCapacityMbps(state) {
  if (!state.linkBuilt) return 0;
  return Math.min(state.link.capacityMbps, state.server.capacityMbps);
}

export function getArrivalMbps(state) {
  return Math.min(getTotalDemandMbps(state), getSwitchIngressCapacityMbps(state));
}

export function getThroughputMbps(state) {
  if (!state.linkBuilt) return 0;
  const arrival = getArrivalMbps(state);
  const serviceCapacity = getServiceCapacityMbps(state);
  if (state.switch.built && state.switch.queueMb > 0) return serviceCapacity;
  return Math.min(arrival, serviceCapacity);
}

export function getIncomePerSecond(state) {
  return getThroughputMbps(state) * ECONOMY.revenuePerMbpsSecond;
}

export function getUtilization(state) {
  const serviceCapacity = getServiceCapacityMbps(state);
  if (serviceCapacity <= 0) return 0;
  return Math.min(1, getThroughputMbps(state) / serviceCapacity);
}

export function getQueueFillRatio(state) {
  if (!state.switch.built || state.switch.bufferMb <= 0) return 0;
  return Math.min(1, state.switch.queueMb / state.switch.bufferMb);
}

export function getLatencyMs(state) {
  const serviceCapacity = getServiceCapacityMbps(state);
  if (!state.linkBuilt) return 0;
  if (!state.switch.built || serviceCapacity <= 0) return 4;
  const queueDelayMs = (state.switch.queueMb / serviceCapacity) * 1000;
  return Math.min(5000, 4 + queueDelayMs);
}

export function getPacketLossPercent(state) {
  const demand = getTotalDemandMbps(state);
  if (demand <= 0) return 0;
  return Math.min(100, (state.switch.currentDropMbps / demand) * 100);
}

export function getBottleneck(state) {
  if (!state.linkBuilt) return 'offline';
  const demand = getTotalDemandMbps(state);
  const switchCapacity = getSwitchIngressCapacityMbps(state);
  const linkCapacity = state.link.capacityMbps;
  const serverCapacity = state.server.capacityMbps;
  const minimum = Math.min(demand, switchCapacity, linkCapacity, serverCapacity);
  if (minimum >= demand) return 'none';
  if (minimum === switchCapacity) return 'switch';
  if (minimum === linkCapacity) return 'link';
  return 'server';
}

function getUpgradeLevel(state, type) {
  if (type === 'buffer') return state.switch.bufferLevel;
  return state[type].level;
}

export function getUpgradeCost(state, type) {
  const config = UPGRADES[type];
  if (!config) throw new Error(`Unknown upgrade type: ${type}`);
  return Math.round(config.baseCost * config.costGrowth ** getUpgradeLevel(state, type));
}

export function getAddClientCost(state) {
  const addedClients = Math.max(0, state.client.count - 1);
  return Math.round(ECONOMY.addClientBaseCost * ECONOMY.addClientCostGrowth ** addedClients);
}

export function advanceSimulation(state, realDeltaSeconds) {
  if (!Number.isFinite(realDeltaSeconds) || realDeltaSeconds <= 0 || state.simulationSpeed <= 0) return;
  const delta = Math.min(realDeltaSeconds, 0.25) * state.simulationSpeed;
  const arrival = getArrivalMbps(state);
  const serviceCapacity = getServiceCapacityMbps(state);
  let servedMbps = Math.min(arrival, serviceCapacity);
  let droppedMb = 0;

  if (state.switch.built && state.linkBuilt) {
    const availableMb = state.switch.queueMb + arrival * delta;
    const servedMb = Math.min(availableMb, serviceCapacity * delta);
    const queuedBeforeDrop = Math.max(0, availableMb - servedMb);
    droppedMb = Math.max(0, queuedBeforeDrop - state.switch.bufferMb);
    state.switch.queueMb = Math.min(state.switch.bufferMb, queuedBeforeDrop);
    state.switch.currentDropMbps = droppedMb / delta;
    state.switch.totalDroppedMb += droppedMb;
    servedMbps = servedMb / delta;
  } else {
    state.switch.queueMb = 0;
    state.switch.currentDropMbps = 0;
  }

  const revenue = servedMbps * ECONOMY.revenuePerMbpsSecond * delta;
  state.elapsedSeconds += delta;
  state.money += revenue;
  state.stats.lifetimeRevenue += revenue;
  state.stats.lifetimeDataMb += servedMbps * delta;
}
