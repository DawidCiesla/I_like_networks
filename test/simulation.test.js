import test from 'node:test';
import assert from 'node:assert/strict';
import { advanceSimulation, createInitialState, getIncomePerSecond, getThroughputMbps, getUpgradeCost } from '../src/simulation/model.js';
import { buildEthernet, buyUpgrade, setSimulationSpeed } from '../src/simulation/actions.js';

test('disconnected network has zero throughput and income', () => {
  const state = createInitialState();
  assert.equal(getThroughputMbps(state), 0);
  assert.equal(getIncomePerSecond(state), 0);
});

test('building Ethernet starts traffic and charges the build cost', () => {
  const state = createInitialState();
  assert.equal(buildEthernet(state).ok, true);
  assert.equal(state.money, 60);
  assert.equal(getThroughputMbps(state), 10);
});

test('simulation earns revenue only from serviced throughput', () => {
  const state = createInitialState();
  buildEthernet(state);
  const before = state.money;
  advanceSimulation(state, 0.25);
  assert.ok(state.money > before);
  assert.equal(getThroughputMbps(state), 10);
});

test('client upgrade increases demand and has escalating cost', () => {
  const state = createInitialState();
  const firstCost = getUpgradeCost(state, 'client');
  assert.equal(buyUpgrade(state, 'client').ok, true);
  assert.equal(state.client.trafficMbps, 15);
  assert.ok(getUpgradeCost(state, 'client') > firstCost);
});

test('link upgrade requires a built link', () => {
  const state = createInitialState();
  assert.deepEqual(buyUpgrade(state, 'link'), { ok: false, reason: 'link-required' });
});

test('speed multiplier changes simulated progress', () => {
  const slow = createInitialState();
  const fast = createInitialState();
  buildEthernet(slow); buildEthernet(fast);
  setSimulationSpeed(fast, 4);
  advanceSimulation(slow, 0.25);
  advanceSimulation(fast, 0.25);
  assert.ok(fast.stats.lifetimeRevenue > slow.stats.lifetimeRevenue);
});
