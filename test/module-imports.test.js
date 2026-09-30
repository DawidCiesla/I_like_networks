import test from 'node:test';
import assert from 'node:assert/strict';

test('browser-facing modules load without missing named exports', async () => {
  const plan = await import('../src/city/planGenerator.js');
  const cityModel = await import('../src/city/cityModel.js');
  const layout = await import('../src/render/transportLayout.js');
  const city = await import('../src/render/cityRenderer.js');
  const renderer = await import('../src/render/transportRenderer.js');
  const hud = await import('../src/ui/hud.js');
  const actions = await import('../src/simulation/actions.js');
  const storage = await import('../src/persistence/storage.js');

  assert.equal(typeof plan.generateCityMasterPlan, 'function');
  assert.equal(typeof cityModel.advanceCitySimulation, 'function');
  assert.equal(typeof layout.getBuiltRoute, 'function');
  assert.equal(typeof layout.getVehiclePoint, 'function');
  assert.equal(typeof city.drawCity, 'function');
  assert.equal(typeof city.getCityStage, 'function');
  assert.equal(typeof renderer.TransportRenderer, 'function');
  assert.equal(typeof hud.Hud, 'function');
  assert.equal(typeof actions.buildNextStop, 'function');
  assert.equal(typeof actions.buildDepot, 'function');
  assert.equal(typeof actions.buildLine2, 'function');
  assert.equal(typeof storage.loadState, 'function');
});
