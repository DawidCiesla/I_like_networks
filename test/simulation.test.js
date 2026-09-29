import test from 'node:test';
import assert from 'node:assert/strict';

import {
  advanceSimulation,
  createInitialState,
  getAddBranchClientCost,
  getBottleneck,
  getBranchDemandMbps,
  getRouteTable,
  getRouterIngressMbps,
  getThroughputMbps,
} from '../src/simulation/model.js';

import {
  addBranchClient,
  buildBranchNetwork,
  buildEthernet,
  buildRouter,
  buildSecondaryServer,
  buildSwitch,
  buyUpgrade,
} from '../src/simulation/actions.js';

function fundedState() {
  const state = createInitialState();
  state.money = 10_000;
  buildEthernet(state);
  buildSwitch(state);
  return state;
}

test('router requires the switched LAN', () => {
  const state = createInitialState();
  assert.equal(buildRouter(state).reason, 'switch-required');

  state.money = 10_000;
  buildEthernet(state);
  buildSwitch(state);

  assert.equal(buildRouter(state).ok, true);
  assert.equal(state.router.built, true);
});

test('router initializes direct routes to LAN A and Server A', () => {
  const state = fundedState();
  buildRouter(state);

  const routes = getRouteTable(state);

  assert.equal(routes.length, 2);
  assert.equal(routes[0].destination, '10.0.1.0/24');
  assert.equal(routes[1].destination, '10.0.10.0/24');
});

test('LAN B adds a second source network and routing-table entry', () => {
  const state = fundedState();
  buildRouter(state);
  buildBranchNetwork(state);

  assert.equal(state.branch.built, true);
  assert.ok(getBranchDemandMbps(state) > 0);
  assert.ok(getRouteTable(state).some((route) => route.destination === '10.0.2.0/24'));
});

test('branch clients increase routed ingress', () => {
  const state = fundedState();
  buildRouter(state);
  buildBranchNetwork(state);

  const before = getRouterIngressMbps(state);
  const cost = getAddBranchClientCost(state);

  assert.equal(addBranchClient(state).ok, true);
  assert.ok(getRouterIngressMbps(state) > before);
  assert.ok(getAddBranchClientCost(state) > cost);
});

test('Server B adds a second destination and receives routed traffic', () => {
  const state = fundedState();
  buildRouter(state);
  buildBranchNetwork(state);
  buildSecondaryServer(state);

  for (let i = 0; i < 10; i += 1) advanceSimulation(state, 0.25);

  assert.ok(state.router.lastThroughputMbps.primary > 0);
  assert.ok(state.router.lastThroughputMbps.secondary > 0);
  assert.ok(getRouteTable(state).some((route) => route.destination === '10.0.20.0/24'));
});

test('router core becomes a bottleneck when combined ingress is too high', () => {
  const state = fundedState();
  buildRouter(state);
  buildBranchNetwork(state);

  state.client.count = 4;
  state.client.trafficMbps = 25;
  state.switch.capacityMbps = 200;
  state.link.capacityMbps = 200;

  state.branch.clientCount = 4;
  state.branch.clientTrafficMbps = 20;
  state.branch.linkCapacityMbps = 200;

  state.router.capacityMbps = 40;

  assert.equal(getBottleneck(state), 'router');

  for (let i = 0; i < 20; i += 1) advanceSimulation(state, 0.25);

  assert.ok(state.router.queueMb > 0);
});

test('routing preserves separate downstream bottlenecks', () => {
  const state = fundedState();
  buildRouter(state);
  buildBranchNetwork(state);
  buildSecondaryServer(state);

  state.client.count = 4;
  state.client.trafficMbps = 20;
  state.switch.capacityMbps = 200;
  state.link.capacityMbps = 200;
  state.branch.linkCapacityMbps = 200;
  state.router.capacityMbps = 200;

  state.server.capacityMbps = 20;
  state.secondaryServer.capacityMbps = 200;
  state.secondaryServer.linkCapacityMbps = 200;

  assert.equal(getBottleneck(state), 'server-a');

  for (let i = 0; i < 20; i += 1) advanceSimulation(state, 0.25);

  assert.ok(state.router.routeQueuesMb.primary > 0);
  assert.equal(state.router.routeQueuesMb.secondary, 0);
});

test('router upgrade increases routed core capacity', () => {
  const state = fundedState();
  buildRouter(state);

  const before = state.router.capacityMbps;
  assert.equal(buyUpgrade(state, 'router').ok, true);
  assert.ok(state.router.capacityMbps > before);
});

test('phase 2 behavior still works before the router is installed', () => {
  const state = fundedState();
  state.client.count = 4;
  state.client.trafficMbps = 20;
  state.link.capacityMbps = 15;
  state.server.capacityMbps = 100;

  for (let i = 0; i < 20; i += 1) advanceSimulation(state, 0.25);

  assert.ok(state.switch.queueMb > 0);
  assert.ok(getThroughputMbps(state) > 0);
});
