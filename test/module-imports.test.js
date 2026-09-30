import test from 'node:test';
import assert from 'node:assert/strict';

test('browser-facing modules load without missing named exports', async () => {
  const renderer = await import('../src/render/transportRenderer.js');
  const hud = await import('../src/ui/hud.js');
  const actions = await import('../src/simulation/actions.js');
  const storage = await import('../src/persistence/storage.js');

  assert.equal(typeof renderer.TransportRenderer, 'function');
  assert.equal(typeof hud.Hud, 'function');
  assert.equal(typeof actions.buildNextStop, 'function');
  assert.equal(typeof actions.buildDepot, 'function');
  assert.equal(typeof actions.buildLine2, 'function');
  assert.equal(typeof storage.loadState, 'function');
});
