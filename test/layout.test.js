import test from 'node:test';
import assert from 'node:assert/strict';

import {
  WORLD,
  getBuiltRoute,
  getFutureSegmentRoute,
  getSegmentRoute,
  getVehiclePoint,
  pointOnRoute,
} from '../src/render/transportLayout.js';

test('Line 2 branches from the exact City Park interchange coordinate', () => {
  assert.deepEqual(
    {
      x: WORLD.line2Stops[0].x,
      y: WORLD.line2Stops[0].y,
    },
    {
      x: WORLD.line1Stops[2].x,
      y: WORLD.line1Stops[2].y,
    },
  );
});

test('extending Line 1 never changes already-built geometry', () => {
  const twoStops = getBuiltRoute('line1', 2);
  const threeStops = getBuiltRoute('line1', 3);
  const fourStops = getBuiltRoute('line1', 4);

  assert.ok(threeStops.points.length > twoStops.points.length);
  assert.ok(fourStops.points.length > threeStops.points.length);

  assert.deepEqual(
    threeStops.points.slice(0, twoStops.points.length),
    twoStops.points,
  );

  assert.deepEqual(
    fourStops.points.slice(0, threeStops.points.length),
    threeStops.points,
  );
});

test('authored segments use visible bends instead of direct diagonals', () => {
  const segment = getSegmentRoute('line1', 1, 2);

  assert.ok(segment.points.length > 4);

  const hasVerticalSection = segment.segments.some(
    (part) =>
      Math.abs(part.dx) < 1
      && Math.abs(part.dy) > 10,
  );

  const hasHorizontalSection = segment.segments.some(
    (part) =>
      Math.abs(part.dy) < 1
      && Math.abs(part.dx) > 10,
  );

  assert.equal(hasVerticalSection, true);
  assert.equal(hasHorizontalSection, true);
});

test('future extension is the same fixed segment used after purchase', () => {
  const future = getFutureSegmentRoute('line1', 3);
  const built = getSegmentRoute('line1', 2, 3);

  assert.deepEqual(future.points, built.points);
});

test('vehicle rendering follows the authored curved segment in both directions', () => {
  const forward = {
    currentStopIndex: 1,
    nextStopIndex: 2,
    direction: 1,
    phase: 'travel',
    phaseDurationMinutes: 10,
    phaseMinutesRemaining: 5,
  };

  const reverse = {
    ...forward,
    currentStopIndex: 2,
    nextStopIndex: 1,
    direction: -1,
  };

  const forwardPoint = getVehiclePoint('line1', forward);
  const reversePoint = getVehiclePoint('line1', reverse);

  const route = getSegmentRoute('line1', 1, 2);
  const expected = pointOnRoute(route, route.total * 0.5);

  assert.ok(Math.abs(forwardPoint.x - expected.x) < 1e-9);
  assert.ok(Math.abs(forwardPoint.y - expected.y) < 1e-9);
  assert.ok(Math.abs(reversePoint.x - expected.x) < 1e-9);
  assert.ok(Math.abs(reversePoint.y - expected.y) < 1e-9);
});
