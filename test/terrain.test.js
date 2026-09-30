import test from 'node:test';
import assert from 'node:assert/strict';

import {
  analyzeRoadTerrain,
  parcelTerrainSuitability,
  terrainBiome,
  terrainForestPotential,
  terrainHeight,
  terrainSlopeDegrees,
} from '../src/world/terrainModel.js';

test('terrain is deterministic for the same seed and coordinates', () => {
  const first =
    terrainHeight(
      284731,
      420,
      -180,
    );

  const second =
    terrainHeight(
      284731,
      420,
      -180,
    );

  assert.equal(first, second);

  assert.equal(
    terrainBiome(
      284731,
      420,
      -180,
    ),
    terrainBiome(
      284731,
      420,
      -180,
    ),
  );
});

test('different terrain seeds produce different landscapes', () => {
  const first =
    terrainHeight(
      284731,
      800,
      900,
    );

  const second =
    terrainHeight(
      284732,
      800,
      900,
    );

  assert.notEqual(first, second);
});

test('terrain slope and forest potential stay in sane numeric ranges', () => {
  for (
    const [x, z]
    of [
      [0, 0],
      [500, 200],
      [-900, 700],
      [1400, -600],
    ]
  ) {
    const slope =
      terrainSlopeDegrees(
        284731,
        x,
        z,
      );

    const forest =
      terrainForestPotential(
        284731,
        x,
        z,
      );

    assert.ok(
      Number.isFinite(slope)
      && slope >= 0
      && slope < 45,
    );

    assert.ok(
      Number.isFinite(forest)
      && forest >= 0
      && forest <= 1,
    );
  }
});

test('road terrain analysis flags extreme synthetic climbs and scores normal terrain', () => {
  const analysis =
    analyzeRoadTerrain(
      284731,
      [
        { x: -600, y: -300 },
        { x: -200, y: -300 },
        { x: 200, y: -300 },
      ],
    );

  assert.ok(
    Number.isFinite(
      analysis.score,
    ),
  );

  assert.ok(
    analysis.totalLength > 700,
  );
});

test('parcel suitability returns explicit buildability and development penalty', () => {
  const result =
    parcelTerrainSuitability(
      284731,
      100,
      100,
    );

  assert.equal(
    typeof result.buildable,
    'boolean',
  );

  assert.ok(
    result.developmentPenalty
      >= 0,
  );

  assert.ok(
    Number.isFinite(
      result.slope,
    ),
  );
});
