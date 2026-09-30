import test from 'node:test';
import assert from 'node:assert/strict';

import {
  WORLD,
  WORLD_METERS_PER_UNIT,
  getSegmentRoute,
} from '../src/render/transportLayout.js';

import {
  advanceSimulation,
  createInitialState,
} from '../src/simulation/model.js';

import {
  buildDepot,
  buildNextStop,
} from '../src/simulation/actions.js';

import {
  CITY_VERSION,
  createInitialCityState,
  getCitySummary,
} from '../src/city/cityModel.js';

import {
  generateCityMasterPlan,
} from '../src/city/planGenerator.js';

function advanceFor(
  state,
  seconds,
  step = 0.1,
) {
  const iterations =
    Math.ceil(seconds / step);

  for (
    let index = 0;
    index < iterations;
    index += 1
  ) {
    advanceSimulation(
      state,
      step,
    );
  }
}

function rectanglesOverlap(a, b) {
  return !(
    a.x + a.w < b.x
    || b.x + b.w < a.x
    || a.y + a.h < b.y
    || b.y + b.h < a.y
  );
}

test('same seed creates the same immutable master plan', () => {
  const first =
    generateCityMasterPlan(284731);

  const second =
    generateCityMasterPlan(284731);

  assert.deepEqual(
    first,
    second,
  );

  assert.equal(
    first.districts.length,
    8,
  );

  assert.ok(
    first.roads.length >= 40,
  );

  assert.ok(
    first.parcels.length >= 80,
  );
});

test('bus stop spacing uses real city-scale distances', () => {
  assert.equal(
    WORLD_METERS_PER_UNIT,
    1,
  );

  const line1Distances =
    [0, 1, 2, 3].map(
      (index) =>
        getSegmentRoute(
          'line1',
          index,
          index + 1,
        ).total,
    );

  const line2Distances =
    [0, 1, 2].map(
      (index) =>
        getSegmentRoute(
          'line2',
          index,
          index + 1,
        ).total,
    );

  for (
    const distance
    of [
      ...line1Distances,
      ...line2Distances,
    ]
  ) {
    assert.ok(
      distance >= 350,
      `stop spacing too short: ${distance.toFixed(1)} m`,
    );

    assert.ok(
      distance <= 900,
      `stop spacing too long: ${distance.toFixed(1)} m`,
    );
  }
});

test('fresh city contains a plan but no completed buildings', () => {
  const city =
    createInitialCityState();

  assert.equal(
    city.version,
    CITY_VERSION,
  );

  assert.equal(
    city.buildings.length,
    0,
  );

  assert.equal(
    city.projects.length,
    0,
  );

  assert.ok(
    city.parcels.every(
      (parcel) =>
        parcel.status === 'vacant',
    ),
  );
});

test('every local street has a valid parent road and physical graph connection', () => {
  const plan =
    generateCityMasterPlan(
      284731,
    );

  const roads =
    new Map(
      plan.roads.map(
        (road) => [
          road.id,
          road,
        ],
      ),
    );

  for (
    const road
    of plan.roads.filter(
      (candidate) =>
        candidate.source === 'city',
    )
  ) {
    assert.ok(
      road.parentRoadIds.length > 0,
      `${road.id} has no parent road`,
    );

    for (
      const parentId
      of road.parentRoadIds
    ) {
      assert.equal(
        roads.has(parentId),
        true,
        `${road.id} references missing parent ${parentId}`,
      );
    }

    const physicallyConnected =
      road.parentRoadIds.some(
        (parentId) => {
          const parent =
            roads.get(parentId);

          return (
            road.fromNodeId
              === parent.fromNodeId
            || road.fromNodeId
              === parent.toNodeId
            || road.toNodeId
              === parent.fromNodeId
            || road.toNodeId
              === parent.toNodeId
          );
        },
      );

    assert.equal(
      physicallyConnected,
      true,
      `${road.id} is not physically connected to its parent`,
    );
  }
});

test('road projects never start before all parent roads are built', () => {
  const state =
    createInitialState();

  for (
    let second = 0;
    second < 90;
    second += 1
  ) {
    advanceFor(
      state,
      1,
    );

    const roads =
      new Map(
        state.city.roads.map(
          (road) => [
            road.id,
            road,
          ],
        ),
      );

    for (
      const road
      of state.city.roads.filter(
        (candidate) =>
          candidate.status
            === 'constructing',
      )
    ) {
      assert.ok(
        road.parentRoadIds.every(
          (parentId) =>
            roads.get(parentId)
              ?.status === 'built',
        ),
        `${road.id} started before its parent road`,
      );
    }
  }
});

test('starting station activates Old Town and development appears over time', () => {
  const state =
    createInitialState();

  advanceFor(state, 1);

  assert.equal(
    getCitySummary(state)
      .activeDistricts,
    1,
  );

  assert.equal(
    getCitySummary(state)
      .builtBuildings,
    0,
  );

  advanceFor(state, 45);

  assert.ok(
    state.city.projects.length > 0,
  );

  assert.ok(
    state.city.buildings.length > 0,
    'a first building project should exist',
  );

  advanceFor(state, 45);

  assert.ok(
    getCitySummary(state)
      .builtBuildings > 0,
  );
});

test('a newly purchased stop unlocks its district without instantly filling it', () => {
  const state =
    createInitialState();

  state.money = 10_000;

  advanceFor(state, 2);

  assert.equal(
    buildNextStop(
      state,
      'line1',
    ).ok,
    true,
  );

  advanceFor(state, 0.2);

  const market =
    state.city.districts.find(
      (district) =>
        district.id === 'market',
    );

  assert.equal(
    market.status,
    'active',
  );

  assert.equal(
    state.city.buildings.filter(
      (building) =>
        building.districtId
          === 'market',
    ).length,
    0,
  );

  advanceFor(state, 70);

  assert.ok(
    state.city.projects.some(
      (project) =>
        project.districtId
          === 'market',
    ),
  );
});

test('parcels only develop after their exact frontage road exists', () => {
  const state =
    createInitialState();

  advanceFor(
    state,
    100,
  );

  const roads =
    new Map(
      state.city.roads.map(
        (road) => [
          road.id,
          road,
        ],
      ),
    );

  for (
    const building
    of state.city.buildings
  ) {
    const parcel =
      state.city.parcels.find(
        (candidate) =>
          candidate.id
            === building.parcelId,
      );

    assert.ok(parcel);

    assert.equal(
      roads.get(
        parcel.frontageRoadId,
      )?.status,
      'built',
      `${building.id} developed without a built frontage road`,
    );
  }
});

test('reserved infrastructure sites stay permanently free of parcels', () => {
  const plan =
    generateCityMasterPlan(
      284731,
    );

  assert.ok(
    plan.reservations.some(
      (reservation) =>
        reservation.facilityType
          === 'bus-depot',
    ),
  );

  for (
    const reservation
    of plan.reservations
  ) {
    const padding =
      reservation.padding ?? 0;

    const reservationRect = {
      x:
        reservation.x
        - reservation.w / 2
        - padding,
      y:
        reservation.y
        - reservation.h / 2
        - padding,
      w:
        reservation.w
        + padding * 2,
      h:
        reservation.h
        + padding * 2,
    };

    for (
      const parcel
      of plan.parcels
    ) {
      const parcelRect = {
        x:
          parcel.x
          - parcel.w / 2,
        y:
          parcel.y
          - parcel.h / 2,
        w: parcel.w,
        h: parcel.h,
      };

      assert.equal(
        rectanglesOverlap(
          parcelRect,
          reservationRect,
        ),
        false,
        `${parcel.id} invades ${reservation.id}`,
      );
    }
  }
});

test('Bus Depot access remains unavailable until the depot is actually built', () => {
  const state =
    createInitialState();

  state.money = 100_000;

  buildNextStop(
    state,
    'line1',
  );

  buildNextStop(
    state,
    'line1',
  );

  advanceFor(state, 1);

  let access =
    state.city.roads.find(
      (road) =>
        road.id
          === 'depot-access',
    );

  assert.notEqual(
    access.status,
    'built',
  );

  assert.equal(
    buildDepot(state).ok,
    true,
  );

  advanceFor(state, 0.2);

  access =
    state.city.roads.find(
      (road) =>
        road.id
          === 'depot-access',
    );

  assert.equal(
    access.status,
    'built',
  );
});

test('already built city objects never disappear after network expansion', () => {
  const state =
    createInitialState();

  state.money = 10_000;

  buildNextStop(
    state,
    'line1',
  );

  advanceFor(state, 90);

  const beforeRoads =
    state.city.roads
      .filter(
        (road) =>
          road.status === 'built',
      )
      .map(
        (road) => road.id,
      );

  const beforeBuildings =
    state.city.buildings
      .filter(
        (building) =>
          building.status === 'built',
      )
      .map(
        (building) =>
          building.id,
      );

  buildNextStop(
    state,
    'line1',
  );

  advanceFor(state, 1);

  const afterRoads =
    new Set(
      state.city.roads
        .filter(
          (road) =>
            road.status === 'built',
        )
        .map(
          (road) => road.id,
        ),
    );

  const afterBuildings =
    new Set(
      state.city.buildings
        .filter(
          (building) =>
            building.status === 'built',
        )
        .map(
          (building) =>
            building.id,
        ),
    );

  for (
    const id
    of beforeRoads
  ) {
    assert.equal(
      afterRoads.has(id),
      true,
    );
  }

  for (
    const id
    of beforeBuildings
  ) {
    assert.equal(
      afterBuildings.has(id),
      true,
    );
  }
});

test('master-plan parcels never overlap each other and all have street frontage', () => {
  const plan =
    generateCityMasterPlan(
      284731,
    );

  assert.ok(
    plan.parcels.length >= 80,
  );

  assert.ok(
    plan.parcels.every(
      (parcel) =>
        typeof parcel.frontageRoadId
          === 'string'
        && parcel.frontageRoadId.length > 0,
    ),
  );

  for (
    let first = 0;
    first < plan.parcels.length;
    first += 1
  ) {
    for (
      let second = first + 1;
      second < plan.parcels.length;
      second += 1
    ) {
      const a =
        plan.parcels[first];

      const b =
        plan.parcels[second];

      assert.equal(
        rectanglesOverlap(
          {
            x: a.x - a.w / 2,
            y: a.y - a.h / 2,
            w: a.w,
            h: a.h,
          },
          {
            x: b.x - b.w / 2,
            y: b.y - b.h / 2,
            w: b.w,
            h: b.h,
          },
        ),
        false,
        `${a.id} overlaps ${b.id}`,
      );
    }
  }
});

test('only a small number of city projects can be active at once', () => {
  const state =
    createInitialState();

  state.money = 100_000;

  buildNextStop(
    state,
    'line1',
  );

  buildNextStop(
    state,
    'line1',
  );

  advanceFor(state, 120);

  const active =
    state.city.projects.filter(
      (project) =>
        project.status === 'active',
    );

  assert.ok(
    active.length <= 2,
  );
});
