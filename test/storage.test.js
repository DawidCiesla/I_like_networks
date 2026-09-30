import test from 'node:test';
import assert from 'node:assert/strict';

import {
  GAME_VERSION,
  createInitialState,
} from '../src/simulation/model.js';

test('v11 save migrates into four-line station-aware schema without losing progression', async () => {
  const storageMap =
    new Map();

  globalThis.localStorage = {
    getItem(key) {
      return storageMap.has(key)
        ? storageMap.get(key)
        : null;
    },
    setItem(key, value) {
      storageMap.set(
        key,
        String(value),
      );
    },
    removeItem(key) {
      storageMap.delete(key);
    },
  };

  const old =
    createInitialState();

  old.version = 11;
  old.money = 4321;
  old.elapsedSeconds = 987;
  old.simulationSpeed = 2;

  old.city.version = 4;
  old.city.seed = 654321;

  old.line1.built = true;
  old.line1.stopCount = 4;
  old.line1.fleetCount = 3;
  old.line1.shelterLevel = 2;
  old.line1.catchmentLevel = 1;

  old.line2.built = true;
  old.line2.stopCount = 3;
  old.line2.fleetCount = 2;
  old.line2.shelterLevel = 1;
  old.line2.catchmentLevel = 3;

  old.depot.built = true;
  old.depot.garageSlots = 6;
  old.depot.level = 1;

  old.stats.lifetimeRevenue = 12345;
  old.stats.lifetimePassengers = 678;

  delete old.line3;
  delete old.line4;
  delete old.stations;

  storageMap.set(
    'i-like-transit.save',
    JSON.stringify(old),
  );

  const storage =
    await import(
      '../src/persistence/storage.js?migration-v11-v12'
    );

  const migrated =
    storage.loadState();

  assert.equal(
    migrated.version,
    GAME_VERSION,
  );

  assert.equal(
    migrated.version,
    12,
  );

  assert.equal(
    migrated.city.version,
    5,
  );

  assert.equal(
    migrated.city.seed,
    654321,
  );

  assert.equal(
    migrated.money,
    4321,
  );

  assert.equal(
    migrated.elapsedSeconds,
    987,
  );

  assert.equal(
    migrated.simulationSpeed,
    2,
  );

  assert.equal(
    migrated.line1.built,
    true,
  );

  assert.equal(
    migrated.line1.stopCount,
    4,
  );

  assert.equal(
    migrated.line1.fleetCount,
    3,
  );

  assert.equal(
    migrated.line2.built,
    true,
  );

  assert.equal(
    migrated.line2.stopCount,
    3,
  );

  assert.equal(
    migrated.line2.fleetCount,
    2,
  );

  assert.equal(
    migrated.line3.built,
    false,
  );

  assert.equal(
    migrated.line3.stopCount,
    0,
  );

  assert.equal(
    migrated.line4.built,
    false,
  );

  assert.equal(
    migrated.line4.stopCount,
    0,
  );

  assert.equal(
    migrated.stations[
      'old-town'
    ].level,
    2,
  );

  assert.equal(
    migrated.stations[
      'market-square'
    ].level,
    2,
  );

  assert.equal(
    migrated.stations[
      'city-park'
    ].level,
    3,
  );

  assert.equal(
    migrated.stations[
      'university'
    ].level,
    2,
  );

  assert.equal(
    migrated.stations[
      'riverside'
    ].level,
    3,
  );

  assert.equal(
    migrated.stations[
      'museum'
    ].level,
    3,
  );

  assert.equal(
    migrated.stations[
      'harbor'
    ].level,
    0,
  );

  assert.ok(
    migrated.depot.garageSlots
      >= migrated.line1.fleetCount
        + migrated.line2.fleetCount,
  );

  assert.equal(
    migrated.stats.lifetimeRevenue,
    12345,
  );

  assert.equal(
    migrated.stats.lifetimePassengers,
    678,
  );

  storage.saveState(
    migrated,
  );

  const reloaded =
    storage.loadState();

  assert.equal(
    reloaded.version,
    12,
  );

  assert.equal(
    reloaded.city.version,
    5,
  );

  assert.equal(
    reloaded.stations[
      'city-park'
    ].level,
    3,
  );

  assert.equal(
    reloaded.line3.built,
    false,
  );

  assert.equal(
    reloaded.line4.built,
    false,
  );
});
