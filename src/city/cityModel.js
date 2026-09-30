import {
  generateCityMasterPlan,
} from './planGenerator.js';

export const CITY_VERSION = 4;
export const DEFAULT_CITY_SEED = 284731;

const MAX_ACTIVE_PROJECTS = 2;
const CITY_SIMULATION_STEP_SECONDS = 0.2;

function clamp(value, min, max) {
  return Math.min(
    max,
    Math.max(min, value),
  );
}

function transportUnlockSatisfied(
  state,
  unlock,
) {
  if (!unlock) return true;

  if (
    unlock.requiresDepot
    && !state.depot.built
  ) {
    return false;
  }

  if (unlock.districtId) {
    return Boolean(
      state.city.districts.find(
        (district) =>
          district.id
          === unlock.districtId,
      )?.status === 'active',
    );
  }

  const line =
    unlock.lineKey === 'line1'
      ? state.line1
      : state.line2;

  if (!line) return false;

  if (
    unlock.lineKey === 'line2'
    && !state.line2.built
  ) {
    return false;
  }

  return (
    line.stopCount
    >= (unlock.stopCount ?? 0)
  );
}

function districtShouldBeActive(
  state,
  district,
) {
  if (district.lineKey === 'line1') {
    return (
      state.line1.stopCount
      > district.stopIndex
    );
  }

  return (
    state.line2.built
    && state.line2.stopCount
      > district.stopIndex
  );
}

function getDistrictLine(
  state,
  district,
) {
  return (
    district.lineKey === 'line1'
      ? state.line1
      : state.line2
  );
}

function getDistrictPressure(
  state,
  district,
) {
  const line =
    getDistrictLine(
      state,
      district,
    );

  const age =
    Math.max(
      0,
      state.city.timeSeconds
      - (district.activatedAt ?? 0),
    );

  const ageScore =
    Math.min(
      3.5,
      age / 40,
    );

  const stopScore =
    Math.max(
      0,
      line.stopCount - 1,
    ) * 0.35;

  const ridershipScore =
    Math.min(
      2.5,
      (line.lastDeliveredPpm ?? 0)
      / 8,
    );

  const fleetScore =
    Math.min(
      1.5,
      (line.fleetCount ?? 0)
      * 0.25,
    );

  const interchangeBonus =
    district.id === 'park'
    && state.line2.built
      ? 1.2
      : 0;

  const centralBonus =
    district.theme === 'central'
      ? 0.8
      : 0;

  return (
    0.6
    + ageScore
    + stopScore
    + ridershipScore
    + fleetScore
    + interchangeBonus
    + centralBonus
  );
}

function roadLength(
  road,
) {
  let total = 0;

  for (
    let index = 0;
    index < (road.points?.length ?? 0) - 1;
    index += 1
  ) {
    total += Math.hypot(
      road.points[index + 1].x
        - road.points[index].x,
      road.points[index + 1].y
        - road.points[index].y,
    );
  }

  return total;
}

function projectDurationForRoad(
  road,
) {
  const length =
    roadLength(road);

  if (road.class === 'service') {
    return 6 + length / 38;
  }

  if (road.class === 'arterial') {
    return 8 + length / 32;
  }

  if (road.class === 'collector') {
    return 7 + length / 29;
  }

  return 6 + length / 26;
}

function profileHeightMeters(
  kind,
  floors,
) {
  if (kind === 'house') return 7.5;
  if (kind === 'townhouse') return 9;
  if (kind === 'shop') return 6.5;
  if (kind === 'workshop') return 8;
  if (kind === 'warehouse') return 11;

  const floorHeight =
    kind === 'tower'
      ? 3.7
      : (
        kind === 'civic'
        || kind === 'campus'
      )
        ? 3.6
        : 3.25;

  return (
    floors * floorHeight
    + 1.5
  );
}

function makeBuildingProfile(
  kind,
  floors,
  density,
) {
  return {
    kind,
    floors,
    density,
    heightMeters:
      profileHeightMeters(
        kind,
        floors,
      ),
  };
}

function buildingProfileFor(
  district,
  parcel,
  pressure,
) {
  const density = clamp(
    parcel.density
      + Math.floor(
        Math.max(
          0,
          pressure - 3.8,
        ) / 2.2,
      ),
    1,
    4,
  );

  if (parcel.zone === 'industrial') {
    const kind =
      density >= 3
        ? 'warehouse'
        : 'workshop';

    return makeBuildingProfile(
      kind,
      density >= 3 ? 2 : 1,
      density,
    );
  }

  if (parcel.zone === 'civic') {
    return makeBuildingProfile(
      district.theme === 'campus'
        ? 'campus'
        : 'civic',
      density >= 3 ? 4 : 3,
      density,
    );
  }

  if (parcel.zone === 'commercial') {
    if (
      district.theme === 'central'
      && density >= 4
    ) {
      return makeBuildingProfile(
        'tower',
        8 + Math.min(4, density),
        density,
      );
    }

    return makeBuildingProfile(
      density >= 3
        ? 'midrise'
        : 'shop',
      density >= 3
        ? 4 + density
        : 1,
      density,
    );
  }

  if (parcel.zone === 'mixed') {
    if (
      district.theme === 'central'
      && density >= 4
    ) {
      return makeBuildingProfile(
        'tower',
        9,
        density,
      );
    }

    if (density >= 3) {
      return makeBuildingProfile(
        'midrise',
        4 + density,
        density,
      );
    }

    return makeBuildingProfile(
      'shop',
      2,
      density,
    );
  }

  if (density >= 3) {
    return makeBuildingProfile(
      'apartment',
      3 + density,
      density,
    );
  }

  if (density >= 2) {
    return makeBuildingProfile(
      'townhouse',
      2,
      density,
    );
  }

  return makeBuildingProfile(
    'house',
    1,
    density,
  );
}

function parcelFrontageAngle(
  city,
  parcel,
) {
  const road =
    city.roads.find(
      (candidate) =>
        candidate.id
        === parcel.frontageRoadId,
    );

  if (
    !road
    || road.points.length < 2
  ) {
    return 0;
  }

  let bestDistance =
    Number.POSITIVE_INFINITY;

  let bestAngle = 0;

  for (
    let index = 0;
    index < road.points.length - 1;
    index += 1
  ) {
    const a =
      road.points[index];

    const b =
      road.points[index + 1];

    const dx =
      b.x - a.x;

    const dy =
      b.y - a.y;

    const lengthSquared =
      dx * dx + dy * dy;

    if (lengthSquared <= 1e-9) {
      continue;
    }

    const t =
      Math.max(
        0,
        Math.min(
          1,
          (
            (parcel.x - a.x) * dx
            + (parcel.y - a.y) * dy
          ) / lengthSquared,
        ),
      );

    const px =
      a.x + dx * t;

    const py =
      a.y + dy * t;

    const distance =
      Math.hypot(
        parcel.x - px,
        parcel.y - py,
      );

    if (distance < bestDistance) {
      bestDistance = distance;
      bestAngle =
        Math.atan2(dy, dx);
    }
  }

  return bestAngle;
}

function buildingDuration(profile) {
  if (profile.kind === 'tower') {
    return 48;
  }

  if (
    profile.kind === 'midrise'
    || profile.kind === 'campus'
    || profile.kind === 'civic'
  ) {
    return 32;
  }

  if (
    profile.kind === 'apartment'
    || profile.kind === 'warehouse'
  ) {
    return 24;
  }

  return 15;
}

function activeProjectCount(city) {
  return city.projects.filter(
    (project) =>
      project.status === 'active',
  ).length;
}

function roadDependenciesBuilt(
  city,
  road,
) {
  const parents =
    road.parentRoadIds ?? [];

  return parents.every(
    (parentId) =>
      city.roads.some(
        (candidate) =>
          candidate.id === parentId
          && candidate.status === 'built',
      ),
  );
}

function projectCanStart(
  city,
  project,
) {
  if (project.type !== 'road') {
    return true;
  }

  const road =
    city.roads.find(
      (candidate) =>
        candidate.id
        === project.targetId,
    );

  return Boolean(
    road
    && roadDependenciesBuilt(
      city,
      road,
    ),
  );
}

function nextProjectId(city) {
  const id =
    `project-${city.nextProjectId}`;

  city.nextProjectId += 1;
  return id;
}

function scheduleRoadProjects(
  state,
  district,
) {
  const city = state.city;

  const roads =
    city.roads
      .filter(
        (road) =>
          road.districtId
          === district.id
          && road.source === 'city'
          && road.status === 'planned',
      )
      .sort(
        (a, b) =>
          a.buildOrder - b.buildOrder,
      );

  roads.forEach(
    (road, index) => {
      const exists =
        city.projects.some(
          (project) =>
            project.targetType === 'road'
            && project.targetId
              === road.id,
        );

      if (exists) return;

      city.projects.push({
        id:
          nextProjectId(city),
        type: 'road',
        targetType: 'road',
        targetId: road.id,
        districtId:
          district.id,
        status: 'queued',
        queuedAt:
          city.timeSeconds,
        eligibleAt:
          city.timeSeconds
          + 5
          + index * 8,
        startedAt: null,
        duration:
          projectDurationForRoad(
            road,
          ),
        progress: 0,
      });
    },
  );
}

function syncPrimaryRoads(state) {
  for (const road of state.city.roads) {
    if (
      road.source === 'existing-arterial'
    ) {
      road.status = 'built';
      road.constructionProgress = 1;
      continue;
    }

    if (
      road.source
      !== 'transport-corridor'
      && road.source
        !== 'depot-access'
    ) {
      continue;
    }

    if (
      transportUnlockSatisfied(
        state,
        road.unlock,
      )
      && roadDependenciesBuilt(
        state.city,
        road,
      )
    ) {
      road.status = 'built';
      road.constructionProgress = 1;
    }
  }
}

function syncDistrictActivation(state) {
  for (
    const district
    of state.city.districts
  ) {
    if (
      district.status === 'locked'
      && districtShouldBeActive(
        state,
        district,
      )
    ) {
      district.status = 'active';
      district.activatedAt =
        state.city.timeSeconds;

      for (
        const blockId
        of district.blockIds
      ) {
        const block =
          state.city.blocks.find(
            (candidate) =>
              candidate.id
              === blockId,
          );

        if (block) {
          block.status = 'active';
        }
      }

      scheduleRoadProjects(
        state,
        district,
      );
    }
  }
}

function roadSupportForParcel(
  state,
  parcel,
) {
  if (!parcel.frontageRoadId) {
    return false;
  }

  return state.city.roads.some(
    (road) =>
      road.id
        === parcel.frontageRoadId
      && road.status === 'built',
  );
}

function maybeQueueBuilding(
  state,
  district,
) {
  const city = state.city;

  const existingQueued =
    city.projects.some(
      (project) =>
        project.districtId
          === district.id
        && project.type
          === 'building'
        && (
          project.status === 'queued'
          || project.status === 'active'
        ),
    );

  if (existingQueued) return;

  const pressure =
    getDistrictPressure(
      state,
      district,
    );

  const age =
    Math.max(
      0,
      city.timeSeconds
      - (district.activatedAt ?? 0),
    );

  const parcels =
    city.parcels
      .filter(
        (parcel) =>
          parcel.districtId
            === district.id
          && parcel.status
            === 'vacant'
          && roadSupportForParcel(
            state,
            parcel,
          ),
      )
      .sort(
        (a, b) =>
          a.developmentOrder
          - b.developmentOrder,
      );

  for (
    let index = 0;
    index < parcels.length;
    index += 1
  ) {
    const parcel = parcels[index];

    const minimumAge =
      12
      + index * 9
      + parcel.developmentOrder * 8;

    const requiredPressure =
      1.2
      + index * 0.38
      + parcel.density * 0.18;

    if (
      age < minimumAge
      || pressure
        < requiredPressure
    ) {
      continue;
    }

    const profile =
      buildingProfileFor(
        district,
        parcel,
        pressure,
      );

    parcel.status = 'reserved';
    parcel.reservedAt =
      city.timeSeconds;

    city.projects.push({
      id:
        nextProjectId(city),
      type: 'building',
      targetType: 'parcel',
      targetId: parcel.id,
      districtId:
        district.id,
      status: 'queued',
      queuedAt:
        city.timeSeconds,
      eligibleAt:
        city.timeSeconds
        + 2,
      startedAt: null,
      duration:
        buildingDuration(profile),
      progress: 0,
      profile,
    });

    return;
  }
}

function queueDevelopmentProjects(
  state,
) {
  for (
    const district
    of state.city.districts
  ) {
    if (
      district.status !== 'active'
    ) {
      continue;
    }

    maybeQueueBuilding(
      state,
      district,
    );
  }
}

function startEligibleProjects(city) {
  let freeSlots =
    MAX_ACTIVE_PROJECTS
    - activeProjectCount(city);

  if (freeSlots <= 0) return;

  const eligible =
    city.projects
      .filter(
        (project) =>
          project.status === 'queued'
          && project.eligibleAt
            <= city.timeSeconds
          && projectCanStart(
            city,
            project,
          ),
      )
      .sort(
        (a, b) => {
          if (
            a.type !== b.type
          ) {
            return (
              a.type === 'road'
                ? -1
                : 1
            );
          }

          return (
            a.eligibleAt
            - b.eligibleAt
          );
        },
      );

  for (
    const project
    of eligible
  ) {
    if (freeSlots <= 0) break;

    project.status = 'active';
    project.startedAt =
      city.timeSeconds;
    freeSlots -= 1;

    if (project.type === 'road') {
      const road =
        city.roads.find(
          (candidate) =>
            candidate.id
            === project.targetId,
        );

      if (road) {
        road.status =
          'constructing';
      }
    }

    if (project.type === 'building') {
      const parcel =
        city.parcels.find(
          (candidate) =>
            candidate.id
            === project.targetId,
        );

      if (parcel) {
        const buildingId =
          `building-${parcel.id}`;

        parcel.buildingId =
          buildingId;
        parcel.status =
          'constructing';

        city.buildings.push({
          id: buildingId,
          districtId:
            project.districtId,
          parcelId:
            parcel.id,
          x: parcel.x,
          y: parcel.y,
          zone: parcel.zone,
          profile: {
            ...project.profile,
          },
          rotationRadians:
            parcelFrontageAngle(
              city,
              parcel,
            ),
          status:
            'constructing',
          constructionProgress: 0,
          createdAt:
            city.timeSeconds,
          completedAt: null,
        });
      }
    }
  }
}

function finishProject(
  city,
  project,
) {
  project.status = 'complete';
  project.progress = 1;
  project.completedAt =
    city.timeSeconds;

  if (project.type === 'road') {
    const road =
      city.roads.find(
        (candidate) =>
          candidate.id
          === project.targetId,
      );

    if (road) {
      road.status = 'built';
      road.constructionProgress = 1;
    }

    return;
  }

  const parcel =
    city.parcels.find(
      (candidate) =>
        candidate.id
        === project.targetId,
    );

  if (parcel) {
    parcel.status = 'built';
  }

  const building =
    city.buildings.find(
      (candidate) =>
        candidate.parcelId
        === project.targetId,
    );

  if (building) {
    building.status = 'built';
    building.constructionProgress = 1;
    building.completedAt =
      city.timeSeconds;
  }
}

function progressActiveProjects(
  city,
  deltaSeconds,
) {
  for (
    const project
    of city.projects
  ) {
    if (
      project.status !== 'active'
    ) {
      continue;
    }

    project.progress = clamp(
      project.progress
      + deltaSeconds
        / Math.max(
          0.01,
          project.duration,
        ),
      0,
      1,
    );

    if (project.type === 'road') {
      const road =
        city.roads.find(
          (candidate) =>
            candidate.id
            === project.targetId,
        );

      if (road) {
        road.constructionProgress =
          project.progress;
      }
    }

    if (project.type === 'building') {
      const building =
        city.buildings.find(
          (candidate) =>
            candidate.parcelId
            === project.targetId,
        );

      if (building) {
        building.constructionProgress =
          project.progress;
      }
    }

    if (project.progress >= 1) {
      finishProject(
        city,
        project,
      );
    }
  }
}

function updateDevelopmentLevels(
  state,
) {
  for (
    const district
    of state.city.districts
  ) {
    const total =
      district.parcelIds.length;

    if (total === 0) {
      district.developmentLevel = 0;
      continue;
    }

    const built =
      state.city.parcels.filter(
        (parcel) =>
          parcel.districtId
            === district.id
          && parcel.status
            === 'built',
      ).length;

    district.developmentLevel =
      built / total;
  }
}

export function createInitialCityState(
  seed = DEFAULT_CITY_SEED,
) {
  const masterPlan =
    generateCityMasterPlan(seed);

  return {
    version: CITY_VERSION,
    seed,
    timeSeconds: 0,
    runtimeAccumulatorSeconds: 0,
    nextProjectId: 1,
    nodes: masterPlan.nodes,
    graphEdges:
      masterPlan.graphEdges,
    junctions:
      masterPlan.junctions,
    roads: masterPlan.roads,
    districts:
      masterPlan.districts,
    blocks:
      masterPlan.blocks,
    parcels:
      masterPlan.parcels,
    reservations:
      masterPlan.reservations,
    buildings: [],
    projects: [],
  };
}

export function ensureCityRuntime(
  state,
) {
  if (
    !state.city
    || state.city.version
      !== CITY_VERSION
  ) {
    state.city =
      createInitialCityState(
        state.city?.seed
        ?? DEFAULT_CITY_SEED,
      );
  }

  state.city.runtimeAccumulatorSeconds =
    Number.isFinite(
      state.city.runtimeAccumulatorSeconds,
    )
      ? state.city.runtimeAccumulatorSeconds
      : 0;

  state.city.nextProjectId =
    Number.isFinite(
      state.city.nextProjectId,
    )
      ? state.city.nextProjectId
      : 1;

  state.city.timeSeconds =
    Number.isFinite(
      state.city.timeSeconds,
    )
      ? state.city.timeSeconds
      : 0;

  state.city.graphEdges =
    Array.isArray(
      state.city.graphEdges,
    )
      ? state.city.graphEdges
      : [];

  state.city.junctions =
    Array.isArray(
      state.city.junctions,
    )
      ? state.city.junctions
      : [];

  state.city.buildings =
    Array.isArray(
      state.city.buildings,
    )
      ? state.city.buildings
      : [];

  state.city.projects =
    Array.isArray(
      state.city.projects,
    )
      ? state.city.projects
      : [];

  state.city.reservations =
    Array.isArray(
      state.city.reservations,
    )
      ? state.city.reservations
      : [];

  syncCityWithTransport(state);
  return state.city;
}

export function syncCityWithTransport(
  state,
) {
  if (!state.city) return;

  syncDistrictActivation(state);
  syncPrimaryRoads(state);
  updateDevelopmentLevels(state);
}

export function advanceCitySimulation(
  state,
  deltaSeconds,
) {
  if (
    !Number.isFinite(deltaSeconds)
    || deltaSeconds <= 0
  ) {
    return;
  }

  ensureCityRuntime(state);

  state.city.timeSeconds +=
    deltaSeconds;

  state.city.runtimeAccumulatorSeconds +=
    deltaSeconds;

  let guard = 0;

  while (
    state.city.runtimeAccumulatorSeconds
      >= CITY_SIMULATION_STEP_SECONDS
    && guard < 8
  ) {
    guard += 1;

    syncCityWithTransport(state);

    progressActiveProjects(
      state.city,
      CITY_SIMULATION_STEP_SECONDS,
    );

    queueDevelopmentProjects(state);

    startEligibleProjects(
      state.city,
    );

    updateDevelopmentLevels(state);

    state.city.runtimeAccumulatorSeconds -=
      CITY_SIMULATION_STEP_SECONDS;
  }
}

export function getCitySummary(state) {
  ensureCityRuntime(state);

  return {
    seed: state.city.seed,
    timeSeconds:
      state.city.timeSeconds,
    activeDistricts:
      state.city.districts.filter(
        (district) =>
          district.status
          === 'active',
      ).length,
    builtRoads:
      state.city.roads.filter(
        (road) =>
          road.status === 'built',
      ).length,
    activeProjects:
      state.city.projects.filter(
        (project) =>
          project.status
          === 'active',
      ).length,
    builtBuildings:
      state.city.buildings.filter(
        (building) =>
          building.status
          === 'built',
      ).length,
  };
}
