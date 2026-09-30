import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createInitialState,
} from '../src/simulation/model.js';

import {
  getCityLots,
  getCityStage,
} from '../src/render/cityRenderer.js';

test('city growth follows transport infrastructure milestones', () => {
  const state = createInitialState();

  assert.equal(getCityStage(state), 0);

  state.line1.built = true;
  state.line1.stopCount = 2;
  assert.equal(getCityStage(state), 1);

  state.line1.stopCount = 3;
  assert.equal(getCityStage(state), 2);

  state.line1.stopCount = 4;
  assert.equal(getCityStage(state), 3);

  state.line1.stopCount = 5;
  assert.equal(getCityStage(state), 4);

  state.line2.built = true;
  state.line2.stopCount = 2;
  assert.equal(getCityStage(state), 5);

  state.line2.stopCount = 3;
  assert.equal(getCityStage(state), 6);

  state.line2.stopCount = 4;
  assert.equal(getCityStage(state), 7);
});

test('mature city lots stay separated and do not collapse into visual clutter', () => {
  const state = createInitialState();

  state.line1.built = true;
  state.line1.stopCount = 5;
  state.depot.built = true;
  state.line2.built = true;
  state.line2.stopCount = 4;

  const lots = getCityLots(state);

  assert.ok(
    lots.length >= 18,
    'mature city should still feel populated',
  );

  assert.ok(
    lots.length <= 28,
    'mature city should not become overcrowded',
  );

  for (
    let first = 0;
    first < lots.length;
    first += 1
  ) {
    for (
      let second = first + 1;
      second < lots.length;
      second += 1
    ) {
      const a = lots[first].box;
      const b = lots[second].box;

      const overlaps = !(
        a.x + a.w < b.x
        || b.x + b.w < a.x
        || a.y + a.h < b.y
        || b.y + b.h < a.y
      );

      assert.equal(
        overlaps,
        false,
        `${lots[first].key} overlaps ${lots[second].key}`,
      );
    }
  }
});

test('central district gains dense urban buildings in the late city', () => {
  const state = createInitialState();

  state.line1.built = true;
  state.line1.stopCount = 5;
  state.depot.built = true;
  state.line2.built = true;
  state.line2.stopCount = 4;

  const centralLots =
    getCityLots(state).filter(
      (lot) => lot.theme === 'central',
    );

  assert.ok(centralLots.length >= 3);

  assert.ok(
    centralLots.some(
      (lot) =>
        lot.profile.kind === 'tower'
        || lot.profile.kind === 'midrise',
    ),
  );
});
