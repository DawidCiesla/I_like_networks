import test from 'node:test';
import assert from 'node:assert/strict';

import {
  ROAD_TOPOLOGY,
  compileRoadGraph,
  roadCorridorsConflict,
  segmentIntersection,
  validateRoadCandidate,
} from '../src/city/roadTopology.js';

import {
  generateCityMasterPlan,
} from '../src/city/planGenerator.js';

test('crossing roads compile into a shared junction and split graph edges', () => {
  const roads = [
    {
      id: 'horizontal',
      class: 'local',
      points: [
        { x: -100, y: 0 },
        { x: 100, y: 0 },
      ],
    },
    {
      id: 'vertical',
      class: 'local',
      points: [
        { x: 0, y: -100 },
        { x: 0, y: 100 },
      ],
    },
  ];

  const graph =
    compileRoadGraph(roads);

  const center =
    graph.junctions.find(
      (junction) =>
        Math.abs(junction.x) < 1e-6
        && Math.abs(junction.y) < 1e-6,
    );

  assert.ok(center);
  assert.equal(center.degree, 4);
  assert.equal(center.roadIds.length, 2);

  assert.equal(
    graph.edges.filter(
      (edge) =>
        edge.roadId === 'horizontal',
    ).length,
    2,
  );

  assert.equal(
    graph.edges.filter(
      (edge) =>
        edge.roadId === 'vertical',
    ).length,
    2,
  );
});

test('segment intersection returns the exact crossing point', () => {
  const crossing =
    segmentIntersection(
      { x: -40, y: 0 },
      { x: 40, y: 0 },
      { x: 10, y: -50 },
      { x: 10, y: 50 },
    );

  assert.ok(crossing);
  assert.ok(
    Math.abs(crossing.point.x - 10)
      < 1e-9,
  );
  assert.ok(
    Math.abs(crossing.point.y)
      < 1e-9,
  );
});

test('parallel road inside occupied corridor is rejected', () => {
  const existing = [
    {
      id: 'main',
      class: 'local',
      points: [
        { x: 0, y: 0 },
        { x: 220, y: 0 },
      ],
    },
  ];

  const result =
    validateRoadCandidate(
      {
        id: 'duplicate',
        class: 'local',
        points: [
          { x: 0, y: 20 },
          { x: 220, y: 20 },
        ],
      },
      existing,
    );

  assert.equal(result.ok, false);
  assert.equal(
    result.reason,
    'parallel-corridor-conflict',
  );
});

test('natural opposite continuation at a shared endpoint is allowed', () => {
  const existing = [
    {
      id: 'west',
      class: 'local',
      points: [
        { x: -150, y: 0 },
        { x: 0, y: 0 },
      ],
    },
  ];

  const result =
    validateRoadCandidate(
      {
        id: 'east',
        class: 'local',
        points: [
          { x: 0, y: 0 },
          { x: 150, y: 0 },
        ],
      },
      existing,
      {
        allowedTouchRoadIds: [
          'west',
        ],
      },
    );

  assert.equal(result.ok, true);
});

test('same-direction duplicate leaving the same junction is rejected', () => {
  const first = {
    id: 'first',
    class: 'local',
    points: [
      { x: 0, y: 0 },
      { x: 180, y: 0 },
    ],
  };

  const second = {
    id: 'second',
    class: 'local',
    points: [
      { x: 0, y: 0 },
      { x: 180, y: 4 },
    ],
  };

  const result =
    validateRoadCandidate(
      second,
      [first],
      {
        allowedTouchRoadIds: [
          'first',
        ],
      },
    );

  assert.equal(result.ok, false);
});

test('final city plan contains no accidental road corridor conflicts', () => {
  const plan =
    generateCityMasterPlan(
      284731,
    );

  for (
    let firstIndex = 0;
    firstIndex < plan.roads.length;
    firstIndex += 1
  ) {
    for (
      let secondIndex =
        firstIndex + 1;
      secondIndex < plan.roads.length;
      secondIndex += 1
    ) {
      const first =
        plan.roads[firstIndex];

      const second =
        plan.roads[secondIndex];

      const conflict =
        roadCorridorsConflict(
          first,
          second,
        );

      if (!conflict.conflict) {
        continue;
      }

      const intentional =
        (
          first.parentRoadIds ?? []
        ).includes(second.id)
        || (
          second.parentRoadIds ?? []
        ).includes(first.id)
        || (
          first.connectionRoadIds ?? []
        ).includes(second.id)
        || (
          second.connectionRoadIds ?? []
        ).includes(first.id);

      assert.equal(
        intentional,
        true,
        `${first.id} conflicts with ${second.id}: ${conflict.reason}`,
      );
    }
  }
});

test('compiled master graph exposes real multi-road junctions', () => {
  const plan =
    generateCityMasterPlan(
      284731,
    );

  assert.ok(
    plan.graphEdges.length
      > plan.roads.length,
  );

  assert.ok(
    plan.junctions.length >= 20,
  );

  assert.ok(
    plan.junctions.every(
      (junction) =>
        junction.roadIds.length >= 2
        || junction.degree >= 3,
    ),
  );
});

test('topology safety distances remain non-zero', () => {
  assert.ok(
    ROAD_TOPOLOGY.nodeSnapRadius >= 20,
  );

  assert.ok(
    ROAD_TOPOLOGY.parallelClearance
      >= 12,
  );

  assert.ok(
    ROAD_TOPOLOGY.minimumJunctionSpacing
      >= 60,
  );
});
