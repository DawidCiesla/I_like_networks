const clamp = (value, min, max) =>
  Math.min(max, Math.max(min, value));

export const WORLD = Object.freeze({
  line1Stops: [
    { x: -430, y: 90, w: 58, h: 64 },
    { x: -315, y: 90, w: 58, h: 64 },
    { x: -205, y: -20, w: 58, h: 64 },
    { x: -25, y: -85, w: 58, h: 64 },
    { x: 190, y: -140, w: 66, h: 70 },
  ],
  line2Stops: [
    { x: -205, y: -20, w: 58, h: 64 },
    { x: -115, y: 120, w: 58, h: 64 },
    { x: 45, y: 185, w: 58, h: 64 },
    { x: 245, y: 125, w: 66, h: 70 },
  ],
  depot: {
    x: -355,
    y: 180,
    w: 118,
    h: 86,
  },
});

const RAW_SEGMENTS = Object.freeze({
  line1: [
    [
      { x: -430, y: 90 },
      { x: -315, y: 90 },
    ],
    [
      { x: -315, y: 90 },
      { x: -255, y: 90 },
      { x: -255, y: -20 },
      { x: -205, y: -20 },
    ],
    [
      { x: -205, y: -20 },
      { x: -110, y: -20 },
      { x: -110, y: -85 },
      { x: -25, y: -85 },
    ],
    [
      { x: -25, y: -85 },
      { x: 70, y: -85 },
      { x: 70, y: -140 },
      { x: 190, y: -140 },
    ],
  ],
  line2: [
    [
      { x: -205, y: -20 },
      { x: -205, y: 55 },
      { x: -115, y: 55 },
      { x: -115, y: 120 },
    ],
    [
      { x: -115, y: 120 },
      { x: -55, y: 120 },
      { x: -55, y: 185 },
      { x: 45, y: 185 },
    ],
    [
      { x: 45, y: 185 },
      { x: 140, y: 185 },
      { x: 140, y: 125 },
      { x: 245, y: 125 },
    ],
  ],
});

const DEPOT_SPUR_POINTS = Object.freeze([
  { x: -205, y: -20 },
  { x: -300, y: -20 },
  { x: -300, y: 120 },
  { x: -355, y: 137 },
]);

function distance(a, b) {
  return Math.hypot(
    b.x - a.x,
    b.y - a.y,
  );
}

function pointToward(from, to, amount) {
  const total = distance(from, to);

  if (total <= 1e-6) {
    return { ...from };
  }

  const ratio = amount / total;

  return {
    x: from.x + (to.x - from.x) * ratio,
    y: from.y + (to.y - from.y) * ratio,
  };
}

function roundedPolyline(
  points,
  radius = 24,
  steps = 5,
) {
  if (points.length <= 2) {
    return points.map((point) => ({ ...point }));
  }

  const result = [{ ...points[0] }];

  for (
    let index = 1;
    index < points.length - 1;
    index += 1
  ) {
    const previous = points[index - 1];
    const corner = points[index];
    const next = points[index + 1];

    const incoming = distance(previous, corner);
    const outgoing = distance(corner, next);

    const effectiveRadius = Math.min(
      radius,
      incoming * 0.38,
      outgoing * 0.38,
    );

    const entry = pointToward(
      corner,
      previous,
      effectiveRadius,
    );

    const exit = pointToward(
      corner,
      next,
      effectiveRadius,
    );

    result.push(entry);

    for (
      let step = 1;
      step <= steps;
      step += 1
    ) {
      const t = step / steps;
      const inv = 1 - t;

      result.push({
        x:
          inv * inv * entry.x
          + 2 * inv * t * corner.x
          + t * t * exit.x,
        y:
          inv * inv * entry.y
          + 2 * inv * t * corner.y
          + t * t * exit.y,
      });
    }
  }

  result.push({
    ...points[points.length - 1],
  });

  return result;
}

export function routeMetrics(points) {
  const segments = [];
  let total = 0;

  for (
    let index = 0;
    index < points.length - 1;
    index += 1
  ) {
    const a = points[index];
    const b = points[index + 1];
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length = Math.hypot(dx, dy);

    if (length <= 1e-6) continue;

    segments.push({
      a,
      b,
      dx,
      dy,
      length,
      start: total,
    });

    total += length;
  }

  return {
    points,
    segments,
    total,
  };
}

function metricsForPolyline(points) {
  return routeMetrics(
    roundedPolyline(points),
  );
}

export function pointOnRoute(metrics, distanceAlong) {
  if (
    !metrics
    || metrics.total <= 0
    || metrics.segments.length === 0
  ) {
    const point =
      metrics?.points?.[0]
      ?? { x: 0, y: 0 };

    return {
      x: point.x,
      y: point.y,
      tx: 1,
      ty: 0,
    };
  }

  const target = clamp(
    distanceAlong,
    0,
    metrics.total,
  );

  const segment =
    metrics.segments.find(
      (candidate) =>
        target
        <= candidate.start + candidate.length,
    )
    ?? metrics.segments.at(-1);

  const local =
    (target - segment.start)
    / segment.length;

  return {
    x: segment.a.x + segment.dx * local,
    y: segment.a.y + segment.dy * local,
    tx: segment.dx / segment.length,
    ty: segment.dy / segment.length,
  };
}

export function getSegmentRoute(
  lineKey,
  fromStopIndex,
  toStopIndex,
) {
  const segmentIndex = Math.min(
    fromStopIndex,
    toStopIndex,
  );

  const raw =
    RAW_SEGMENTS[lineKey]?.[segmentIndex];

  if (!raw) {
    throw new Error(
      `Unknown route segment: ${lineKey} ${fromStopIndex}->${toStopIndex}`,
    );
  }

  const points =
    fromStopIndex <= toStopIndex
      ? raw
      : [...raw].reverse();

  return metricsForPolyline(points);
}

export function getBuiltRoute(
  lineKey,
  stopCount,
) {
  const segmentCount = Math.max(
    0,
    stopCount - 1,
  );

  if (segmentCount === 0) {
    const stop =
      lineKey === 'line1'
        ? WORLD.line1Stops[0]
        : WORLD.line2Stops[0];

    return routeMetrics([
      { x: stop.x, y: stop.y },
    ]);
  }

  const merged = [];

  for (
    let segmentIndex = 0;
    segmentIndex < segmentCount;
    segmentIndex += 1
  ) {
    const rounded = roundedPolyline(
      RAW_SEGMENTS[lineKey][segmentIndex],
    );

    for (
      let pointIndex = 0;
      pointIndex < rounded.length;
      pointIndex += 1
    ) {
      if (
        segmentIndex > 0
        && pointIndex === 0
      ) {
        continue;
      }

      merged.push(rounded[pointIndex]);
    }
  }

  return routeMetrics(merged);
}

export function getFutureSegmentRoute(
  lineKey,
  builtStopCount,
) {
  return getSegmentRoute(
    lineKey,
    builtStopCount - 1,
    builtStopCount,
  );
}

export function getVehiclePoint(
  lineKey,
  vehicle,
) {
  const stopRects =
    lineKey === 'line1'
      ? WORLD.line1Stops
      : WORLD.line2Stops;

  const current =
    stopRects[vehicle.currentStopIndex]
    ?? stopRects[0];

  if (
    vehicle.phase !== 'travel'
    || vehicle.nextStopIndex == null
  ) {
    const candidateNext =
      vehicle.currentStopIndex
      + (vehicle.direction >= 0 ? 1 : -1);

    if (
      candidateNext >= 0
      && candidateNext < stopRects.length
    ) {
      const stationaryRoute =
        getSegmentRoute(
          lineKey,
          vehicle.currentStopIndex,
          candidateNext,
        );

      return pointOnRoute(
        stationaryRoute,
        0,
      );
    }

    return {
      x: current.x,
      y: current.y,
      tx: vehicle.direction >= 0 ? 1 : -1,
      ty: 0,
    };
  }

  const route = getSegmentRoute(
    lineKey,
    vehicle.currentStopIndex,
    vehicle.nextStopIndex,
  );

  const duration = Math.max(
    1e-6,
    vehicle.phaseDurationMinutes ?? 1,
  );

  const progress = clamp(
    1
      - (vehicle.phaseMinutesRemaining ?? 0)
        / duration,
    0,
    1,
  );

  return pointOnRoute(
    route,
    route.total * progress,
  );
}

export function getDepotSpurRoute() {
  return metricsForPolyline(
    DEPOT_SPUR_POINTS,
  );
}
