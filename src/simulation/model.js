import {
  advanceCitySimulation,
  createInitialCityState,
  ensureCityRuntime,
} from '../city/cityModel.js';

export const GAME_VERSION = 12;

export const LINE_KEYS = Object.freeze([
  'line1',
  'line2',
  'line3',
  'line4',
]);

export const ECONOMY = Object.freeze({
  startingMoney: 100,
  line1StopBaseCost: 40,
  line1StopCostGrowth: 1.5,
  depotBuildCost: 130,
  line2BuildCost: 220,
  line2StopBaseCost: 75,
  line2StopCostGrowth: 1.55,
  line3BuildCost: 520,
  line3StopBaseCost: 135,
  line3StopCostGrowth: 1.58,
  line4BuildCost: 950,
  line4StopBaseCost: 210,
  line4StopCostGrowth: 1.6,
  busBaseCost: 70,
  busCostGrowth: 1.4,
  maxLine1Stops: 5,
  maxLine2Stops: 4,
  maxLine3Stops: 5,
  maxLine4Stops: 5,
  maxVehiclesPerLine: 8,
  farePerPassenger: 12,
});

export const UPGRADES = Object.freeze({
  depot: {
    baseCost: 160,
    costGrowth: 1.8,
    delta: 2,
  },
});

export const STATION_UPGRADE = Object.freeze({
  maxLevel: 3,
  baseCost: 55,
  costGrowth: 1.85,
  waitingCapacityByLevel: [
    35,
    55,
    85,
    125,
  ],
  demandBonusByLevel: [
    0,
    0.2,
    0.45,
    0.75,
  ],
  dwellReductionByLevel: [
    0,
    0.02,
    0.04,
    0.06,
  ],
  tierNames: [
    'Stop',
    'Shelter',
    'Station',
    'Hub',
  ],
});

export const TRANSPORT_MODES = Object.freeze({
  bus: {
    label: 'Bus',
    unlocked: true,
    vehicleCapacity: 40,
    speedKph: 18,
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
  line3: [
    'University',
    'North Quarter',
    'Hillcrest',
    'Northgate',
    'Meadow End',
  ],
  line4: [
    'Harbor',
    'Docklands',
    'Eastgate',
    'Stadium',
    'Central',
  ],
});

export const STATION_IDS = Object.freeze({
  line1: [
    'old-town',
    'market-square',
    'city-park',
    'university',
    'central',
  ],
  line2: [
    'city-park',
    'riverside',
    'museum',
    'harbor',
  ],
  line3: [
    'university',
    'north-quarter',
    'hillcrest',
    'northgate',
    'meadow-end',
  ],
  line4: [
    'harbor',
    'docklands',
    'eastgate',
    'stadium',
    'central',
  ],
});

const GAME_MINUTES_PER_REAL_SECOND = 0.25;
const DELIVERY_RATE_WINDOW_MINUTES = 0.5;
const BOARDING_HOLD_MINUTES = 0.18;

const LINE_CONFIG = Object.freeze({
  line1: {
    segmentLengthsKm: [
      0.368,
      0.6748566882715991,
      0.7548566882715991,
      0.8348566882715991,
    ],
    demandPerStopPpm: 3.2,
    maxStops: ECONOMY.maxLine1Stops,
  },
  line2: {
    segmentLengthsKm: [
      0.7068566882715991,
      0.6908566882715991,
      0.8028566882715991,
    ],
    demandPerStopPpm: 2.8,
    maxStops: ECONOMY.maxLine2Stops,
  },
  line3: {
    segmentLengthsKm: [
      0.770856688271599,
      0.7388566882715992,
      0.6588566882715992,
      0.5948566882715993,
    ],
    demandPerStopPpm: 3.1,
    maxStops: ECONOMY.maxLine3Stops,
  },
  line4: {
    segmentLengthsKm: [
      0.738856688271599,
      0.6748566882715991,
      0.6588566882715992,
      1.202856688271599,
    ],
    demandPerStopPpm: 3.4,
    maxStops: ECONOMY.maxLine4Stops,
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
    stopCount:
      lineKey === 'line1'
        ? 1
        : 0,
    fleetCount: 0,
    demandPerStopPpm:
      config.demandPerStopPpm,
    waitingByStop:
      createWaitingMatrix(
        config.maxStops,
      ),
    queuePassengers: 0,
    currentAbandonmentPpm: 0,
    totalAbandonedPassengers: 0,
    lastDeliveredPpm: 0,
    vehicles: [],
    nextVehicleId: 1,
    eventSerial: 0,
    lastPassengerEvent: null,
    passengerEvents: [],
  };
}

function createStationState() {
  const ids =
    new Set(
      Object.values(
        STATION_IDS,
      ).flat(),
    );

  return Object.fromEntries(
    [...ids].map(
      (stationId) => [
        stationId,
        {
          level: 0,
        },
      ],
    ),
  );
}

export function createInitialState() {
  return {
    version: GAME_VERSION,
    money: ECONOMY.startingMoney,
    elapsedSeconds: 0,
    simulationSpeed: 1,

    city: createInitialCityState(),

    stations:
      createStationState(),

    line1: createLineState('line1'),
    line2: createLineState('line2'),
    line3: createLineState('line3'),
    line4: createLineState('line4'),

    depot: {
      built: false,
      garageSlots: 4,
      level: 0,
    },

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
  if (
    !LINE_CONFIG[lineKey]
    || !state[lineKey]
  ) {
    throw new Error(
      `Unknown line: ${lineKey}`,
    );
  }

  return state[lineKey];
}

export function getStationId(
  lineKey,
  stopIndex,
) {
  const stationId =
    STATION_IDS[lineKey]?.[
      stopIndex
    ];

  if (!stationId) {
    throw new Error(
      `Unknown station: ${lineKey}:${stopIndex}`,
    );
  }

  return stationId;
}

export function getStationName(
  stationId,
) {
  for (
    const lineKey
    of LINE_KEYS
  ) {
    const index =
      STATION_IDS[lineKey]
        .indexOf(stationId);

    if (index >= 0) {
      return STOP_NAMES[lineKey][
        index
      ];
    }
  }

  return stationId;
}

export function getStationLevel(
  state,
  stationId,
) {
  return (
    state.stations?.[
      stationId
    ]?.level
    ?? 0
  );
}

export function getStationTierName(
  state,
  stationId,
) {
  return (
    STATION_UPGRADE
      .tierNames[
        getStationLevel(
          state,
          stationId,
        )
      ]
    ?? 'Stop'
  );
}

export function getStationUpgradeCost(
  state,
  stationId,
) {
  const level =
    getStationLevel(
      state,
      stationId,
    );

  return Math.round(
    STATION_UPGRADE.baseCost
    * STATION_UPGRADE.costGrowth
      ** level,
  );
}

export function getStationWaitingCapacity(
  state,
  stationId,
) {
  return (
    STATION_UPGRADE
      .waitingCapacityByLevel[
        getStationLevel(
          state,
          stationId,
        )
      ]
    ?? STATION_UPGRADE
      .waitingCapacityByLevel[0]
  );
}

export function getStopDemandPpm(
  state,
  lineKey,
  stopIndex,
) {
  const line =
    getLine(
      state,
      lineKey,
    );

  const stationId =
    getStationId(
      lineKey,
      stopIndex,
    );

  const level =
    getStationLevel(
      state,
      stationId,
    );

  return (
    line.demandPerStopPpm
    + (
      STATION_UPGRADE
        .demandBonusByLevel[
          level
        ]
      ?? 0
    )
  );
}

export function getStationServedLines(
  state,
  stationId,
) {
  return LINE_KEYS.filter(
    (lineKey) => {
      const line = state[lineKey];

      if (!line?.built) {
        return false;
      }

      const index =
        STATION_IDS[lineKey]
          .indexOf(stationId);

      return (
        index >= 0
        && index < line.stopCount
      );
    },
  );
}

export function isStationBuilt(
  state,
  stationId,
) {
  if (stationId === 'old-town') {
    return true;
  }

  return LINE_KEYS.some(
    (lineKey) => {
      const line =
        state[lineKey];

      if (!line) {
        return false;
      }

      const index =
        STATION_IDS[lineKey]
          .indexOf(stationId);

      if (index < 0) {
        return false;
      }

      if (lineKey === 'line1') {
        return index < line.stopCount;
      }

      return (
        line.built
        && index < line.stopCount
      );
    },
  );
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

function getSegmentTravelMinutes(
  state,
  lineKey,
  fromStopIndex,
  toStopIndex,
) {
  const mode =
    getMode(
      state,
      lineKey,
    );

  const config =
    getLineConfig(
      lineKey,
    );

  const segmentIndex =
    Math.min(
      fromStopIndex,
      toStopIndex,
    );

  const lengthKm =
    config.segmentLengthsKm[
      segmentIndex
    ] ?? 0;

  return (
    lengthKm
    / mode.speedKph
    * 60
  );
}

function getStopDwellMinutes(
  state,
  lineKey,
  stopIndex,
) {
  const line =
    getLine(
      state,
      lineKey,
    );

  const mode =
    getMode(
      state,
      lineKey,
    );

  const stationId =
    getStationId(
      lineKey,
      stopIndex,
    );

  const level =
    getStationLevel(
      state,
      stationId,
    );

  const dwellReduction =
    STATION_UPGRADE
      .dwellReductionByLevel[
        level
      ]
    ?? 0;

  const isEndpoint =
    stopIndex === 0
    || stopIndex
      === line.stopCount - 1;

  return (
    Math.max(
      0.12,
      mode.dwellMinutes
      - dwellReduction,
    )
    + (
      isEndpoint
        ? mode.turnaroundMinutes / 2
        : 0
    )
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

export function ensureStationRuntime(
  state,
) {
  if (
    !state.stations
    || typeof state.stations
      !== 'object'
  ) {
    state.stations =
      createStationState();
    return;
  }

  for (
    const stationId
    of new Set(
      Object.values(
        STATION_IDS,
      ).flat(),
    )
  ) {
    const previous =
      state.stations[
        stationId
      ];

    state.stations[
      stationId
    ] = {
      level:
        Number.isFinite(
          previous?.level,
        )
          ? Math.max(
            0,
            Math.min(
              STATION_UPGRADE.maxLevel,
              Math.floor(
                previous.level,
              ),
            ),
          )
          : 0,
    };
  }
}

export function ensureLineRuntime(state, lineKey) {
  ensureStationRuntime(state);

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
  const line =
    getLine(
      state,
      lineKey,
    );

  if (
    !line.built
    || line.stopCount < 2
  ) {
    return 0;
  }

  let total = 0;

  for (
    let stopIndex = 0;
    stopIndex < line.stopCount;
    stopIndex += 1
  ) {
    total +=
      getStopDemandPpm(
        state,
        lineKey,
        stopIndex,
      );
  }

  return total;
}

export function getTotalDemandPpm(state) {
  return LINE_KEYS.reduce(
    (total, lineKey) =>
      total
      + getLineDemandPpm(
        state,
        lineKey,
      ),
    0,
  );
}

export function getRouteLengthKm(state, lineKey) {
  const line =
    getLine(
      state,
      lineKey,
    );

  const config =
    getLineConfig(
      lineKey,
    );

  const segmentCount =
    Math.max(
      0,
      line.stopCount - 1,
    );

  return config.segmentLengthsKm
    .slice(
      0,
      segmentCount,
    )
    .reduce(
      (sum, length) =>
        sum + length,
      0,
    );
}

function getBaseStopDwellMinutes(
  state,
  lineKey,
  stopIndex,
) {
  const mode =
    getMode(
      state,
      lineKey,
    );

  const level =
    getStationLevel(
      state,
      getStationId(
        lineKey,
        stopIndex,
      ),
    );

  return Math.max(
    0.12,
    mode.dwellMinutes
    - (
      STATION_UPGRADE
        .dwellReductionByLevel[
          level
        ]
      ?? 0
    ),
  );
}

export function getLineOneWayMinutes(state, lineKey) {
  const line =
    getLine(
      state,
      lineKey,
    );

  if (
    !line.built
    || line.stopCount < 2
  ) {
    return 0;
  }

  const mode =
    getMode(
      state,
      lineKey,
    );

  const drivingMinutes =
    getRouteLengthKm(
      state,
      lineKey,
    )
    / mode.speedKph
    * 60;

  let dwellMinutes = 0;

  for (
    let stopIndex = 1;
    stopIndex < line.stopCount;
    stopIndex += 1
  ) {
    dwellMinutes +=
      getBaseStopDwellMinutes(
        state,
        lineKey,
        stopIndex,
      );
  }

  return (
    drivingMinutes
    + dwellMinutes
    + mode.turnaroundMinutes / 2
  );
}

export function getLineCycleMinutes(state, lineKey) {
  const line =
    getLine(
      state,
      lineKey,
    );

  if (
    !line.built
    || line.stopCount < 2
  ) {
    return 0;
  }

  const mode =
    getMode(
      state,
      lineKey,
    );

  const drivingMinutes =
    getRouteLengthKm(
      state,
      lineKey,
    )
    / mode.speedKph
    * 60
    * 2;

  let dwellMinutes = 0;

  for (
    let stopIndex = 0;
    stopIndex < line.stopCount;
    stopIndex += 1
  ) {
    const visits =
      stopIndex === 0
      || stopIndex
        === line.stopCount - 1
        ? 1
        : 2;

    dwellMinutes +=
      getBaseStopDwellMinutes(
        state,
        lineKey,
        stopIndex,
      ) * visits;
  }

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
  const line =
    getLine(
      state,
      lineKey,
    );

  const config = {
    line1: {
      base:
        ECONOMY.line1StopBaseCost,
      growth:
        ECONOMY.line1StopCostGrowth,
      includedStops: 1,
    },
    line2: {
      base:
        ECONOMY.line2StopBaseCost,
      growth:
        ECONOMY.line2StopCostGrowth,
      includedStops: 2,
    },
    line3: {
      base:
        ECONOMY.line3StopBaseCost,
      growth:
        ECONOMY.line3StopCostGrowth,
      includedStops: 2,
    },
    line4: {
      base:
        ECONOMY.line4StopBaseCost,
      growth:
        ECONOMY.line4StopCostGrowth,
      includedStops: 2,
    },
  }[lineKey];

  if (!config) {
    throw new Error(
      `Unknown line: ${lineKey}`,
    );
  }

  const purchasedStops =
    Math.max(
      0,
      line.stopCount
      - config.includedStops,
    );

  return Math.round(
    config.base
    * config.growth
      ** purchasedStops,
  );
}

export function getGarageUsed(state) {
  return LINE_KEYS.reduce(
    (total, lineKey) =>
      total
      + (
        state[lineKey]
          ?.fleetCount
        ?? 0
      ),
    0,
  );
}

export function getVehiclePurchaseCost(state) {
  const starterVehicles =
    LINE_KEYS.filter(
      (lineKey) =>
        state[lineKey]?.built,
    ).length;

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

export function isLineStable(
  state,
  lineKey,
) {
  const line =
    getLine(
      state,
      lineKey,
    );

  return (
    line.built
    && getLineCapacityPpm(
      state,
      lineKey,
    )
      >= getLineDemandPpm(
        state,
        lineKey,
      )
  );
}

export function isLine1Stable(state) {
  return isLineStable(
    state,
    'line1',
  );
}

function hasFreeGarageSlot(state) {
  return (
    getGarageUsed(state)
    < state.depot.garageSlots
  );
}

export function canUnlockLine2(state) {
  return (
    !state.line2.built
    && state.depot.built
    && state.line1.stopCount
      >= ECONOMY.maxLine1Stops
    && isLineStable(
      state,
      'line1',
    )
    && hasFreeGarageSlot(state)
  );
}

export function canUnlockLine3(state) {
  return (
    !state.line3.built
    && state.depot.built
    && state.line2.built
    && state.line2.stopCount
      >= ECONOMY.maxLine2Stops
    && isLineStable(
      state,
      'line2',
    )
    && hasFreeGarageSlot(state)
  );
}

export function canUnlockLine4(state) {
  return (
    !state.line4.built
    && state.depot.built
    && state.line3.built
    && state.line3.stopCount
      >= ECONOMY.maxLine3Stops
    && isLineStable(
      state,
      'line3',
    )
    && hasFreeGarageSlot(state)
  );
}

function getUpgradeLevel(state, type) {
  if (type === 'depot') {
    return state.depot.level;
  }

  throw new Error(
    `Unknown upgrade type: ${type}`,
  );
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

export function getStationWaitingPassengers(
  state,
  stationId,
) {
  let total = 0;

  for (
    const lineKey
    of LINE_KEYS
  ) {
    const line = state[lineKey];

    if (!line?.built) {
      continue;
    }

    const stopIndex =
      STATION_IDS[lineKey]
        .indexOf(stationId);

    if (
      stopIndex < 0
      || stopIndex
        >= line.stopCount
    ) {
      continue;
    }

    total +=
      getStopWaitingPassengers(
        state,
        lineKey,
        stopIndex,
      );
  }

  return total;
}

export function getStationDemandPpm(
  state,
  stationId,
) {
  let total = 0;

  for (
    const lineKey
    of LINE_KEYS
  ) {
    const line = state[lineKey];

    if (!line?.built) {
      continue;
    }

    const stopIndex =
      STATION_IDS[lineKey]
        .indexOf(stationId);

    if (
      stopIndex < 0
      || stopIndex
        >= line.stopCount
    ) {
      continue;
    }

    total +=
      getStopDemandPpm(
        state,
        lineKey,
        stopIndex,
      );
  }

  return total;
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
  return LINE_KEYS.reduce(
    (total, lineKey) =>
      total
      + (
        state[lineKey]
          ?.lastDeliveredPpm
        ?? 0
      ),
    0,
  );
}

export function getLastFareEventValue(state) {
  return state.stats.lastFareEventValue ?? 0;
}

export function getAverageWaitMinutes(state) {
  const demands =
    LINE_KEYS.map(
      (lineKey) => ({
        lineKey,
        demand:
          getLineDemandPpm(
            state,
            lineKey,
          ),
      }),
    );

  const totalDemand =
    demands.reduce(
      (total, entry) =>
        total + entry.demand,
      0,
    );

  if (totalDemand <= 0) {
    return 0;
  }

  let weighted = 0;

  for (
    const {
      lineKey,
      demand,
    }
    of demands
  ) {
    if (demand <= 0) {
      continue;
    }

    const line =
      getLine(
        state,
        lineKey,
      );

    const scheduled =
      getLineHeadwayMinutes(
        state,
        lineKey,
      ) / 2;

    const delivered =
      Math.max(
        0.1,
        line.lastDeliveredPpm,
      );

    weighted += (
      scheduled
      + line.queuePassengers
        / delivered
    ) * demand;
  }

  return Math.min(
    120,
    weighted / totalDemand,
  );
}

export function getAbandonmentPercent(state) {
  const demand = getTotalDemandPpm(state);

  if (demand <= 0) return 0;

  const abandonment =
    LINE_KEYS.reduce(
      (total, lineKey) =>
        total
        + (
          state[lineKey]
            ?.currentAbandonmentPpm
          ?? 0
        ),
      0,
    );

  return Math.min(
    100,
    abandonment / demand * 100,
  );
}

export function getBottleneck(state) {
  for (
    let index = 0;
    index < LINE_KEYS.length;
    index += 1
  ) {
    const lineKey =
      LINE_KEYS[index];

    const line =
      state[lineKey];

    if (!line?.built) {
      continue;
    }

    if (
      getLineDemandPpm(
        state,
        lineKey,
      )
      > getLineCapacityPpm(
        state,
        lineKey,
      )
    ) {
      return `line-${index + 1}`;
    }
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

  let abandoned = 0;

  for (
    let origin = 0;
    origin < line.stopCount;
    origin += 1
  ) {
    const perDestinationRate =
      getStopDemandPpm(
        state,
        lineKey,
        origin,
      )
      / Math.max(
        1,
        line.stopCount - 1,
      );

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

    const stationId =
      getStationId(
        lineKey,
        origin,
      );

    const waitingCapacity =
      getStationWaitingCapacity(
        state,
        stationId,
      );

    if (
      waiting
      > waitingCapacity
    ) {
      const keepRatio =
        waitingCapacity
        / waiting;

      const excess =
        waiting - waitingCapacity;

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
      vehicle.currentStopIndex,
      nextStopIndex,
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

  for (
    const lineKey
    of LINE_KEYS
  ) {
    simulateLine(
      state,
      lineKey,
      deltaMinutes,
    );
  }

  advanceCitySimulation(
    state,
    deltaSeconds,
  );
}

export {
  ensureCityRuntime,
};
