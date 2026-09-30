export const GAME_VERSION = 5;

export const ECONOMY = Object.freeze({
  startingMoney: 100,
  firstLineBuildCost: 40,
  terminalBuildCost: 95,
  interchangeBuildCost: 220,
  corridorBBuildCost: 180,
  stationBBuildCost: 210,
  addStopABaseCost: 60,
  addStopACostGrowth: 1.5,
  addStopBBaseCost: 85,
  addStopBCostGrowth: 1.55,
  vehicleBaseCost: 55,
  vehicleCostGrowth: 1.45,
  maxStopsA: 4,
  maxStopsB: 4,
  maxVehiclesPerLine: 8,
  farePerPassenger: 12,
});

export const UPGRADES = Object.freeze({
  catchmentA: { baseCost: 25, costGrowth: 1.65, delta: 1 },
  terminalA: { baseCost: 70, costGrowth: 1.75, delta: 5 },
  waitingArea: { baseCost: 55, costGrowth: 1.7, delta: 40 },
  stationA: { baseCost: 45, costGrowth: 1.7, delta: 5 },
  interchange: { baseCost: 120, costGrowth: 1.8, delta: 10 },
  stationB: { baseCost: 110, costGrowth: 1.75, delta: 5 },
});

export const TRANSPORT_MODES = Object.freeze({
  bus: {
    label: 'Bus',
    unlocked: true,
    role: 'Flexible local transport',
    vehicleCapacity: 40,
    speedKph: 30,
    dwellMinutes: 0.25,
    turnaroundMinutes: 1,
  },
  tram: {
    label: 'Tram',
    unlocked: false,
    role: 'High-capacity urban corridor',
    vehicleCapacity: 120,
    speedKph: 35,
    dwellMinutes: 0.35,
    turnaroundMinutes: 1.5,
  },
  metro: {
    label: 'Metro',
    unlocked: false,
    role: 'Very high-capacity rapid transit',
    vehicleCapacity: 600,
    speedKph: 55,
    dwellMinutes: 0.45,
    turnaroundMinutes: 2,
  },
  rail: {
    label: 'Rail',
    unlocked: false,
    role: 'Regional and intercity transport',
    vehicleCapacity: 400,
    speedKph: 100,
    dwellMinutes: 0.8,
    turnaroundMinutes: 4,
  },
  ferry: {
    label: 'Ferry',
    unlocked: false,
    role: 'Water crossings',
    vehicleCapacity: 250,
    speedKph: 25,
    dwellMinutes: 2,
    turnaroundMinutes: 5,
  },
  air: {
    label: 'Air',
    unlocked: false,
    role: 'Long-distance transport',
    vehicleCapacity: 180,
    speedKph: 650,
    dwellMinutes: 25,
    turnaroundMinutes: 40,
  },
});

export const PLACES = Object.freeze({
  corridorA: { label: 'Northside', code: 'LINE 1' },
  corridorB: { label: 'Riverside', code: 'LINE 2' },
  stationA: { label: 'Central Station', code: 'CENTRAL' },
  stationB: { label: 'Harbor Station', code: 'HARBOR' },
});

const LINE_GEOMETRY = Object.freeze({
  corridorA: {
    baseStopCount: 1,
    baseLengthKm: 2.2,
    extraStopLengthKm: 0.75,
    starterFleet: 2,
  },
  corridorB: {
    baseStopCount: 2,
    baseLengthKm: 2.4,
    extraStopLengthKm: 0.75,
    starterFleet: 2,
  },
});

export function createInitialState() {
  return {
    version: GAME_VERSION,
    money: ECONOMY.startingMoney,
    elapsedSeconds: 0,
    simulationSpeed: 1,

    corridorA: {
      lineBuilt: false,
      mode: 'bus',
      stopCount: 1,
      demandPerStopPpm: 4,
      demandLevel: 0,
      fleetCount: 2,
    },

    terminalA: {
      built: false,
      platformCapacityPpm: 14,
      level: 0,
      waitingCapacityPassengers: 60,
      waitingLevel: 0,
      queuePassengers: 0,
      currentAbandonmentPpm: 0,
      totalAbandonedPassengers: 0,
    },

    stationA: {
      capacityPpm: 12,
      level: 0,
    },

    interchange: {
      built: false,
      transferCapacityPpm: 24,
      level: 0,
      waitingCapacityPassengers: 100,
      queuePassengers: 0,
      currentAbandonmentPpm: 0,
      totalAbandonedPassengers: 0,
      destinationQueuesPassengers: {
        primary: 0,
        secondary: 0,
      },
      destinationAbandonmentPpm: {
        primary: 0,
        secondary: 0,
      },
      lastDeliveredPpm: {
        primary: 0,
        secondary: 0,
      },
    },

    corridorB: {
      built: false,
      mode: 'bus',
      stopCount: 2,
      demandPerStopPpm: 3,
      fleetCount: 2,
    },

    stationB: {
      built: false,
      capacityPpm: 12,
      level: 0,
    },

    stats: {
      lifetimeRevenue: 0,
      lifetimePassengers: 0,
    },
  };
}

function getCorridorState(state, corridorKey) {
  if (corridorKey === 'corridorA') return state.corridorA;
  if (corridorKey === 'corridorB') return state.corridorB;
  throw new Error(`Unknown corridor: ${corridorKey}`);
}

export function getRouteLengthKm(state, corridorKey) {
  const corridor = getCorridorState(state, corridorKey);
  const geometry = LINE_GEOMETRY[corridorKey];
  const extraStops = Math.max(
    0,
    corridor.stopCount - geometry.baseStopCount,
  );

  return (
    geometry.baseLengthKm
    + extraStops * geometry.extraStopLengthKm
  );
}

export function getLineOneWayMinutes(state, corridorKey) {
  const corridor = getCorridorState(state, corridorKey);
  const mode = TRANSPORT_MODES[corridor.mode];
  const drivingMinutes =
    getRouteLengthKm(state, corridorKey)
    / mode.speedKph
    * 60;

  const servicedPoints = corridor.stopCount + 1;
  const dwellMinutes = servicedPoints * mode.dwellMinutes;

  return drivingMinutes + dwellMinutes;
}

export function getLineCycleMinutes(state, corridorKey) {
  const corridor = getCorridorState(state, corridorKey);
  const mode = TRANSPORT_MODES[corridor.mode];

  return (
    getLineOneWayMinutes(state, corridorKey) * 2
    + mode.turnaroundMinutes
  );
}

export function getLineHeadwayMinutes(state, corridorKey) {
  const corridor = getCorridorState(state, corridorKey);

  if (corridor.fleetCount <= 0) {
    return Number.POSITIVE_INFINITY;
  }

  return getLineCycleMinutes(state, corridorKey)
    / corridor.fleetCount;
}

export function getLineFrequencyPerHour(state, corridorKey) {
  const headway = getLineHeadwayMinutes(state, corridorKey);

  if (!Number.isFinite(headway) || headway <= 0) {
    return 0;
  }

  return 60 / headway;
}

export function getLineCapacityPpm(state, corridorKey) {
  const corridor = getCorridorState(state, corridorKey);
  const mode = TRANSPORT_MODES[corridor.mode];
  const cycle = getLineCycleMinutes(state, corridorKey);

  if (cycle <= 0) return 0;

  return (
    mode.vehicleCapacity
    * corridor.fleetCount
    / cycle
  );
}

export function getVehiclePurchaseCost(state, corridorKey) {
  const corridor = getCorridorState(state, corridorKey);
  const geometry = LINE_GEOMETRY[corridorKey];
  const purchasedVehicles = Math.max(
    0,
    corridor.fleetCount - geometry.starterFleet,
  );

  return Math.round(
    ECONOMY.vehicleBaseCost
    * ECONOMY.vehicleCostGrowth ** purchasedVehicles,
  );
}

export function getCorridorADemandPpm(state) {
  return state.corridorA.demandPerStopPpm
    * state.corridorA.stopCount;
}

export function getCorridorBDemandPpm(state) {
  if (!state.corridorB.built) return 0;

  return state.corridorB.demandPerStopPpm
    * state.corridorB.stopCount;
}

export function getTotalDemandPpm(state) {
  return getCorridorADemandPpm(state)
    + getCorridorBDemandPpm(state);
}

export function getTerminalAIngressCapacityPpm(state) {
  return state.terminalA.built
    ? state.terminalA.platformCapacityPpm
    : Number.POSITIVE_INFINITY;
}

export function getLocalServiceCapacityPpm(state) {
  if (!state.corridorA.lineBuilt) return 0;

  return Math.min(
    getLineCapacityPpm(state, 'corridorA'),
    state.stationA.capacityPpm,
  );
}

export function getLocalArrivalPpm(state) {
  if (state.interchange.built) {
    return getInterchangeIngressPpm(state);
  }

  return Math.min(
    getCorridorADemandPpm(state),
    getTerminalAIngressCapacityPpm(state),
  );
}

export function getInterchangeIngressPpm(state) {
  if (!state.interchange.built) return 0;

  const corridorA = Math.min(
    getCorridorADemandPpm(state),
    getTerminalAIngressCapacityPpm(state),
    getLineCapacityPpm(state, 'corridorA'),
  );

  const corridorB = state.corridorB.built
    ? Math.min(
      getCorridorBDemandPpm(state),
      getLineCapacityPpm(state, 'corridorB'),
    )
    : 0;

  return corridorA + corridorB;
}

export function getDestinationRatios(state) {
  if (!state.stationB.built) {
    return { primary: 1, secondary: 0 };
  }

  return { primary: 0.6, secondary: 0.4 };
}

export function getStationACapacityPpm(state) {
  return state.stationA.capacityPpm;
}

export function getStationBCapacityPpm(state) {
  if (!state.stationB.built) return 0;
  return state.stationB.capacityPpm;
}

export function getDeliveredPassengersPpm(state) {
  if (!state.corridorA.lineBuilt) return 0;

  if (state.interchange.built) {
    return (
      state.interchange.lastDeliveredPpm.primary
      + state.interchange.lastDeliveredPpm.secondary
    );
  }

  const arrival = getLocalArrivalPpm(state);
  const capacity = getLocalServiceCapacityPpm(state);

  if (
    state.terminalA.built
    && state.terminalA.queuePassengers > 0
  ) {
    return capacity;
  }

  return Math.min(arrival, capacity);
}

export function getIncomePerSecond(state) {
  return (
    getDeliveredPassengersPpm(state)
    * ECONOMY.farePerPassenger
    / 60
  );
}

export function getScheduledWaitMinutes(state) {
  const demandA = getCorridorADemandPpm(state);
  const demandB = getCorridorBDemandPpm(state);
  const totalDemand = demandA + demandB;

  if (totalDemand <= 0) return 0;

  const waitA =
    getLineHeadwayMinutes(state, 'corridorA') / 2;

  const waitB =
    state.corridorB.built
      ? getLineHeadwayMinutes(state, 'corridorB') / 2
      : 0;

  return (
    waitA * demandA
    + waitB * demandB
  ) / totalDemand;
}

export function getAverageWaitMinutes(state) {
  if (!state.corridorA.lineBuilt) return 0;

  const scheduledWait = getScheduledWaitMinutes(state);

  if (state.interchange.built) {
    const delivered = Math.max(
      1,
      getDeliveredPassengersPpm(state),
    );

    const waiting =
      state.interchange.queuePassengers
      + state.interchange.destinationQueuesPassengers.primary
      + state.interchange.destinationQueuesPassengers.secondary;

    return Math.min(
      120,
      scheduledWait + waiting / delivered,
    );
  }

  const service = getLocalServiceCapacityPpm(state);

  if (!state.terminalA.built || service <= 0) {
    return scheduledWait;
  }

  return Math.min(
    120,
    scheduledWait
      + state.terminalA.queuePassengers / service,
  );
}

export function getAbandonmentPercent(state) {
  const demand = getTotalDemandPpm(state);

  if (demand <= 0) return 0;

  const abandonmentPpm = state.interchange.built
    ? (
      state.interchange.currentAbandonmentPpm
      + state.interchange.destinationAbandonmentPpm.primary
      + state.interchange.destinationAbandonmentPpm.secondary
    )
    : state.terminalA.currentAbandonmentPpm;

  return Math.min(
    100,
    abandonmentPpm / demand * 100,
  );
}

export function getBottleneck(state) {
  if (!state.corridorA.lineBuilt) {
    return 'offline';
  }

  if (state.interchange.built) {
    const demandA = getCorridorADemandPpm(state);
    const demandB = getCorridorBDemandPpm(state);

    if (
      demandA
      > getTerminalAIngressCapacityPpm(state)
    ) {
      return 'terminal-a';
    }

    if (
      demandA
      > getLineCapacityPpm(state, 'corridorA')
    ) {
      return 'line-a';
    }

    if (
      state.corridorB.built
      && demandB
        > getLineCapacityPpm(state, 'corridorB')
    ) {
      return 'line-b';
    }

    const ingress = getInterchangeIngressPpm(state);

    if (
      ingress
      > state.interchange.transferCapacityPpm
    ) {
      return 'interchange';
    }

    const ratios = getDestinationRatios(state);

    const transferred = Math.min(
      ingress,
      state.interchange.transferCapacityPpm,
    );

    if (
      transferred * ratios.primary
      > getStationACapacityPpm(state)
    ) {
      return 'station-a';
    }

    if (
      state.stationB.built
      && transferred * ratios.secondary
        > getStationBCapacityPpm(state)
    ) {
      return 'station-b';
    }

    return 'none';
  }

  const demand = getCorridorADemandPpm(state);
  const terminalCapacity =
    getTerminalAIngressCapacityPpm(state);
  const lineCapacity =
    getLineCapacityPpm(state, 'corridorA');
  const stationCapacity =
    state.stationA.capacityPpm;

  const minimum = Math.min(
    demand,
    terminalCapacity,
    lineCapacity,
    stationCapacity,
  );

  if (minimum >= demand) return 'none';
  if (minimum === terminalCapacity) return 'terminal-a';
  if (minimum === lineCapacity) return 'line-a';

  return 'station-a';
}

function getUpgradeLevel(state, type) {
  if (type === 'catchmentA') {
    return state.corridorA.demandLevel;
  }

  if (type === 'terminalA') {
    return state.terminalA.level;
  }

  if (type === 'waitingArea') {
    return state.terminalA.waitingLevel;
  }

  if (type === 'stationA') {
    return state.stationA.level;
  }

  if (type === 'interchange') {
    return state.interchange.level;
  }

  if (type === 'stationB') {
    return state.stationB.level;
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
    * config.costGrowth ** getUpgradeLevel(state, type),
  );
}

export function getAddStopACost(state) {
  const addedStops = Math.max(
    0,
    state.corridorA.stopCount - 1,
  );

  return Math.round(
    ECONOMY.addStopABaseCost
    * ECONOMY.addStopACostGrowth ** addedStops,
  );
}

export function getAddStopBCost(state) {
  const addedStops = Math.max(
    0,
    state.corridorB.stopCount - 2,
  );

  return Math.round(
    ECONOMY.addStopBBaseCost
    * ECONOMY.addStopBCostGrowth ** addedStops,
  );
}

export function getServiceBoard(state) {
  const lineA = {
    destination: PLACES.stationA.label,
    service: '1',
    mode: TRANSPORT_MODES[state.corridorA.mode].label,
    headwayMinutes: getLineHeadwayMinutes(
      state,
      'corridorA',
    ),
    fleetCount: state.corridorA.fleetCount,
    active: state.corridorA.lineBuilt,
  };

  const services = [lineA];

  if (state.corridorB.built) {
    services.push({
      destination: state.stationB.built
        ? PLACES.stationB.label
        : PLACES.corridorB.label,
      service: '2',
      mode: TRANSPORT_MODES[state.corridorB.mode].label,
      headwayMinutes: getLineHeadwayMinutes(
        state,
        'corridorB',
      ),
      fleetCount: state.corridorB.fleetCount,
      active: true,
    });
  }

  return services;
}

function simulateLocalCorridor(state, deltaMinutes) {
  const arrivalPpm = getLocalArrivalPpm(state);
  const serviceCapacityPpm =
    getLocalServiceCapacityPpm(state);

  let deliveredPpm = Math.min(
    arrivalPpm,
    serviceCapacityPpm,
  );

  if (
    state.terminalA.built
    && state.corridorA.lineBuilt
  ) {
    const availablePassengers =
      state.terminalA.queuePassengers
      + arrivalPpm * deltaMinutes;

    const deliveredPassengers = Math.min(
      availablePassengers,
      serviceCapacityPpm * deltaMinutes,
    );

    const waitingBeforeAbandonment = Math.max(
      0,
      availablePassengers - deliveredPassengers,
    );

    const abandonedPassengers = Math.max(
      0,
      waitingBeforeAbandonment
      - state.terminalA.waitingCapacityPassengers,
    );

    state.terminalA.queuePassengers = Math.min(
      state.terminalA.waitingCapacityPassengers,
      waitingBeforeAbandonment,
    );

    state.terminalA.currentAbandonmentPpm =
      deltaMinutes > 0
        ? abandonedPassengers / deltaMinutes
        : 0;

    state.terminalA.totalAbandonedPassengers +=
      abandonedPassengers;

    deliveredPpm =
      deltaMinutes > 0
        ? deliveredPassengers / deltaMinutes
        : 0;
  } else {
    state.terminalA.queuePassengers = 0;
    state.terminalA.currentAbandonmentPpm = 0;
  }

  return deliveredPpm;
}

function simulateInterchange(state, deltaMinutes) {
  const ingressPpm = getInterchangeIngressPpm(state);

  const availablePassengers =
    state.interchange.queuePassengers
    + ingressPpm * deltaMinutes;

  const transferredPassengers = Math.min(
    availablePassengers,
    state.interchange.transferCapacityPpm
      * deltaMinutes,
  );

  const waitingBeforeAbandonment = Math.max(
    0,
    availablePassengers - transferredPassengers,
  );

  const abandonedPassengers = Math.max(
    0,
    waitingBeforeAbandonment
    - state.interchange.waitingCapacityPassengers,
  );

  state.interchange.queuePassengers = Math.min(
    state.interchange.waitingCapacityPassengers,
    waitingBeforeAbandonment,
  );

  state.interchange.currentAbandonmentPpm =
    deltaMinutes > 0
      ? abandonedPassengers / deltaMinutes
      : 0;

  state.interchange.totalAbandonedPassengers +=
    abandonedPassengers;

  const transferredPpm =
    deltaMinutes > 0
      ? transferredPassengers / deltaMinutes
      : 0;

  const ratios = getDestinationRatios(state);

  const perDestinationWaitingCapacity =
    state.interchange.waitingCapacityPassengers / 2;

  const processDestination = (
    key,
    incomingPpm,
    capacityPpm,
  ) => {
    const destinationAvailable =
      state.interchange.destinationQueuesPassengers[key]
      + incomingPpm * deltaMinutes;

    const deliveredPassengers = Math.min(
      destinationAvailable,
      capacityPpm * deltaMinutes,
    );

    const destinationWaitingBeforeAbandonment =
      Math.max(
        0,
        destinationAvailable - deliveredPassengers,
      );

    const destinationAbandonedPassengers =
      Math.max(
        0,
        destinationWaitingBeforeAbandonment
        - perDestinationWaitingCapacity,
      );

    state.interchange.destinationQueuesPassengers[key] =
      Math.min(
        perDestinationWaitingCapacity,
        destinationWaitingBeforeAbandonment,
      );

    state.interchange.destinationAbandonmentPpm[key] =
      deltaMinutes > 0
        ? destinationAbandonedPassengers / deltaMinutes
        : 0;

    state.interchange.totalAbandonedPassengers +=
      destinationAbandonedPassengers;

    state.interchange.lastDeliveredPpm[key] =
      deltaMinutes > 0
        ? deliveredPassengers / deltaMinutes
        : 0;
  };

  processDestination(
    'primary',
    transferredPpm * ratios.primary,
    getStationACapacityPpm(state),
  );

  processDestination(
    'secondary',
    transferredPpm * ratios.secondary,
    getStationBCapacityPpm(state),
  );

  return (
    state.interchange.lastDeliveredPpm.primary
    + state.interchange.lastDeliveredPpm.secondary
  );
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
    state.interchange.built
      ? simulateInterchange(state, deltaMinutes)
      : simulateLocalCorridor(state, deltaMinutes);

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
