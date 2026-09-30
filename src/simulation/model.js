export const GAME_VERSION = 6;

export const ECONOMY = Object.freeze({
  startingMoney: 100,
  line1StopBaseCost: 40,
  line1StopCostGrowth: 1.5,
  depotBuildCost: 130,
  line2BuildCost: 220,
  line2StopBaseCost: 75,
  line2StopCostGrowth: 1.55,
  busBaseCost: 70,
  busCostGrowth: 1.4,
  maxLine1Stops: 5,
  maxLine2Stops: 4,
  maxVehiclesPerLine: 8,
  farePerPassenger: 12,
});

export const UPGRADES = Object.freeze({
  shelter1: {
    baseCost: 45,
    costGrowth: 1.6,
    delta: 30,
  },
  catchment1: {
    baseCost: 70,
    costGrowth: 1.7,
    delta: 0.5,
  },
  depot: {
    baseCost: 160,
    costGrowth: 1.8,
    delta: 2,
  },
  shelter2: {
    baseCost: 60,
    costGrowth: 1.65,
    delta: 30,
  },
  catchment2: {
    baseCost: 85,
    costGrowth: 1.7,
    delta: 0.5,
  },
});

export const TRANSPORT_MODES = Object.freeze({
  bus: {
    label: 'Bus',
    unlocked: true,
    vehicleCapacity: 40,
    speedKph: 30,
    dwellMinutes: 0.25,
    turnaroundMinutes: 1,
  },
  tram: {
    label: 'Tram',
    unlocked: false,
    vehicleCapacity: 120,
    speedKph: 35,
    dwellMinutes: 0.35,
    turnaroundMinutes: 1.5,
  },
  metro: {
    label: 'Metro',
    unlocked: false,
    vehicleCapacity: 600,
    speedKph: 55,
    dwellMinutes: 0.45,
    turnaroundMinutes: 2,
  },
  rail: {
    label: 'Rail',
    unlocked: false,
    vehicleCapacity: 400,
    speedKph: 100,
    dwellMinutes: 0.8,
    turnaroundMinutes: 4,
  },
  ferry: {
    label: 'Ferry',
    unlocked: false,
    vehicleCapacity: 250,
    speedKph: 25,
    dwellMinutes: 2,
    turnaroundMinutes: 5,
  },
  air: {
    label: 'Air',
    unlocked: false,
    vehicleCapacity: 180,
    speedKph: 650,
    dwellMinutes: 25,
    turnaroundMinutes: 40,
  },
});

export const STOP_NAMES = Object.freeze({
  line1: [
    'Old Town',
    'Market Square',
    'City Park',
    'University',
    'Central',
  ],
  line2: [
    'City Park',
    'Riverside',
    'Museum',
    'Harbor',
  ],
});

const LINE_CONFIG = Object.freeze({
  line1: {
    segmentLengthKm: 0.9,
    demandPerStopPpm: 2.2,
    starterFleet: 1,
    maxStops: ECONOMY.maxLine1Stops,
  },
  line2: {
    segmentLengthKm: 0.8,
    demandPerStopPpm: 2,
    starterFleet: 1,
    maxStops: ECONOMY.maxLine2Stops,
  },
});

export function createInitialState() {
  return {
    version: GAME_VERSION,
    money: ECONOMY.startingMoney,
    elapsedSeconds: 0,
    simulationSpeed: 1,

    line1: {
      built: false,
      mode: 'bus',
      stopCount: 1,
      fleetCount: 0,
      demandPerStopPpm: LINE_CONFIG.line1.demandPerStopPpm,
      waitingCapacityPassengers: 50,
      queuePassengers: 0,
      currentAbandonmentPpm: 0,
      totalAbandonedPassengers: 0,
      shelterLevel: 0,
      catchmentLevel: 0,
      lastDeliveredPpm: 0,
    },

    depot: {
      built: false,
      garageSlots: 4,
      level: 0,
    },

    line2: {
      built: false,
      mode: 'bus',
      stopCount: 0,
      fleetCount: 0,
      demandPerStopPpm: LINE_CONFIG.line2.demandPerStopPpm,
      waitingCapacityPassengers: 45,
      queuePassengers: 0,
      currentAbandonmentPpm: 0,
      totalAbandonedPassengers: 0,
      shelterLevel: 0,
      catchmentLevel: 0,
      lastDeliveredPpm: 0,
    },

    stats: {
      lifetimeRevenue: 0,
      lifetimePassengers: 0,
    },
  };
}

function getLine(state, lineKey) {
  if (lineKey === 'line1') return state.line1;
  if (lineKey === 'line2') return state.line2;
  throw new Error(`Unknown line: ${lineKey}`);
}

function getLineConfig(lineKey) {
  const config = LINE_CONFIG[lineKey];

  if (!config) {
    throw new Error(`Unknown line: ${lineKey}`);
  }

  return config;
}

export function getLineDemandPpm(state, lineKey) {
  const line = getLine(state, lineKey);

  if (!line.built) return 0;

  const passengerGeneratingStops = Math.max(
    0,
    line.stopCount - 1,
  );

  return (
    passengerGeneratingStops
    * line.demandPerStopPpm
  );
}

export function getTotalDemandPpm(state) {
  return (
    getLineDemandPpm(state, 'line1')
    + getLineDemandPpm(state, 'line2')
  );
}

export function getRouteLengthKm(state, lineKey) {
  const line = getLine(state, lineKey);
  const config = getLineConfig(lineKey);

  return (
    Math.max(0, line.stopCount - 1)
    * config.segmentLengthKm
  );
}

export function getLineOneWayMinutes(state, lineKey) {
  const line = getLine(state, lineKey);

  if (!line.built || line.stopCount < 2) {
    return 0;
  }

  const mode = TRANSPORT_MODES[line.mode];

  const drivingMinutes =
    getRouteLengthKm(state, lineKey)
    / mode.speedKph
    * 60;

  const dwellMinutes =
    line.stopCount * mode.dwellMinutes;

  return drivingMinutes + dwellMinutes;
}

export function getLineCycleMinutes(state, lineKey) {
  const line = getLine(state, lineKey);

  if (!line.built) return 0;

  const mode = TRANSPORT_MODES[line.mode];

  return (
    getLineOneWayMinutes(state, lineKey) * 2
    + mode.turnaroundMinutes
  );
}

export function getLineHeadwayMinutes(state, lineKey) {
  const line = getLine(state, lineKey);

  if (
    !line.built
    || line.fleetCount <= 0
  ) {
    return Number.POSITIVE_INFINITY;
  }

  return (
    getLineCycleMinutes(state, lineKey)
    / line.fleetCount
  );
}

export function getLineFrequencyPerHour(state, lineKey) {
  const headway =
    getLineHeadwayMinutes(state, lineKey);

  if (
    !Number.isFinite(headway)
    || headway <= 0
  ) {
    return 0;
  }

  return 60 / headway;
}

export function getLineCapacityPpm(state, lineKey) {
  const line = getLine(state, lineKey);

  if (
    !line.built
    || line.fleetCount <= 0
  ) {
    return 0;
  }

  const mode = TRANSPORT_MODES[line.mode];
  const cycle =
    getLineCycleMinutes(state, lineKey);

  if (cycle <= 0) return 0;

  return (
    mode.vehicleCapacity
    * line.fleetCount
    / cycle
  );
}

export function getNextStopCost(state, lineKey) {
  const line = getLine(state, lineKey);

  if (lineKey === 'line1') {
    const purchasedStops =
      Math.max(0, line.stopCount - 1);

    return Math.round(
      ECONOMY.line1StopBaseCost
      * ECONOMY.line1StopCostGrowth ** purchasedStops,
    );
  }

  const purchasedExtraStops =
    Math.max(0, line.stopCount - 2);

  return Math.round(
    ECONOMY.line2StopBaseCost
    * ECONOMY.line2StopCostGrowth ** purchasedExtraStops,
  );
}

export function getGarageUsed(state) {
  return (
    state.line1.fleetCount
    + state.line2.fleetCount
  );
}

export function getVehiclePurchaseCost(state) {
  const starterVehicles =
    (state.line1.built ? 1 : 0)
    + (state.line2.built ? 1 : 0);

  const purchasedVehicles = Math.max(
    0,
    getGarageUsed(state) - starterVehicles,
  );

  return Math.round(
    ECONOMY.busBaseCost
    * ECONOMY.busCostGrowth ** purchasedVehicles,
  );
}

export function canBuildDepot(state) {
  return (
    !state.depot.built
    && state.line1.stopCount >= 3
  );
}

export function isLine1Stable(state) {
  return (
    state.line1.built
    && getLineCapacityPpm(state, 'line1')
      >= getLineDemandPpm(state, 'line1')
  );
}

export function canUnlockLine2(state) {
  return (
    !state.line2.built
    && state.depot.built
    && state.line1.stopCount
      >= ECONOMY.maxLine1Stops
    && isLine1Stable(state)
  );
}

function getUpgradeLevel(state, type) {
  if (type === 'shelter1') {
    return state.line1.shelterLevel;
  }

  if (type === 'catchment1') {
    return state.line1.catchmentLevel;
  }

  if (type === 'depot') {
    return state.depot.level;
  }

  if (type === 'shelter2') {
    return state.line2.shelterLevel;
  }

  if (type === 'catchment2') {
    return state.line2.catchmentLevel;
  }

  throw new Error(`Unknown upgrade type: ${type}`);
}

export function getUpgradeCost(state, type) {
  const config = UPGRADES[type];

  if (!config) {
    throw new Error(`Unknown upgrade type: ${type}`);
  }

  return Math.round(
    config.baseCost
    * config.costGrowth
      ** getUpgradeLevel(state, type),
  );
}

export function getDeliveredPassengersPpm(state) {
  return (
    state.line1.lastDeliveredPpm
    + state.line2.lastDeliveredPpm
  );
}

export function getIncomePerSecond(state) {
  return (
    getDeliveredPassengersPpm(state)
    * ECONOMY.farePerPassenger
    / 60
  );
}

export function getAverageWaitMinutes(state) {
  const demand1 =
    getLineDemandPpm(state, 'line1');

  const demand2 =
    getLineDemandPpm(state, 'line2');

  const totalDemand = demand1 + demand2;

  if (totalDemand <= 0) return 0;

  const waitForLine = (
    lineKey,
    demand,
  ) => {
    if (demand <= 0) return 0;

    const line = getLine(state, lineKey);
    const scheduled =
      getLineHeadwayMinutes(state, lineKey) / 2;

    const delivered = Math.max(
      0.1,
      line.lastDeliveredPpm,
    );

    return (
      scheduled
      + line.queuePassengers / delivered
    );
  };

  return Math.min(
    120,
    (
      waitForLine('line1', demand1) * demand1
      + waitForLine('line2', demand2) * demand2
    ) / totalDemand,
  );
}

export function getAbandonmentPercent(state) {
  const demand = getTotalDemandPpm(state);

  if (demand <= 0) return 0;

  const abandonment =
    state.line1.currentAbandonmentPpm
    + state.line2.currentAbandonmentPpm;

  return Math.min(
    100,
    abandonment / demand * 100,
  );
}

export function getBottleneck(state) {
  const demand1 =
    getLineDemandPpm(state, 'line1');

  if (
    demand1
    > getLineCapacityPpm(state, 'line1')
  ) {
    return 'line-1';
  }

  const demand2 =
    getLineDemandPpm(state, 'line2');

  if (
    state.line2.built
    && demand2
      > getLineCapacityPpm(state, 'line2')
  ) {
    return 'line-2';
  }

  return state.line1.built
    ? 'none'
    : 'offline';
}

function simulateLine(
  state,
  lineKey,
  deltaMinutes,
) {
  const line = getLine(state, lineKey);

  if (!line.built) {
    line.queuePassengers = 0;
    line.currentAbandonmentPpm = 0;
    line.lastDeliveredPpm = 0;
    return 0;
  }

  const demandPpm =
    getLineDemandPpm(state, lineKey);

  const capacityPpm =
    getLineCapacityPpm(state, lineKey);

  const availablePassengers =
    line.queuePassengers
    + demandPpm * deltaMinutes;

  const deliveredPassengers = Math.min(
    availablePassengers,
    capacityPpm * deltaMinutes,
  );

  const waitingBeforeAbandonment = Math.max(
    0,
    availablePassengers - deliveredPassengers,
  );

  const abandonedPassengers = Math.max(
    0,
    waitingBeforeAbandonment
    - line.waitingCapacityPassengers,
  );

  line.queuePassengers = Math.min(
    line.waitingCapacityPassengers,
    waitingBeforeAbandonment,
  );

  line.currentAbandonmentPpm =
    deltaMinutes > 0
      ? abandonedPassengers / deltaMinutes
      : 0;

  line.totalAbandonedPassengers +=
    abandonedPassengers;

  line.lastDeliveredPpm =
    deltaMinutes > 0
      ? deliveredPassengers / deltaMinutes
      : 0;

  return line.lastDeliveredPpm;
}

export function advanceSimulation(
  state,
  realDeltaSeconds,
) {
  if (
    !Number.isFinite(realDeltaSeconds)
    || realDeltaSeconds <= 0
    || state.simulationSpeed <= 0
  ) {
    return;
  }

  const deltaSeconds =
    Math.min(realDeltaSeconds, 0.25)
    * state.simulationSpeed;

  const deltaMinutes =
    deltaSeconds / 60;

  const deliveredPpm =
    simulateLine(
      state,
      'line1',
      deltaMinutes,
    )
    + simulateLine(
      state,
      'line2',
      deltaMinutes,
    );

  const deliveredPassengers =
    deliveredPpm * deltaMinutes;

  const revenue =
    deliveredPassengers
    * ECONOMY.farePerPassenger;

  state.elapsedSeconds += deltaSeconds;
  state.money += revenue;
  state.stats.lifetimeRevenue += revenue;
  state.stats.lifetimePassengers +=
    deliveredPassengers;
}
