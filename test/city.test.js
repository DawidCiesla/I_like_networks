import test from 'node:test';
import assert from 'node:assert/strict';

import {
  advanceSimulation,
  createInitialState,
} from '../src/simulation/model.js';

import {
  buildNextStop,
} from '../src/simulation/actions.js';

import {
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

test('same seed creates the same immutable master plan', () => {
  const first =
    generateCityMasterPlan(284731);

  const second =
    generateCityMasterPlan(284731);

  assert.deepEqual(
    first,
    second,
  );

  assert.ok(first.roads.length > 10);
  assert.ok(first.parcels.length >= 15);
  assert.equal(first.districts.length, 8);
});

test('fresh city contains a plan but no completed buildings', () => {
  const city =
    createInitialCityState();

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

test('starting station activates Old Town and development appears over time', () => {
  const state =
    createInitialState();

  advanceFor(state, 1);

  let summary =
    getCitySummary(state);

  assert.equal(
    summary.activeDistricts,
    1,
  );

  assert.equal(
    summary.builtBuildings,
    0,
  );

  advanceFor(state, 35);

  summary =
    getCitySummary(state);

  assert.ok(
    summary.builtRoads >= 1,
  );

  assert.ok(
    state.city.projects.length > 0,
  );

  assert.ok(
    state.city.buildings.length > 0,
    'a first building project should exist',
  );
});

test('a newly purchased stop unlocks its district without instantly filling it with buildings', () => {
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

  const marketBuildingsNow =
    state.city.buildings.filter(
      (building) =>
        building.districtId
        === 'market',
    );

  assert.equal(
    marketBuildingsNow.length,
    0,
  );

  advanceFor(state, 55);

  const marketProjects =
    state.city.projects.filter(
      (project) =>
        project.districtId
        === 'market',
    );

  assert.ok(
    marketProjects.length > 0,
  );
});

test('already built city objects never disappear when another stop is purchased', () => {
  const state =
    createInitialState();

  state.money = 10_000;

  buildNextStop(
    state,
    'line1',
  );

  advanceFor(state, 75);

  const beforeRoads =
    state.city.roads
      .filter(
        (road) =>
          road.status === 'built',
      )
      .map((road) => road.id);

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

  const afterRoadIds =
    new Set(
      state.city.roads
        .filter(
          (road) =>
            road.status === 'built',
        )
        .map((road) => road.id),
    );

  const afterBuildingIds =
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

  for (const id of beforeRoads) {
    assert.equal(
      afterRoadIds.has(id),
      true,
    );
  }

  for (const id of beforeBuildings) {
    assert.equal(
      afterBuildingIds.has(id),
      true,
    );
  }
});

test('master-plan parcels never overlap each other', () => {
  const plan =
    generateCityMasterPlan(
      284731,
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

      const overlap = !(
        a.x + a.w / 2
          < b.x - b.w / 2
        || b.x + b.w / 2
          < a.x - a.w / 2
        || a.y + a.h / 2
          < b.y - b.h / 2
        || b.y + b.h / 2
          < a.y - a.h / 2
      );

      assert.equal(
        overlap,
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

  advanceFor(state, 90);

  const active =
    state.city.projects.filter(
      (project) =>
        project.status === 'active',
    );

  assert.ok(
    active.length <= 2,
  );
});
