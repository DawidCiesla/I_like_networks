import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createInitialState,
} from '../src/simulation/model.js';

import {
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
