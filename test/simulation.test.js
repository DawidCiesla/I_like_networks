import test from 'node:test';
import assert from 'node:assert/strict';

import {
  advanceSimulation,
  createInitialState,
  getAddClientCost,
  getBottleneck,
  getIncomePerSecond,
  getLatencyMs,
  getPacketLossPercent,
  getQueueFillRatio,
  getThroughputMbps,
  getTotalDemandMbps,
  getUpgradeCost,
} from '../src/simulation/model.js';

import {
  addClient,
  buildEthernet,
  buildSwitch,
  buyUpgrade,
  setSimulationSpeed,
} from '../src/simulation/actions.js';

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

test('switch requires Ethernet and enables additional clients', () => {
  const state = createInitialState();
  assert.equal(buildSwitch(state).reason, 'link-required');
  buildEthernet(state);
  state.money = 500;
  assert.equal(buildSwitch(state).ok, true);

  const cost = getAddClientCost(state);
  assert.equal(addClient(state).ok, true);
  assert.equal(state.client.count, 2);
  assert.ok(getAddClientCost(state) > cost);
});

test('aggregate demand grows with client count', () => {
  const state = createInitialState();
  state.client.count = 3;
  assert.equal(getTotalDemandMbps(state), 30);
});

test('overloaded uplink builds a queue and eventually drops traffic', () => {
  const state = createInitialState();
  buildEthernet(state);
  state.money = 500;
  buildSwitch(state);
  state.client.count = 4;
  state.switch.capacityMbps = 100;
  state.link.capacityMbps = 20;
  state.server.capacityMbps = 100;

  for (let i = 0; i < 40; i += 1) advanceSimulation(state, 0.25);

  assert.ok(state.switch.queueMb > 0);
  assert.ok(getQueueFillRatio(state) > 0);
  assert.ok(getLatencyMs(state) > 4);

  for (let i = 0; i < 40; i += 1) advanceSimulation(state, 0.25);

  assert.ok(state.switch.totalDroppedMb > 0);
  assert.ok(getPacketLossPercent(state) > 0);
  assert.equal(getBottleneck(state), 'link');
});

test('increasing link capacity drains the queue', () => {
  const state = createInitialState();
  buildEthernet(state);
  state.money = 1000;
  buildSwitch(state);
  state.client.count = 4;
  state.switch.capacityMbps = 100;
  state.server.capacityMbps = 100;
  state.link.capacityMbps = 20;

  for (let i = 0; i < 24; i += 1) advanceSimulation(state, 0.25);
  const queued = state.switch.queueMb;

  state.link.capacityMbps = 80;
  for (let i = 0; i < 12; i += 1) advanceSimulation(state, 0.25);

  assert.ok(state.switch.queueMb < queued);
});

test('phase 2 switch and buffer upgrades have escalating costs', () => {
  const state = createInitialState();
  buildEthernet(state);
  state.money = 1000;
  buildSwitch(state);

  const switchCost = getUpgradeCost(state, 'switch');
  const bufferCost = getUpgradeCost(state, 'buffer');

  assert.equal(buyUpgrade(state, 'switch').ok, true);
  assert.equal(buyUpgrade(state, 'buffer').ok, true);
  assert.ok(getUpgradeCost(state, 'switch') > switchCost);
  assert.ok(getUpgradeCost(state, 'buffer') > bufferCost);
});

test('speed multiplier changes simulated progress', () => {
  const slow = createInitialState();
  const fast = createInitialState();
  buildEthernet(slow);
  buildEthernet(fast);
  setSimulationSpeed(fast, 4);

  advanceSimulation(slow, 0.25);
  advanceSimulation(fast, 0.25);

  assert.ok(fast.stats.lifetimeRevenue > slow.stats.lifetimeRevenue);
});
