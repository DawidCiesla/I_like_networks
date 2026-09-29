export const GAME_VERSION = 3;

export const ECONOMY = Object.freeze({
  startingMoney: 100,
  ethernetBuildCost: 40,
  switchBuildCost: 95,
  routerBuildCost: 220,
  branchNetworkCost: 180,
  secondaryServerCost: 210,
  addClientBaseCost: 60,
  addClientCostGrowth: 1.5,
  addBranchClientBaseCost: 85,
  addBranchClientCostGrowth: 1.55,
  maxClients: 4,
  maxBranchClients: 4,
  revenuePerMbpsSecond: 0.16,
});

export const UPGRADES = Object.freeze({
  client: { baseCost: 25, costGrowth: 1.65, delta: 5 },
  link: { baseCost: 35, costGrowth: 1.7, delta: 20 },
  switch: { baseCost: 70, costGrowth: 1.75, delta: 25 },
  buffer: { baseCost: 55, costGrowth: 1.7, delta: 40 },
  server: { baseCost: 45, costGrowth: 1.7, delta: 15 },
  router: { baseCost: 120, costGrowth: 1.8, delta: 40 },
  branch: { baseCost: 95, costGrowth: 1.75, delta: 20 },
  server2: { baseCost: 110, costGrowth: 1.75, delta: 20 },
});

export const NETWORKS = Object.freeze({
  lanA: { cidr: '10.0.1.0/24', label: 'LAN A' },
  lanB: { cidr: '10.0.2.0/24', label: 'LAN B' },
  serverA: { cidr: '10.0.10.0/24', label: 'SERVER NET A' },
  serverB: { cidr: '10.0.20.0/24', label: 'SERVER NET B' },
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
    router: {
      built: false,
      capacityMbps: 60,
      level: 0,
      bufferMb: 120,
      queueMb: 0,
      currentDropMbps: 0,
      totalDroppedMb: 0,
      routeQueuesMb: { primary: 0, secondary: 0 },
      routeDropsMbps: { primary: 0, secondary: 0 },
      lastThroughputMbps: { primary: 0, secondary: 0 },
    },
    branch: {
      built: false,
      clientCount: 2,
      clientTrafficMbps: 8,
      linkCapacityMbps: 30,
      level: 0,
    },
    secondaryServer: {
      built: false,
      capacityMbps: 30,
      level: 0,
      linkCapacityMbps: 30,
    },
    stats: { lifetimeRevenue: 0, lifetimeDataMb: 0 },
  };
}

export function getPrimaryDemandMbps(state) {
  return state.client.trafficMbps * state.client.count;
}

export function getBranchDemandMbps(state) {
  if (!state.branch.built) return 0;
  return state.branch.clientTrafficMbps * state.branch.clientCount;
}

export function getTotalDemandMbps(state) {
  return getPrimaryDemandMbps(state) + getBranchDemandMbps(state);
}

export function getSwitchIngressCapacityMbps(state) {
  return state.switch.built ? state.switch.capacityMbps : Number.POSITIVE_INFINITY;
}

export function getServiceCapacityMbps(state) {
  if (!state.linkBuilt) return 0;
  return Math.min(state.link.capacityMbps, state.server.capacityMbps);
}

export function getArrivalMbps(state) {
  if (state.router.built) return getRouterIngressMbps(state);
  return Math.min(getPrimaryDemandMbps(state), getSwitchIngressCapacityMbps(state));
}

export function getRouterIngressMbps(state) {
  if (!state.router.built) return 0;
  const lanA = Math.min(
    getPrimaryDemandMbps(state),
    getSwitchIngressCapacityMbps(state),
    state.link.capacityMbps,
  );
  const lanB = state.branch.built
    ? Math.min(getBranchDemandMbps(state), state.branch.linkCapacityMbps)
    : 0;
  return lanA + lanB;
}

export function getDestinationRatios(state) {
  if (!state.secondaryServer.built) return { primary: 1, secondary: 0 };
  return { primary: 0.6, secondary: 0.4 };
}

export function getPrimaryRouteCapacityMbps(state) {
  return state.server.capacityMbps;
}

export function getSecondaryRouteCapacityMbps(state) {
  if (!state.secondaryServer.built) return 0;
  return Math.min(
    state.secondaryServer.capacityMbps,
    state.secondaryServer.linkCapacityMbps,
  );
}

export function getThroughputMbps(state) {
  if (!state.linkBuilt) return 0;
  if (state.router.built) {
    return state.router.lastThroughputMbps.primary + state.router.lastThroughputMbps.secondary;
  }
  const arrival = getArrivalMbps(state);
  const serviceCapacity = getServiceCapacityMbps(state);
  if (state.switch.built && state.switch.queueMb > 0) return serviceCapacity;
  return Math.min(arrival, serviceCapacity);
}

export function getIncomePerSecond(state) {
  return getThroughputMbps(state) * ECONOMY.revenuePerMbpsSecond;
}

export function getUtilization(state) {
  if (state.router.built) {
    if (state.router.capacityMbps <= 0) return 0;
    return Math.min(1, getRouterIngressMbps(state) / state.router.capacityMbps);
  }
  const serviceCapacity = getServiceCapacityMbps(state);
  if (serviceCapacity <= 0) return 0;
  return Math.min(1, getThroughputMbps(state) / serviceCapacity);
}

export function getQueueFillRatio(state) {
  if (state.router.built) {
    if (state.router.bufferMb <= 0) return 0;
    return Math.min(1, state.router.queueMb / state.router.bufferMb);
  }
  if (!state.switch.built || state.switch.bufferMb <= 0) return 0;
  return Math.min(1, state.switch.queueMb / state.switch.bufferMb);
}

export function getRouteQueueFillRatio(state, destination) {
  if (!state.router.built || state.router.bufferMb <= 0) return 0;
  const perRouteBuffer = state.router.bufferMb / 2;
  return Math.min(1, state.router.routeQueuesMb[destination] / perRouteBuffer);
}

export function getLatencyMs(state) {
  if (!state.linkBuilt) return 0;
  if (state.router.built) {
    const throughput = Math.max(1, getThroughputMbps(state));
    const queued = state.router.queueMb
      + state.router.routeQueuesMb.primary
      + state.router.routeQueuesMb.secondary;
    return Math.min(5000, 8 + (queued / throughput) * 1000);
  }
  const serviceCapacity = getServiceCapacityMbps(state);
  if (!state.switch.built || serviceCapacity <= 0) return 4;
  const queueDelayMs = (state.switch.queueMb / serviceCapacity) * 1000;
  return Math.min(5000, 4 + queueDelayMs);
}

export function getPacketLossPercent(state) {
  const demand = getTotalDemandMbps(state);
  if (demand <= 0) return 0;
  const dropMbps = state.router.built
    ? state.router.currentDropMbps
      + state.router.routeDropsMbps.primary
      + state.router.routeDropsMbps.secondary
    : state.switch.currentDropMbps;
  return Math.min(100, (dropMbps / demand) * 100);
}

export function getBottleneck(state) {
  if (!state.linkBuilt) return 'offline';

  if (state.router.built) {
    const lanA = getPrimaryDemandMbps(state);
    const lanB = getBranchDemandMbps(state);
    if (lanA > getSwitchIngressCapacityMbps(state)) return 'switch-a';
    if (lanA > state.link.capacityMbps) return 'uplink-a';
    if (state.branch.built && lanB > state.branch.linkCapacityMbps) return 'uplink-b';

    const ingress = getRouterIngressMbps(state);
    if (ingress > state.router.capacityMbps) return 'router';

    const ratios = getDestinationRatios(state);
    const routed = Math.min(ingress, state.router.capacityMbps);
    if (routed * ratios.primary > getPrimaryRouteCapacityMbps(state)) return 'server-a';
    if (
      state.secondaryServer.built
      && routed * ratios.secondary > getSecondaryRouteCapacityMbps(state)
    ) return 'server-b';

    return 'none';
  }

  const demand = getPrimaryDemandMbps(state);
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
  if (type === 'server2') return state.secondaryServer.level;
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

export function getAddBranchClientCost(state) {
  const addedClients = Math.max(0, state.branch.clientCount - 2);
  return Math.round(
    ECONOMY.addBranchClientBaseCost * ECONOMY.addBranchClientCostGrowth ** addedClients,
  );
}

export function getRouteTable(state) {
  const routes = [
    {
      destination: NETWORKS.lanA.cidr,
      label: NETWORKS.lanA.label,
      nextHop: 'DIRECT',
      active: state.router.built,
    },
    {
      destination: NETWORKS.serverA.cidr,
      label: NETWORKS.serverA.label,
      nextHop: 'PORT 2',
      active: state.router.built,
    },
  ];

  if (state.branch.built) {
    routes.push({
      destination: NETWORKS.lanB.cidr,
      label: NETWORKS.lanB.label,
      nextHop: 'PORT 3',
      active: true,
    });
  }

  if (state.secondaryServer.built) {
    routes.push({
      destination: NETWORKS.serverB.cidr,
      label: NETWORKS.serverB.label,
      nextHop: 'PORT 4',
      active: true,
    });
  }

  return routes;
}

function simulateLegacyNetwork(state, delta) {
  const arrival = getArrivalMbps(state);
  const serviceCapacity = getServiceCapacityMbps(state);
  let servedMbps = Math.min(arrival, serviceCapacity);

  if (state.switch.built && state.linkBuilt) {
    const availableMb = state.switch.queueMb + arrival * delta;
    const servedMb = Math.min(availableMb, serviceCapacity * delta);
    const queuedBeforeDrop = Math.max(0, availableMb - servedMb);
    const droppedMb = Math.max(0, queuedBeforeDrop - state.switch.bufferMb);
    state.switch.queueMb = Math.min(state.switch.bufferMb, queuedBeforeDrop);
    state.switch.currentDropMbps = droppedMb / delta;
    state.switch.totalDroppedMb += droppedMb;
    servedMbps = servedMb / delta;
  } else {
    state.switch.queueMb = 0;
    state.switch.currentDropMbps = 0;
  }

  return servedMbps;
}

function simulateRoutedNetwork(state, delta) {
  const ingress = getRouterIngressMbps(state);

  const routerAvailableMb = state.router.queueMb + ingress * delta;
  const routerServedMb = Math.min(routerAvailableMb, state.router.capacityMbps * delta);
  const routerQueuedBeforeDrop = Math.max(0, routerAvailableMb - routerServedMb);
  const routerDroppedMb = Math.max(0, routerQueuedBeforeDrop - state.router.bufferMb);

  state.router.queueMb = Math.min(state.router.bufferMb, routerQueuedBeforeDrop);
  state.router.currentDropMbps = routerDroppedMb / delta;
  state.router.totalDroppedMb += routerDroppedMb;

  const routedMbps = routerServedMb / delta;
  const ratios = getDestinationRatios(state);
  const routeBufferMb = state.router.bufferMb / 2;

  const processRoute = (key, incomingMbps, capacityMbps) => {
    const availableMb = state.router.routeQueuesMb[key] + incomingMbps * delta;
    const servedMb = Math.min(availableMb, capacityMbps * delta);
    const queuedBeforeDrop = Math.max(0, availableMb - servedMb);
    const droppedMb = Math.max(0, queuedBeforeDrop - routeBufferMb);

    state.router.routeQueuesMb[key] = Math.min(routeBufferMb, queuedBeforeDrop);
    state.router.routeDropsMbps[key] = droppedMb / delta;
    state.router.totalDroppedMb += droppedMb;
    state.router.lastThroughputMbps[key] = servedMb / delta;
  };

  processRoute(
    'primary',
    routedMbps * ratios.primary,
    getPrimaryRouteCapacityMbps(state),
  );

  processRoute(
    'secondary',
    routedMbps * ratios.secondary,
    getSecondaryRouteCapacityMbps(state),
  );

  return state.router.lastThroughputMbps.primary + state.router.lastThroughputMbps.secondary;
}

export function advanceSimulation(state, realDeltaSeconds) {
  if (
    !Number.isFinite(realDeltaSeconds)
    || realDeltaSeconds <= 0
    || state.simulationSpeed <= 0
  ) return;

  const delta = Math.min(realDeltaSeconds, 0.25) * state.simulationSpeed;

  const servedMbps = state.router.built
    ? simulateRoutedNetwork(state, delta)
    : simulateLegacyNetwork(state, delta);

  const revenue = servedMbps * ECONOMY.revenuePerMbpsSecond * delta;

  state.elapsedSeconds += delta;
  state.money += revenue;
  state.stats.lifetimeRevenue += revenue;
  state.stats.lifetimeDataMb += servedMbps * delta;
}
