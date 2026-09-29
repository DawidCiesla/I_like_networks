export const GAME_VERSION = 1;

export const ECONOMY = Object.freeze({
  startingMoney: 100,
  ethernetBuildCost: 40,
  revenuePerMbpsSecond: 0.16,
});

export const UPGRADES = Object.freeze({
  client: { baseCost: 25, costGrowth: 1.65, delta: 5 },
  link: { baseCost: 35, costGrowth: 1.7, delta: 20 },
  server: { baseCost: 45, costGrowth: 1.7, delta: 15 },
});

export function createInitialState() {
  return {
    version: GAME_VERSION,
    money: ECONOMY.startingMoney,
    elapsedSeconds: 0,
    simulationSpeed: 1,
    linkBuilt: false,
    client: { trafficMbps: 10, level: 0 },
    link: { capacityMbps: 20, level: 0 },
    server: { capacityMbps: 25, level: 0 },
    stats: { lifetimeRevenue: 0, lifetimeDataMb: 0 },
  };
}

export function getThroughputMbps(state) {
  if (!state.linkBuilt) return 0;
  return Math.min(state.client.trafficMbps, state.link.capacityMbps, state.server.capacityMbps);
}

export function getIncomePerSecond(state) {
  return getThroughputMbps(state) * ECONOMY.revenuePerMbpsSecond;
}

export function getUtilization(state) {
  if (!state.linkBuilt || state.link.capacityMbps <= 0) return 0;
  return getThroughputMbps(state) / state.link.capacityMbps;
}

export function getUpgradeCost(state, type) {
  const config = UPGRADES[type];
  if (!config) throw new Error(`Unknown upgrade type: ${type}`);
  const level = state[type].level;
  return Math.round(config.baseCost * config.costGrowth ** level);
}

export function advanceSimulation(state, realDeltaSeconds) {
  if (!Number.isFinite(realDeltaSeconds) || realDeltaSeconds <= 0 || state.simulationSpeed <= 0) return;
  const delta = Math.min(realDeltaSeconds, 0.25) * state.simulationSpeed;
  const throughput = getThroughputMbps(state);
  const revenue = throughput * ECONOMY.revenuePerMbpsSecond * delta;
  state.elapsedSeconds += delta;
  state.money += revenue;
  state.stats.lifetimeRevenue += revenue;
  state.stats.lifetimeDataMb += throughput * delta;
}
