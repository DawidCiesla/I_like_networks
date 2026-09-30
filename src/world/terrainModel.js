export const TERRAIN_VERSION = 1;

const TAU = Math.PI * 2;

function hash32(value) {
  let hash = 2166136261;

  for (
    let index = 0;
    index < value.length;
    index += 1
  ) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(
      hash,
      16777619,
    );
  }

  return hash >>> 0;
}

function random01(
  seed,
  key,
) {
  return (
    hash32(
      `${seed}:${key}`,
    )
    / 0xffffffff
  );
}

function smoothstep(t) {
  return (
    t * t
    * (3 - 2 * t)
  );
}

function lerp(a, b, t) {
  return (
    a + (b - a) * t
  );
}

function latticeValue(
  seed,
  x,
  z,
  scale,
  channel,
) {
  const gx =
    Math.floor(x / scale);

  const gz =
    Math.floor(z / scale);

  const tx =
    smoothstep(
      x / scale - gx,
    );

  const tz =
    smoothstep(
      z / scale - gz,
    );

  const value = (
    ix,
    iz,
  ) => (
    random01(
      seed,
      `${channel}:${ix}:${iz}`,
    ) * 2 - 1
  );

  const a =
    lerp(
      value(gx, gz),
      value(gx + 1, gz),
      tx,
    );

  const b =
    lerp(
      value(gx, gz + 1),
      value(gx + 1, gz + 1),
      tx,
    );

  return lerp(a, b, tz);
}

function fbm(
  seed,
  x,
  z,
  {
    baseScale,
    octaves,
    channel,
  },
) {
  let value = 0;
  let amplitude = 1;
  let frequency = 1;
  let amplitudeTotal = 0;

  for (
    let octave = 0;
    octave < octaves;
    octave += 1
  ) {
    value +=
      latticeValue(
        seed,
        x,
        z,
        baseScale / frequency,
        `${channel}:${octave}`,
      )
      * amplitude;

    amplitudeTotal +=
      amplitude;

    amplitude *= 0.5;
    frequency *= 2;
  }

  return (
    amplitudeTotal <= 0
      ? 0
      : value / amplitudeTotal
  );
}

function seedPhase(
  seed,
  channel,
) {
  return (
    random01(
      seed,
      `phase:${channel}`,
    ) * TAU
  );
}

export function terrainHeight(
  seed,
  x,
  z,
) {
  const broad =
    fbm(
      seed,
      x,
      z,
      {
        baseScale: 1050,
        octaves: 4,
        channel: 'height-broad',
      },
    );

  const detail =
    fbm(
      seed,
      x,
      z,
      {
        baseScale: 340,
        octaves: 3,
        channel: 'height-detail',
      },
    );

  const ridge =
    Math.sin(
      x * 0.00125
      + z * 0.00072
      + seedPhase(
        seed,
        'ridge',
      ),
    );

  return (
    broad * 36
    + detail * 9
    + ridge * 5
  );
}

export function terrainSlopeDegrees(
  seed,
  x,
  z,
  sampleDistance = 12,
) {
  const left =
    terrainHeight(
      seed,
      x - sampleDistance,
      z,
    );

  const right =
    terrainHeight(
      seed,
      x + sampleDistance,
      z,
    );

  const back =
    terrainHeight(
      seed,
      x,
      z - sampleDistance,
    );

  const front =
    terrainHeight(
      seed,
      x,
      z + sampleDistance,
    );

  const dx =
    (right - left)
    / (sampleDistance * 2);

  const dz =
    (front - back)
    / (sampleDistance * 2);

  return (
    Math.atan(
      Math.hypot(dx, dz),
    ) * 180 / Math.PI
  );
}

export function terrainMoisture(
  seed,
  x,
  z,
) {
  return (
    fbm(
      seed,
      x + 791,
      z - 433,
      {
        baseScale: 720,
        octaves: 4,
        channel: 'moisture',
      },
    ) * 0.5 + 0.5
  );
}

export function terrainForestPotential(
  seed,
  x,
  z,
) {
  const noise =
    fbm(
      seed,
      x - 311,
      z + 907,
      {
        baseScale: 610,
        octaves: 4,
        channel: 'forest',
      },
    ) * 0.5 + 0.5;

  const moisture =
    terrainMoisture(
      seed,
      x,
      z,
    );

  const slope =
    terrainSlopeDegrees(
      seed,
      x,
      z,
    );

  const slopeBonus =
    Math.min(
      0.18,
      slope / 90,
    );

  return Math.max(
    0,
    Math.min(
      1,
      noise * 0.68
      + moisture * 0.32
      + slopeBonus,
    ),
  );
}

export function terrainBiome(
  seed,
  x,
  z,
) {
  const slope =
    terrainSlopeDegrees(
      seed,
      x,
      z,
    );

  const forest =
    terrainForestPotential(
      seed,
      x,
      z,
    );

  const moisture =
    terrainMoisture(
      seed,
      x,
      z,
    );

  if (slope >= 18) {
    return 'hillside';
  }

  if (forest >= 0.61) {
    return 'forest';
  }

  if (moisture >= 0.64) {
    return 'meadow';
  }

  return 'grassland';
}

export function analyzeRoadTerrain(
  seed,
  points,
  sampleStep = 28,
) {
  let totalLength = 0;
  let slopeWeighted = 0;
  let forestWeighted = 0;
  let maxSlope = 0;
  let samples = 0;

  for (
    let index = 0;
    index < points.length - 1;
    index += 1
  ) {
    const a =
      points[index];

    const b =
      points[index + 1];

    const length =
      Math.hypot(
        b.x - a.x,
        b.y - a.y,
      );

    const segmentSamples =
      Math.max(
        1,
        Math.ceil(
          length / sampleStep,
        ),
      );

    for (
      let sample = 0;
      sample <= segmentSamples;
      sample += 1
    ) {
      const t =
        sample / segmentSamples;

      const x =
        a.x
        + (b.x - a.x) * t;

      const z =
        a.y
        + (b.y - a.y) * t;

      const slope =
        terrainSlopeDegrees(
          seed,
          x,
          z,
        );

      const forest =
        terrainForestPotential(
          seed,
          x,
          z,
        );

      maxSlope =
        Math.max(
          maxSlope,
          slope,
        );

      slopeWeighted +=
        slope;

      forestWeighted +=
        forest;

      samples += 1;
    }

    totalLength +=
      length;
  }

  const averageSlope =
    samples <= 0
      ? 0
      : slopeWeighted / samples;

  const forestShare =
    samples <= 0
      ? 0
      : forestWeighted / samples;

  return {
    totalLength,
    averageSlope,
    maxSlope,
    forestShare,
    blocked:
      maxSlope > 22,
    score:
      averageSlope * 1.8
      + forestShare * 8,
  };
}

export function parcelTerrainSuitability(
  seed,
  x,
  z,
) {
  const slope =
    terrainSlopeDegrees(
      seed,
      x,
      z,
    );

  const forest =
    terrainForestPotential(
      seed,
      x,
      z,
    );

  return {
    slope,
    forest,
    buildable:
      slope < 17,
    developmentPenalty:
      Math.min(
        1.25,
        slope / 24
        + Math.max(
          0,
          forest - 0.5,
        ) * 0.9,
      ),
  };
}

export function terrainColorSample(
  seed,
  x,
  z,
) {
  const biome =
    terrainBiome(
      seed,
      x,
      z,
    );

  if (biome === 'forest') {
    return {
      r: 0.18,
      g: 0.31,
      b: 0.18,
    };
  }

  if (biome === 'meadow') {
    return {
      r: 0.34,
      g: 0.46,
      b: 0.24,
    };
  }

  if (biome === 'hillside') {
    return {
      r: 0.31,
      g: 0.34,
      b: 0.25,
    };
  }

  return {
    r: 0.26,
    g: 0.38,
    b: 0.22,
  };
}
