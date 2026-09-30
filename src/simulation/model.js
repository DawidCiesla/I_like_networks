import {
  advanceCitySimulation,
  createInitialCityState,
  ensureCityRuntime,
} from '../city/cityModel.js';

export const GAME_VERSION = 10;

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

const GAME_MINUTES_PER_REAL_SECOND = 0.25;
const DELIVERY_RATE_WINDOW_MINUTES = 0.5;
const BOARDING_HOLD_MINUTES = 0.18;

const LINE_CONFIG = Object.freeze({
  line1: {
    segmentLengthKm: 0.9,
    demandPerStopPpm: 3.2,
    maxStops: ECONOMY.maxLine1Stops,
  },
  line2: {
    segmentLengthKm: 0.8,
    demandPerStopPpm: 2.8,
    maxStops: ECONOMY.maxLine2Stops,
  },
});

function createWaitingMatrix(maxStops) {
  return Array.from(
    { length: maxStops },
    () => Array(maxStops).fill(0),
  );
}

function createLineState(lineKey) {
  const config = LINE_CONFIG[lineKey];

  return {
    built: false,
    mode: 'bus',
    stopCount: lineKey === 'line1' ? 1 : 0,
    fleetCount: 0,
    demandPerStopPpm: config.demandPerStopPpm,
    waitingCapacityPassengers: lineKey === 'line1' ? 50 : 45,
    waitingByStop: createWaitingMatrix(config.maxStops),
    queuePassengers: 0,
    currentAbandonmentPpm: 0,
    totalAbandonedPassengers: 0,
    shelterLevel: 0,
    catchmentLevel: 0,
    lastDeliveredPpm: 0,
    vehicles: [],
    nextVehicleId: 1,
    eventSerial: 0,
    lastPassengerEvent: null,
    passengerEvents: [],
  };
}

export function createInitialState() {
  return {
    version: GAME_VERSION,
    money: ECONOMY.startingMoney,
    elapsedSeconds: 0,
    simulationSpeed: 1,

    city: createInitialCityState(),

    line1: createLineState('line1'),

    depot: {
      built: false,
      garageSlots: 4,
      level: 0,
    },

    line2: createLineState('line2'),

    stats: {
      lifetimeRevenue: 0,
      lifetimePassengers: 0,
      lastFareEventValue: 0,
      lastFareEventSerial: 0,
      lastFareLine: null,
      lastFareStopIndex: null,
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

function getMaxStops(lineKey) {
  return getLineConfig(lineKey).maxStops;
}

function getMode(state, lineKey) {
  const line = getLine(state, lineKey);
  return TRANSPORT_MODES[line.mode];
}

function getSegmentTravelMinutes(state, lineKey) {
  const mode = getMode(state, lineKey);
  const config = getLineConfig(lineKey);

  return (
    config.segmentLengthKm
    / mode.speedKph
    * 60
  );
}

function getStopDwellMinutes(state, lineKey, stopIndex) {
  const line = getLine(state, lineKey);
  const mode = getMode(state, lineKey);
  const isEndpoint =
    stopIndex === 0
    || stopIndex === line.stopCount - 1;

  return (
    mode.dwellMinutes
    + (isEndpoint ? mode.turnaroundMinutes / 2 : 0)
  );
}

function createVehicle(state, lineKey) {
  const line = getLine(state, lineKey);
  const maxStops = getMaxStops(lineKey);
  const id = line.nextVehicleId;

  line.nextVehicleId += 1;

  return {
    id,
    currentStopIndex: 0,
    nextStopIndex: Math.min(1, line.stopCount - 1),
    direction: 1,
    phase: 'dwell',
    phaseMinutesRemaining: getStopDwellMinutes(
      state,
      lineKey,
      0,
    ),
    phaseDurationMinutes: getStopDwellMinutes(
      state,
      lineKey,
      0,
    ),
    onboardByDestination: Array(maxStops).fill(0),
    onboardPassengers: 0,
  };
}

export function initializeLineService(state, lineKey, fleetCount = 1) {
  const line = getLine(state, lineKey);

  line.built = true;
  line.vehicles = [];
  line.fleetCount = 0;
  line.nextVehicleId = 1;

  for (let index = 0; index < fleetCount; index += 1) {
    addVehicleToLineState(state, lineKey);
  }
}

export function addVehicleToLineState(state, lineKey) {
  const line = getLine(state, lineKey);

  if (!line.built) {
    throw new Error(`Cannot add vehicle to inactive line: ${lineKey}`);
  }

  const vehicle = createVehicle(state, lineKey);

  line.vehicles.push(vehicle);
  line.fleetCount = line.vehicles.length;

  return vehicle;
}

export function ensureLineRuntime(state, lineKey) {
  const line = getLine(state, lineKey);
  const maxStops = getMaxStops(lineKey);

  if (!Array.isArray(line.waitingByStop)) {
    line.waitingByStop = createWaitingMatrix(maxStops);
  }

  while (line.waitingByStop.length < maxStops) {
    line.waitingByStop.push(Array(maxStops).fill(0));
  }

  line.waitingByStop = line.waitingByStop
    .slice(0, maxStops)
    .map((row) => {
      const next = Array(maxStops).fill(0);

      if (Array.isArray(row)) {
        for (
          let index = 0;
          index < Math.min(maxStops, row.length);
          index += 1
        ) {
          next[index] = Number.isFinite(row[index])
            ? Math.max(0, row[index])
            : 0;
        }
      }

      return next;
    });

  if (!Array.isArray(line.vehicles)) {
    line.vehicles = [];
  }

  if (!Number.isFinite(line.nextVehicleId)) {
    line.nextVehicleId = 1;
  }

  if (!Number.isFinite(line.eventSerial)) {
    line.eventSerial = 0;
  }

  if (line.lastPassengerEvent === undefined) {
    line.lastPassengerEvent = null;
  }

  if (!Array.isArray(line.passengerEvents)) {
    line.passengerEvents = [];
  }

  if (line.built && line.vehicles.length === 0) {
    const targetFleet = Math.max(1, line.fleetCount || 1);

    line.fleetCount = 0;

    for (let index = 0; index < targetFleet; index += 1) {
      addVehicleToLineState(state, lineKey);
    }
  } else {
    line.fleetCount = line.vehicles.length;
  }

  line.queuePassengers = getLineWaitingPassengers(state, lineKey);
}

export function getLineDemandPpm(state, lineKey) {
  const line = getLine(state, lineKey);

  if (!line.built || line.stopCount < 2) return 0;

  return (
    line.stopCount
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

  const mode = getMode(state, lineKey);

  const drivingMinutes =
    getRouteLengthKm(state, lineKey)
    / mode.speedKph
    * 60;

  const intermediateDwell =
    Math.max(0, line.stopCount - 1)
    * mode.dwellMinutes;

  return (
    drivingMinutes
    + intermediateDwell
    + mode.turnaroundMinutes / 2
  );
}

export function getLineCycleMinutes(state, lineKey) {
  const line = getLine(state, lineKey);

  if (!line.built || line.stopCount < 2) {
    return 0;
  }

  const mode = getMode(state, lineKey);

  const drivingMinutes =
    getRouteLengthKm(state, lineKey)
    / mode.speedKph
    * 60
    * 2;

  const dwellMinutes =
    Math.max(0, line.stopCount - 1)
    * mode.dwellMinutes
    * 2;

  return (
    drivingMinutes
    + dwellMinutes
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

  const mode = getMode(state, lineKey);
  const cycle =
    getLineCycleMinutes(state, lineKey);

  if (cycle <= 0) return 0;

  return (
    mode.vehicleCapacity
    * line.fleetCount
    * 2
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
    && getGarageUsed(state)
      < state.depot.garageSlots
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

export function getStopWaitingPassengers(state, lineKey, stopIndex) {
  const line = getLine(state, lineKey);

  if (!Array.isArray(line.waitingByStop?.[stopIndex])) {
    return 0;
  }

  return line.waitingByStop[stopIndex]
    .slice(0, line.stopCount)
    .reduce(
      (sum, value) => sum + (Number.isFinite(value) ? value : 0),
      0,
    );
}

export function getLineWaitingPassengers(state, lineKey) {
  const line = getLine(state, lineKey);
  let total = 0;

  for (let stopIndex = 0; stopIndex < line.stopCount; stopIndex += 1) {
    total += getStopWaitingPassengers(
      state,
      lineKey,
      stopIndex,
    );
  }

  return total;
}

export function getVehicleOnboardPassengers(vehicle) {
  if (Number.isFinite(vehicle?.onboardPassengers)) {
    return vehicle.onboardPassengers;
  }

  if (!Array.isArray(vehicle?.onboardByDestination)) {
    return 0;
  }

  return vehicle.onboardByDestination.reduce(
    (sum, value) => sum + (Number.isFinite(value) ? value : 0),
    0,
  );
}

export function getLineOnboardPassengers(state, lineKey) {
  const line = getLine(state, lineKey);

  return line.vehicles.reduce(
    (sum, vehicle) =>
      sum + getVehicleOnboardPassengers(vehicle),
    0,
  );
}

export function getDeliveredPassengersPpm(state) {
  return (
    state.line1.lastDeliveredPpm
    + state.line2.lastDeliveredPpm
  );
}

export function getLastFareEventValue(state) {
  return state.stats.lastFareEventValue ?? 0;
}

export function getAverageWaitMinutes(state) {
  const demand1 =
    getLineDemandPpm(state, 'line1');

  const demand2 =
    getLineDemandPpm(state, 'line2');

  const totalDemand = demand1 + demand2;

  if (totalDemand <= 0) return 0;

  const waitForLine = (lineKey, demand) => {
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

function generatePassengers(
  state,
  lineKey,
  deltaMinutes,
) {
  const line = getLine(state, lineKey);

  if (!line.built || line.stopCount < 2) {
    line.currentAbandonmentPpm = 0;
    return;
  }

  const perDestinationRate =
    line.demandPerStopPpm
    / (line.stopCount - 1);

  let abandoned = 0;

  for (
    let origin = 0;
    origin < line.stopCount;
    origin += 1
  ) {
    for (
      let destination = 0;
      destination < line.stopCount;
      destination += 1
    ) {
      if (origin === destination) continue;

      line.waitingByStop[origin][destination] +=
        perDestinationRate * deltaMinutes;
    }

    const waiting =
      getStopWaitingPassengers(
        state,
        lineKey,
        origin,
      );

    if (
      waiting
      > line.waitingCapacityPassengers
    ) {
      const keepRatio =
        line.waitingCapacityPassengers
        / waiting;

      const excess =
        waiting - line.waitingCapacityPassengers;

      abandoned += excess;

      for (
        let destination = 0;
        destination < line.stopCount;
        destination += 1
      ) {
        line.waitingByStop[origin][destination] *=
          keepRatio;
      }
    }
  }

  line.currentAbandonmentPpm =
    deltaMinutes > 0
      ? abandoned / deltaMinutes
      : 0;

  line.totalAbandonedPassengers += abandoned;
  line.queuePassengers =
    getLineWaitingPassengers(state, lineKey);
}

function emitPassengerEvent(
  line,
  type,
  stopIndex,
  vehicleId,
  count,
  fare = 0,
) {
  if (count <= 0) return;

  line.eventSerial += 1;
  line.lastPassengerEvent = {
    serial: line.eventSerial,
    type,
    stopIndex,
    vehicleId,
    count,
    fare,
  };

  line.passengerEvents.push(
    line.lastPassengerEvent,
  );

  if (line.passengerEvents.length > 24) {
    line.passengerEvents.splice(
      0,
      line.passengerEvents.length - 24,
    );
  }
}

function unloadAtStop(
  state,
  lineKey,
  vehicle,
  stopIndex,
) {
  const line = getLine(state, lineKey);

  const alighting =
    vehicle.onboardByDestination[stopIndex] ?? 0;

  if (alighting <= 0) return 0;

  vehicle.onboardByDestination[stopIndex] = 0;
  vehicle.onboardPassengers = Math.max(
    0,
    vehicle.onboardPassengers - alighting,
  );

  const fare =
    alighting * ECONOMY.farePerPassenger;

  state.money += fare;
  state.stats.lifetimeRevenue += fare;
  state.stats.lifetimePassengers += alighting;
  state.stats.lastFareEventValue = fare;
  state.stats.lastFareEventSerial += 1;
  state.stats.lastFareLine = lineKey;
  state.stats.lastFareStopIndex = stopIndex;

  line.lastDeliveredPpm +=
    alighting / DELIVERY_RATE_WINDOW_MINUTES;

  emitPassengerEvent(
    line,
    'alight',
    stopIndex,
    vehicle.id,
    alighting,
    fare,
  );

  return alighting;
}

function boardAtStop(
  state,
  lineKey,
  vehicle,
) {
  const line = getLine(state, lineKey);
  const mode = getMode(state, lineKey);

  const stopIndex =
    vehicle.currentStopIndex;

  let availableSpace =
    mode.vehicleCapacity
    - vehicle.onboardPassengers;

  if (availableSpace <= 0) return 0;

  const destinationIndexes = [];

  if (vehicle.direction > 0) {
    for (
      let destination = stopIndex + 1;
      destination < line.stopCount;
      destination += 1
    ) {
      destinationIndexes.push(destination);
    }
  } else {
    for (
      let destination = stopIndex - 1;
      destination >= 0;
      destination -= 1
    ) {
      destinationIndexes.push(destination);
    }
  }

  let boarded = 0;

  for (const destination of destinationIndexes) {
    if (availableSpace <= 0) break;

    const waiting =
      line.waitingByStop[stopIndex][destination];

    if (waiting <= 0) continue;

    const take =
      Math.min(waiting, availableSpace);

    line.waitingByStop[stopIndex][destination] -= take;
    vehicle.onboardByDestination[destination] += take;
    vehicle.onboardPassengers += take;
    boarded += take;
    availableSpace -= take;
  }

  line.queuePassengers =
    getLineWaitingPassengers(state, lineKey);

  emitPassengerEvent(
    line,
    'board',
    stopIndex,
    vehicle.id,
    boarded,
    0,
  );

  return boarded;
}

function beginBoarding(
  state,
  lineKey,
  vehicle,
) {
  boardAtStop(
    state,
    lineKey,
    vehicle,
  );

  vehicle.phase = 'boarding';
  vehicle.phaseDurationMinutes =
    BOARDING_HOLD_MINUTES;
  vehicle.phaseMinutesRemaining =
    BOARDING_HOLD_MINUTES;
}

function startTravel(
  state,
  lineKey,
  vehicle,
) {
  const line = getLine(state, lineKey);

  if (
    vehicle.currentStopIndex === 0
    && vehicle.direction < 0
  ) {
    vehicle.direction = 1;
  }

  if (
    vehicle.currentStopIndex === line.stopCount - 1
    && vehicle.direction > 0
  ) {
    vehicle.direction = -1;
  }

  const nextStopIndex =
    vehicle.currentStopIndex
    + vehicle.direction;

  if (
    nextStopIndex < 0
    || nextStopIndex >= line.stopCount
  ) {
    return;
  }

  vehicle.nextStopIndex = nextStopIndex;
  vehicle.phase = 'travel';

  const travelMinutes =
    getSegmentTravelMinutes(
      state,
      lineKey,
    );

  vehicle.phaseDurationMinutes =
    travelMinutes;

  vehicle.phaseMinutesRemaining =
    travelMinutes;
}

function arriveAtStop(
  state,
  lineKey,
  vehicle,
) {
  vehicle.currentStopIndex =
    vehicle.nextStopIndex;

  unloadAtStop(
    state,
    lineKey,
    vehicle,
    vehicle.currentStopIndex,
  );

  const line = getLine(state, lineKey);

  if (vehicle.currentStopIndex === 0) {
    vehicle.direction = 1;
  } else if (
    vehicle.currentStopIndex
    === line.stopCount - 1
  ) {
    vehicle.direction = -1;
  }

  vehicle.phase = 'dwell';

  const dwellMinutes =
    getStopDwellMinutes(
      state,
      lineKey,
      vehicle.currentStopIndex,
    );

  vehicle.phaseDurationMinutes =
    dwellMinutes;

  vehicle.phaseMinutesRemaining =
    dwellMinutes;
}

function advanceVehicle(
  state,
  lineKey,
  vehicle,
  deltaMinutes,
) {
  let remaining = deltaMinutes;
  let guard = 0;

  while (remaining > 0 && guard < 8) {
    guard += 1;

    const step = Math.min(
      remaining,
      Math.max(
        0,
        vehicle.phaseMinutesRemaining,
      ),
    );

    vehicle.phaseMinutesRemaining -= step;
    remaining -= step;

    if (vehicle.phaseMinutesRemaining > 1e-9) {
      break;
    }

    if (vehicle.phase === 'travel') {
      arriveAtStop(
        state,
        lineKey,
        vehicle,
      );
    } else if (vehicle.phase === 'dwell') {
      beginBoarding(
        state,
        lineKey,
        vehicle,
      );
    } else {
      startTravel(
        state,
        lineKey,
        vehicle,
      );
    }

    if (
      vehicle.phaseMinutesRemaining <= 0
      && remaining <= 0
    ) {
      break;
    }
  }
}

function simulateLine(
  state,
  lineKey,
  deltaMinutes,
) {
  const line = getLine(state, lineKey);

  ensureLineRuntime(state, lineKey);

  if (!line.built) {
    line.queuePassengers = 0;
    line.currentAbandonmentPpm = 0;
    line.lastDeliveredPpm = 0;
    return;
  }

  const decay =
    Math.exp(
      -deltaMinutes
      / DELIVERY_RATE_WINDOW_MINUTES,
    );

  line.lastDeliveredPpm *= decay;

  generatePassengers(
    state,
    lineKey,
    deltaMinutes,
  );

  for (const vehicle of line.vehicles) {
    advanceVehicle(
      state,
      lineKey,
      vehicle,
      deltaMinutes,
    );
  }

  line.queuePassengers =
    getLineWaitingPassengers(
      state,
      lineKey,
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
    deltaSeconds
    * GAME_MINUTES_PER_REAL_SECOND;

  state.elapsedSeconds += deltaSeconds;

  simulateLine(
    state,
    'line1',
    deltaMinutes,
  );

  simulateLine(
    state,
    'line2',
    deltaMinutes,
  );

  advanceCitySimulation(
    state,
    deltaSeconds,
  );
}

export {
  ensureCityRuntime,
};
