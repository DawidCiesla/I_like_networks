import test from 'node:test';
import assert from 'node:assert/strict';

test('browser-facing modules load without missing named exports', async () => {
  const terrain = await import('../src/world/terrainModel.js');
  const topology = await import('../src/city/roadTopology.js');
  const plan = await import('../src/city/planGenerator.js');
  const cityModel = await import('../src/city/cityModel.js');
  const layout = await import('../src/render/transportLayout.js');
  const city = await import('../src/render/cityRenderer.js');
  const renderer = await import('../src/render/transportRenderer.js');
  const threeRenderer = await import('../src/render/threeTransportRenderer.js');
  const hud = await import('../src/ui/hud.js');
  const actions = await import('../src/simulation/actions.js');
  const storage = await import('../src/persistence/storage.js');

  assert.equal(typeof terrain.terrainHeight, 'function');
  assert.equal(typeof terrain.terrainBiome, 'function');
  assert.equal(typeof topology.compileRoadGraph, 'function');
  assert.equal(typeof topology.validateRoadCandidate, 'function');
  assert.equal(typeof plan.generateCityMasterPlan, 'function');
  assert.equal(typeof cityModel.advanceCitySimulation, 'function');
  assert.equal(typeof layout.getBuiltRoute, 'function');
  assert.equal(typeof layout.getVehiclePoint, 'function');
  assert.equal(typeof city.drawCity, 'function');
  assert.equal(typeof city.getCityStage, 'function');
  assert.equal(typeof renderer.TransportRenderer, 'function');
  assert.equal(typeof threeRenderer.ThreeTransportRenderer, 'function');
  assert.equal(typeof hud.Hud, 'function');
  assert.equal(typeof actions.buildNextStop, 'function');
  assert.equal(typeof actions.buildDepot, 'function');
  assert.equal(typeof actions.buildLine2, 'function');
  assert.equal(typeof actions.buildLine3, 'function');
  assert.equal(typeof actions.buildLine4, 'function');
  assert.equal(typeof actions.upgradeStation, 'function');
  assert.equal(typeof storage.loadState, 'function');
});
