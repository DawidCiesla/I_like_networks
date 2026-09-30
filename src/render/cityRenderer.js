import {
  WORLD,
  getDepotSpurRoute,
  getSegmentRoute,
  pointOnRoute,
  routeMetrics,
} from './transportLayout.js';

const ROAD_SURFACE = '#303233';
const ROAD_EDGE = '#525653';
const SIDEWALK = '#777a74';
const ROAD_MARKING = '#b9ad6a';

const clamp = (value, min, max) =>
  Math.min(max, Math.max(min, value));

export function getCityStage(state) {
  if (!state.line1.built) return 0;
  if (state.line1.stopCount < 3) return 1;
  if (state.line1.stopCount < 4) return 2;
  if (state.line1.stopCount < 5) return 3;
  if (!state.line2.built) return 4;
  if (state.line2.stopCount < 3) return 5;
  if (state.line2.stopCount < 4) return 6;
  return 7;
}

function traceRoute(ctx, metrics) {
  if (!metrics?.points?.length) return;

  ctx.beginPath();
  ctx.moveTo(
    metrics.points[0].x,
    metrics.points[0].y,
  );

  for (
    let index = 1;
    index < metrics.points.length;
    index += 1
  ) {
    ctx.lineTo(
      metrics.points[index].x,
      metrics.points[index].y,
    );
  }
}

function drawRoad(
  ctx,
  metrics,
  { local = false } = {},
) {
  if (!metrics || metrics.points.length < 2) return;

  ctx.save();
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';

  ctx.strokeStyle = SIDEWALK;
  ctx.lineWidth = local ? 22 : 42;
  traceRoute(ctx, metrics);
  ctx.stroke();

  ctx.strokeStyle = ROAD_EDGE;
  ctx.lineWidth = local ? 18 : 36;
  traceRoute(ctx, metrics);
  ctx.stroke();

  ctx.strokeStyle = ROAD_SURFACE;
  ctx.lineWidth = local ? 14 : 31;
  traceRoute(ctx, metrics);
  ctx.stroke();

  if (!local) {
    ctx.setLineDash([9, 13]);
    ctx.strokeStyle = ROAD_MARKING;
    ctx.globalAlpha = 0.5;
    ctx.lineWidth = 1.2;
    traceRoute(ctx, metrics);
    ctx.stroke();
  }

  ctx.restore();
}

function localRoad(points) {
  return routeMetrics(points);
}

function district(
  key,
  lineKey,
  stopIndex,
  minStage,
  theme,
  sites,
  roads = [],
) {
  return {
    key,
    lineKey,
    stopIndex,
    minStage,
    theme,
    sites,
    roads,
  };
}

const DISTRICT_PLANS = Object.freeze([
  district(
    'oldTown',
    'line1',
    0,
    0,
    'residential',
    [
      [-92, -72],
      [-28, -82],
      [42, -76],
      [104, -66],
      [-100, 82],
      [-36, 92],
      [40, 88],
      [108, 76],
    ],
    [
      [[-125, -118], [-125, 118]],
      [[-125, -118], [105, -118]],
    ],
  ),
  district(
    'market',
    'line1',
    1,
    1,
    'mixed',
    [
      [-88, -78],
      [-22, -86],
      [52, -76],
      [112, -62],
      [-92, 86],
      [-20, 96],
      [54, 86],
    ],
    [
      [[-115, 122], [118, 122]],
      [[118, 122], [118, 34]],
    ],
  ),
  district(
    'park',
    'line1',
    2,
    2,
    'park',
    [
      [-116, 84],
      [-46, 104],
      [98, 92],
    ],
    [
      [[-138, 132], [132, 132]],
    ],
  ),
  district(
    'university',
    'line1',
    3,
    3,
    'campus',
    [
      [-100, -88],
      [-26, -98],
      [56, -90],
      [112, -72],
      [-104, 88],
      [10, 102],
      [96, 82],
    ],
    [
      [[-132, 126], [126, 126]],
      [[126, 126], [126, 42]],
    ],
  ),
  district(
    'central',
    'line1',
    4,
    4,
    'central',
    [
      [-116, -98],
      [-42, -112],
      [42, -106],
      [116, -88],
      [-112, 94],
      [-34, 108],
      [48, 104],
      [122, 90],
    ],
    [
      [[-145, 140], [145, 140]],
      [[145, 140], [145, -132]],
      [[-142, -142], [142, -142]],
    ],
  ),
  district(
    'riverside',
    'line2',
    1,
    5,
    'riverside',
    [
      [-106, -82],
      [-34, -96],
      [64, -84],
      [-104, 86],
      [-30, 98],
      [72, 88],
    ],
    [
      [[-132, 128], [126, 128]],
    ],
  ),
  district(
    'museum',
    'line2',
    2,
    6,
    'mixed',
    [
      [-110, -84],
      [-34, -100],
      [54, -90],
      [112, -72],
      [-104, 90],
      [-24, 106],
      [64, 92],
    ],
    [
      [[-136, 132], [136, 132]],
      [[136, 132], [136, 42]],
    ],
  ),
  district(
    'harbor',
    'line2',
    3,
    7,
    'industrial',
    [
      [-112, -86],
      [-34, -98],
      [66, -88],
      [124, -62],
      [-106, 92],
      [-12, 104],
      [92, 86],
    ],
    [
      [[-150, 132], [148, 132]],
      [[148, 132], [148, -120]],
    ],
  ),
]);

function getStop(plan) {
  return WORLD[plan.lineKey + 'Stops'][plan.stopIndex];
}

function isDistrictActive(state, plan) {
  if (plan.lineKey === 'line1') {
    return state.line1.stopCount > plan.stopIndex;
  }

  return (
    state.line2.built
    && state.line2.stopCount > plan.stopIndex
  );
}

function getActivePlans(state) {
  return DISTRICT_PLANS.filter(
    (plan) => isDistrictActive(state, plan),
  );
}

function getMainRoads(state) {
  const roads = [];

  const line1Segments = Math.min(
    4,
    state.line1.stopCount,
  );

  for (
    let segment = 0;
    segment < line1Segments;
    segment += 1
  ) {
    roads.push({
      metrics: getSegmentRoute(
        'line1',
        segment,
        segment + 1,
      ),
      local: false,
    });
  }

  if (state.line2.built) {
    const line2Segments = Math.min(
      3,
      Math.max(
        1,
        state.line2.stopCount - 1,
      ),
    );

    for (
      let segment = 0;
      segment < line2Segments;
      segment += 1
    ) {
      roads.push({
        metrics: getSegmentRoute(
          'line2',
          segment,
          segment + 1,
        ),
        local: false,
      });
    }
  }

  if (
    state.line1.stopCount >= 3
    || state.depot.built
  ) {
    roads.push({
      metrics: getDepotSpurRoute(),
      local: true,
    });
  }

  return roads;
}

function getSecondaryRoads(state) {
  const roads = [];

  for (const plan of getActivePlans(state)) {
    const stop = getStop(plan);

    for (const points of plan.roads) {
      roads.push({
        metrics: localRoad(
          points.map(([dx, dy]) => ({
            x: stop.x + dx,
            y: stop.y + dy,
          })),
        ),
        local: true,
      });
    }
  }

  return roads;
}

function distancePointToSegment(
  point,
  a,
  b,
) {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const lengthSquared =
    dx * dx + dy * dy;

  if (lengthSquared <= 1e-9) {
    return Math.hypot(
      point.x - a.x,
      point.y - a.y,
    );
  }

  const t = clamp(
    (
      (point.x - a.x) * dx
      + (point.y - a.y) * dy
    ) / lengthSquared,
    0,
    1,
  );

  return Math.hypot(
    point.x - (a.x + dx * t),
    point.y - (a.y + dy * t),
  );
}

function distancePointToRoute(
  point,
  metrics,
) {
  if (!metrics?.segments?.length) {
    return Number.POSITIVE_INFINITY;
  }

  let minimum =
    Number.POSITIVE_INFINITY;

  for (const segment of metrics.segments) {
    minimum = Math.min(
      minimum,
      distancePointToSegment(
        point,
        segment.a,
        segment.b,
      ),
    );
  }

  return minimum;
}

function buildingProfile(
  theme,
  stage,
  index,
) {
  if (theme === 'industrial') {
    return {
      kind:
        index % 3 === 0
          ? 'warehouse'
          : 'workshop',
      floors:
        index % 4 === 0
          ? 2
          : 1,
    };
  }

  if (theme === 'campus') {
    return {
      kind:
        index % 3 === 0
          ? 'campus'
          : 'apartment',
      floors:
        stage >= 6 ? 4 : 3,
    };
  }

  if (theme === 'central') {
    if (
      stage >= 7
      && index % 3 === 0
    ) {
      return {
        kind: 'tower',
        floors: 8 + (index % 4),
      };
    }

    return {
      kind:
        stage >= 5
          ? 'midrise'
          : 'apartment',
      floors:
        stage >= 5
          ? 5 + (index % 2)
          : 3,
    };
  }

  if (theme === 'mixed') {
    if (
      stage >= 5
      && index % 4 === 0
    ) {
      return {
        kind: 'midrise',
        floors: 4,
      };
    }

    return {
      kind:
        index % 3 === 1
          ? 'shop'
          : stage >= 3
            ? 'apartment'
            : 'townhouse',
      floors:
        stage >= 3
          ? 2 + (index % 2)
          : 1,
    };
  }

  if (theme === 'riverside') {
    return {
      kind:
        stage >= 6
        && index % 2 === 0
          ? 'apartment'
          : 'townhouse',
      floors:
        stage >= 6
          ? 3
          : 2,
    };
  }

  if (theme === 'park') {
    return {
      kind:
        index === 1
          ? 'cafe'
          : 'townhouse',
      floors: 1,
    };
  }

  return {
    kind:
      stage >= 4
      && index % 4 === 0
        ? 'apartment'
        : stage >= 2
          ? 'townhouse'
          : 'house',
    floors:
      stage >= 4
      && index % 4 === 0
        ? 3
        : stage >= 2
          ? 2
          : 1,
  };
}

function buildingSize(profile) {
  if (profile.kind === 'tower') {
    return { w: 34, h: 34 };
  }

  if (
    profile.kind === 'midrise'
    || profile.kind === 'apartment'
  ) {
    return { w: 40, h: 32 };
  }

  if (
    profile.kind === 'warehouse'
    || profile.kind === 'campus'
  ) {
    return { w: 52, h: 32 };
  }

  if (
    profile.kind === 'shop'
    || profile.kind === 'cafe'
  ) {
    return { w: 34, h: 26 };
  }

  return { w: 30, h: 26 };
}

function boxForSite(
  x,
  y,
  profile,
) {
  const { w, h } =
    buildingSize(profile);

  const lift =
    Math.max(
      0,
      profile.floors - 1,
    ) * 4;

  return {
    x:
      x - w / 2 - 4,
    y:
      y - h / 2 - lift - 8,
    w: w + 8,
    h: h + lift + 12,
  };
}

function boxesOverlap(
  a,
  b,
  margin = 8,
) {
  return !(
    a.x + a.w + margin < b.x
    || b.x + b.w + margin < a.x
    || a.y + a.h + margin < b.y
    || b.y + b.h + margin < a.y
  );
}

function getStopPoints(state) {
  const stops = [];

  for (
    let index = 0;
    index < state.line1.stopCount;
    index += 1
  ) {
    stops.push(
      WORLD.line1Stops[index],
    );
  }

  if (state.line2.built) {
    for (
      let index = 1;
      index < state.line2.stopCount;
      index += 1
    ) {
      stops.push(
        WORLD.line2Stops[index],
      );
    }
  }

  return stops;
}

export function getCityLots(state) {
  const stage =
    getCityStage(state);

  const roadRoutes = [
    ...getMainRoads(state),
    ...getSecondaryRoads(state),
  ];

  const stops =
    getStopPoints(state);

  const accepted = [];

  for (const plan of getActivePlans(state)) {
    const stop = getStop(plan);

    plan.sites.forEach(
      ([dx, dy], index) => {
        if (
          stage === plan.minStage
          && index >= 4
        ) {
          return;
        }

        const profile =
          buildingProfile(
            plan.theme,
            stage,
            index,
          );

        const x = stop.x + dx;
        const y = stop.y + dy;
        const box =
          boxForSite(
            x,
            y,
            profile,
          );

        const halfSpan =
          Math.max(
            box.w,
            box.h,
          ) / 2;

        const roadCollision =
          roadRoutes.some(
            ({ metrics, local }) =>
              distancePointToRoute(
                { x, y },
                metrics,
              )
              < halfSpan
                + (local ? 19 : 27),
          );

        if (roadCollision) return;

        const stopCollision =
          stops.some(
            (candidate) =>
              Math.hypot(
                x - candidate.x,
                y - candidate.y,
              ) < 58,
          );

        if (stopCollision) return;

        const depotCollision =
          (
            state.line1.stopCount >= 3
            || state.depot.built
          )
          && Math.abs(
            x - WORLD.depot.x,
          ) < 90
          && Math.abs(
            y - WORLD.depot.y,
          ) < 72;

        if (depotCollision) return;

        if (
          accepted.some(
            (site) =>
              boxesOverlap(
                box,
                site.box,
              ),
          )
        ) {
          return;
        }

        accepted.push({
          key:
            plan.key + '-' + index,
          x,
          y,
          profile,
          theme: plan.theme,
          box,
        });
      },
    );
  }

  return accepted;
}

function drawBuilding(
  ctx,
  site,
  stage,
) {
  const {
    x,
    y,
    profile,
  } = site;

  const { w, h } =
    buildingSize(profile);

  const verticalLift =
    Math.max(
      0,
      profile.floors - 1,
    ) * 4;

  ctx.save();

  ctx.fillStyle = '#111';
  ctx.fillRect(
    x - w / 2 - 3,
    y - h / 2 - verticalLift - 3,
    w + 6,
    h + verticalLift + 6,
  );

  const wall =
    profile.kind === 'warehouse'
      ? '#70736f'
      : profile.kind === 'tower'
        ? '#a3a9aa'
        : profile.kind === 'campus'
          ? '#828d90'
          : profile.kind === 'shop'
            || profile.kind === 'cafe'
            ? '#8e8174'
            : '#918d82';

  ctx.fillStyle = wall;
  ctx.fillRect(
    x - w / 2,
    y - h / 2 - verticalLift,
    w,
    h + verticalLift,
  );

  if (
    profile.kind === 'house'
    || profile.kind === 'townhouse'
  ) {
    ctx.fillStyle = '#625c55';
    ctx.beginPath();
    ctx.moveTo(
      x - w / 2 - 2,
      y - h / 2 - verticalLift,
    );
    ctx.lineTo(
      x,
      y - h / 2 - verticalLift - 9,
    );
    ctx.lineTo(
      x + w / 2 + 2,
      y - h / 2 - verticalLift,
    );
    ctx.closePath();
    ctx.fill();
  }

  const rows = clamp(
    profile.floors,
    1,
    8,
  );

  const columns = Math.max(
    2,
    Math.floor(w / 14),
  );

  for (
    let row = 0;
    row < rows;
    row += 1
  ) {
    for (
      let col = 0;
      col < columns;
      col += 1
    ) {
      const wx =
        x - w / 2 + 6
        + col * 12;

      const wy =
        y + h / 2 - 13
        - row * 8;

      if (
        wx + 5
        >= x + w / 2 - 3
      ) {
        continue;
      }

      ctx.fillStyle =
        (
          (
            row * 5
            + col * 3
            + site.key.length
            + stage
          ) % 5
        ) < 2
          ? '#d2c46a'
          : '#30383a';

      ctx.fillRect(
        wx,
        wy,
        5,
        4,
      );
    }
  }

  if (
    profile.kind === 'shop'
    || profile.kind === 'cafe'
  ) {
    ctx.fillStyle = '#30444a';
    ctx.fillRect(
      x - w / 2 + 4,
      y + h / 2 - 10,
      w - 8,
      6,
    );
  }

  if (profile.kind === 'tower') {
    ctx.fillStyle = '#c7c8c2';
    ctx.fillRect(
      x - 2,
      y - h / 2 - verticalLift - 8,
      4,
      8,
    );
  }

  ctx.restore();
}

function drawTree(
  ctx,
  x,
  y,
  seed = 0,
) {
  ctx.fillStyle = '#463b2e';
  ctx.fillRect(
    x - 2,
    y,
    4,
    8,
  );

  ctx.fillStyle =
    seed % 2 === 0
      ? '#2e6d3c'
      : '#397949';

  ctx.fillRect(
    x - 6,
    y - 8,
    12,
    10,
  );

  ctx.fillRect(
    x - 4,
    y - 12,
    8,
    5,
  );
}

function drawCityPark(ctx) {
  const stop =
    WORLD.line1Stops[2];

  const x = stop.x - 86;
  const y = stop.y - 100;
  const w = 92;
  const h = 58;

  ctx.fillStyle = '#24352a';
  ctx.fillRect(
    x,
    y,
    w,
    h,
  );

  ctx.strokeStyle = '#45644c';
  ctx.lineWidth = 2;
  ctx.strokeRect(
    x,
    y,
    w,
    h,
  );

  for (
    let index = 0;
    index < 6;
    index += 1
  ) {
    drawTree(
      ctx,
      x + 16 + (index % 3) * 28,
      y + 22 + Math.floor(index / 3) * 25,
      index,
    );
  }
}

function drawCrosswalk(
  ctx,
  x,
  y,
  horizontal = true,
) {
  ctx.save();
  ctx.fillStyle = '#c7c7bf';
  ctx.globalAlpha = 0.5;

  for (
    let index = -2;
    index <= 2;
    index += 1
  ) {
    if (horizontal) {
      ctx.fillRect(
        x - 8,
        y + index * 4,
        16,
        2,
      );
    } else {
      ctx.fillRect(
        x + index * 4,
        y - 8,
        2,
        16,
      );
    }
  }

  ctx.restore();
}

function drawAmbientCars(
  ctx,
  roadRoutes,
  stage,
  timeSeconds,
) {
  const primaryRoads =
    roadRoutes.filter(
      (road) => !road.local,
    );

  if (primaryRoads.length === 0) {
    return;
  }

  const carCount = clamp(
    1 + Math.floor(stage / 2),
    1,
    4,
  );

  for (
    let index = 0;
    index < carCount;
    index += 1
  ) {
    const route =
      primaryRoads[
        index % primaryRoads.length
      ].metrics;

    const distanceAlong =
      (
        timeSeconds
          * (17 + index * 3)
        + index * 91
      ) % route.total;

    const point =
      pointOnRoute(
        route,
        distanceAlong,
      );

    const angle =
      Math.atan2(
        point.ty,
        point.tx,
      );

    ctx.save();
    ctx.translate(
      point.x,
      point.y,
    );
    ctx.rotate(angle);

    ctx.fillStyle = '#0d0d0d';
    ctx.fillRect(
      -7,
      -4,
      14,
      8,
    );

    ctx.fillStyle =
      index % 2 === 0
        ? '#858b8a'
        : '#77665f';

    ctx.fillRect(
      -6,
      -3,
      12,
      6,
    );

    ctx.fillStyle = '#c6d6d7';
    ctx.fillRect(
      -2,
      -2,
      4,
      3,
    );

    ctx.restore();
  }
}

export function drawCity(
  ctx,
  state,
  timeSeconds,
) {
  const stage =
    getCityStage(state);

  const mainRoads =
    getMainRoads(state);

  const secondaryRoads =
    getSecondaryRoads(state);

  for (const road of secondaryRoads) {
    drawRoad(
      ctx,
      road.metrics,
      { local: true },
    );
  }

  for (const road of mainRoads) {
    drawRoad(
      ctx,
      road.metrics,
      { local: road.local },
    );
  }

  if (state.line1.stopCount >= 3) {
    drawCityPark(ctx);
  }

  for (const lot of getCityLots(state)) {
    drawBuilding(
      ctx,
      lot,
      stage,
    );
  }

  const stops =
    getStopPoints(state);

  stops.forEach(
    (stop, index) => {
      drawCrosswalk(
        ctx,
        stop.x,
        stop.y,
        index % 2 === 0,
      );
    },
  );

  drawAmbientCars(
    ctx,
    mainRoads,
    stage,
    timeSeconds,
  );
}
