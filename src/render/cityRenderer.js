import {
  WORLD,
  getDepotSpurRoute,
  getSegmentRoute,
  pointOnRoute,
  routeMetrics,
} from './transportLayout.js';

const ROAD_SURFACE = '#303233';
const ROAD_EDGE = '#555954';
const SIDEWALK = '#85857d';
const ROAD_MARKING = '#c5b86a';

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

function drawRoad(ctx, metrics, { local = false } = {}) {
  if (!metrics || metrics.points.length < 2) return;

  ctx.save();
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';

  ctx.strokeStyle = SIDEWALK;
  ctx.lineWidth = local ? 30 : 42;
  traceRoute(ctx, metrics);
  ctx.stroke();

  ctx.strokeStyle = ROAD_EDGE;
  ctx.lineWidth = local ? 25 : 36;
  traceRoute(ctx, metrics);
  ctx.stroke();

  ctx.strokeStyle = ROAD_SURFACE;
  ctx.lineWidth = local ? 21 : 32;
  traceRoute(ctx, metrics);
  ctx.stroke();

  if (!local) {
    ctx.setLineDash([9, 11]);
    ctx.strokeStyle = ROAD_MARKING;
    ctx.globalAlpha = 0.65;
    ctx.lineWidth = 1.4;
    traceRoute(ctx, metrics);
    ctx.stroke();
  }

  ctx.restore();
}

function localRoad(points) {
  return routeMetrics(points);
}

function getActiveDistricts(state) {
  const districts = [
    {
      key: 'oldTown',
      stop: WORLD.line1Stops[0],
      active: true,
      minStage: 0,
      theme: 'residential',
    },
  ];

  if (state.line1.stopCount >= 2) {
    districts.push({
      key: 'market',
      stop: WORLD.line1Stops[1],
      active: true,
      minStage: 1,
      theme: 'mixed',
    });
  }

  if (state.line1.stopCount >= 3) {
    districts.push({
      key: 'park',
      stop: WORLD.line1Stops[2],
      active: true,
      minStage: 2,
      theme: 'park',
    });
  }

  if (state.line1.stopCount >= 4) {
    districts.push({
      key: 'university',
      stop: WORLD.line1Stops[3],
      active: true,
      minStage: 3,
      theme: 'campus',
    });
  }

  if (state.line1.stopCount >= 5) {
    districts.push({
      key: 'central',
      stop: WORLD.line1Stops[4],
      active: true,
      minStage: 4,
      theme: 'central',
    });
  }

  if (state.line2.built && state.line2.stopCount >= 2) {
    districts.push({
      key: 'riverside',
      stop: WORLD.line2Stops[1],
      active: true,
      minStage: 5,
      theme: 'riverside',
    });
  }

  if (state.line2.built && state.line2.stopCount >= 3) {
    districts.push({
      key: 'museum',
      stop: WORLD.line2Stops[2],
      active: true,
      minStage: 6,
      theme: 'mixed',
    });
  }

  if (state.line2.built && state.line2.stopCount >= 4) {
    districts.push({
      key: 'harbor',
      stop: WORLD.line2Stops[3],
      active: true,
      minStage: 7,
      theme: 'industrial',
    });
  }

  return districts;
}

function getVisibleRoadSegments(state) {
  const result = [];

  const line1VisibleSegments = Math.min(
    4,
    state.line1.stopCount,
  );

  for (
    let segment = 0;
    segment < line1VisibleSegments;
    segment += 1
  ) {
    result.push(
      getSegmentRoute(
        'line1',
        segment,
        segment + 1,
      ),
    );
  }

  if (state.line2.built) {
    const line2VisibleSegments = Math.min(
      3,
      Math.max(1, state.line2.stopCount - 1),
    );

    for (
      let segment = 0;
      segment < line2VisibleSegments;
      segment += 1
    ) {
      result.push(
        getSegmentRoute(
          'line2',
          segment,
          segment + 1,
        ),
      );
    }
  }

  return result;
}

function drawDistrictRoads(ctx, district, stage) {
  const { x, y } = district.stop;

  const radius =
    stage >= 5
      ? 105
      : stage >= 3
        ? 92
        : 78;

  const roads = [
    localRoad([
      { x: x - radius, y: y - 62 },
      { x: x + radius, y: y - 62 },
    ]),
    localRoad([
      { x: x - radius, y: y + 68 },
      { x: x + radius, y: y + 68 },
    ]),
    localRoad([
      { x: x - 76, y: y - radius },
      { x: x - 76, y: y + radius },
    ]),
    localRoad([
      { x: x + 78, y: y - radius },
      { x: x + 78, y: y + radius },
    ]),
  ];

  for (const road of roads) {
    drawRoad(ctx, road, { local: true });
  }
}

function siteOffsets(theme) {
  if (theme === 'central') {
    return [
      [-94, -96],
      [-30, -104],
      [42, -96],
      [102, -72],
      [-96, 84],
      [-28, 92],
      [52, 88],
      [112, 82],
    ];
  }

  if (theme === 'park') {
    return [
      [-102, -92],
      [-28, -106],
      [98, -82],
      [-100, 90],
      [102, 96],
    ];
  }

  return [
    [-100, -88],
    [-34, -98],
    [42, -92],
    [104, -70],
    [-98, 86],
    [-28, 96],
    [48, 88],
    [106, 78],
  ];
}

function buildingProfile(theme, stage, index) {
  if (theme === 'industrial') {
    return {
      kind: index % 3 === 0 ? 'warehouse' : 'workshop',
      floors: 1 + (stage >= 7 && index % 4 === 0 ? 1 : 0),
    };
  }

  if (theme === 'campus') {
    return {
      kind: index % 4 === 0 ? 'campus' : 'apartment',
      floors: stage >= 5 ? 4 : 3,
    };
  }

  if (theme === 'central') {
    if (stage >= 7 && index % 3 === 0) {
      return {
        kind: 'tower',
        floors: 9 + (index % 4),
      };
    }

    if (stage >= 5) {
      return {
        kind: 'midrise',
        floors: 5 + (index % 3),
      };
    }

    return {
      kind: 'apartment',
      floors: 3 + (index % 2),
    };
  }

  if (theme === 'mixed') {
    if (stage >= 5 && index % 3 === 0) {
      return {
        kind: 'midrise',
        floors: 4 + (index % 2),
      };
    }

    if (stage >= 3) {
      return {
        kind: index % 2 === 0 ? 'apartment' : 'shop',
        floors: 2 + (index % 2),
      };
    }

    return {
      kind: index % 2 === 0 ? 'house' : 'shop',
      floors: 1,
    };
  }

  if (theme === 'riverside') {
    return {
      kind: stage >= 6 && index % 2 === 0
        ? 'apartment'
        : 'house',
      floors: stage >= 6 ? 3 : 1,
    };
  }

  if (theme === 'park') {
    return {
      kind: index % 2 === 0 ? 'house' : 'townhouse',
      floors: stage >= 4 ? 2 : 1,
    };
  }

  if (stage >= 4 && index % 3 === 0) {
    return {
      kind: 'apartment',
      floors: 3,
    };
  }

  if (stage >= 2) {
    return {
      kind: index % 2 === 0 ? 'townhouse' : 'house',
      floors: 2,
    };
  }

  return {
    kind: 'house',
    floors: 1,
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
    return { w: 42, h: 34 };
  }

  if (
    profile.kind === 'warehouse'
    || profile.kind === 'campus'
  ) {
    return { w: 54, h: 34 };
  }

  if (profile.kind === 'shop') {
    return { w: 38, h: 28 };
  }

  if (profile.kind === 'townhouse') {
    return { w: 34, h: 30 };
  }

  return { w: 30, h: 26 };
}

function drawBuilding(ctx, x, y, profile, stage, seed) {
  const { w, h } = buildingSize(profile);

  const verticalLift =
    Math.max(0, profile.floors - 1) * 4;

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
      ? '#75756e'
      : profile.kind === 'tower'
        ? '#a7aaa9'
        : profile.kind === 'campus'
          ? '#8b9293'
          : '#9a9589';

  ctx.fillStyle = wall;
  ctx.fillRect(
    x - w / 2,
    y - h / 2 - verticalLift,
    w,
    h + verticalLift,
  );

  ctx.fillStyle = '#30302d';
  ctx.fillRect(
    x - w / 2 + 4,
    y + h / 2 - 7,
    w - 8,
    7,
  );

  if (
    profile.kind === 'house'
    || profile.kind === 'townhouse'
  ) {
    ctx.fillStyle = '#67605a';
    ctx.beginPath();
    ctx.moveTo(
      x - w / 2 - 3,
      y - h / 2 - verticalLift,
    );
    ctx.lineTo(
      x,
      y - h / 2 - verticalLift - 11,
    );
    ctx.lineTo(
      x + w / 2 + 3,
      y - h / 2 - verticalLift,
    );
    ctx.closePath();
    ctx.fill();
  }

  const windowRows = clamp(
    profile.floors,
    1,
    8,
  );

  const windowCols = Math.max(
    2,
    Math.floor(w / 14),
  );

  for (
    let row = 0;
    row < windowRows;
    row += 1
  ) {
    for (
      let col = 0;
      col < windowCols;
      col += 1
    ) {
      const lit =
        ((seed + row * 3 + col * 5 + stage) % 5)
        < 2;

      ctx.fillStyle =
        lit
          ? '#d7c76b'
          : '#313a3d';

      const wx =
        x - w / 2 + 6 + col * 12;

      const wy =
        y + h / 2 - 14 - row * 8;

      if (
        wx + 5
        < x + w / 2 - 3
      ) {
        ctx.fillRect(
          wx,
          wy,
          5,
          4,
        );
      }
    }
  }

  if (profile.kind === 'shop') {
    ctx.fillStyle = '#263a40';
    ctx.fillRect(
      x - w / 2 + 4,
      y + h / 2 - 11,
      w - 8,
      7,
    );
  }

  if (profile.kind === 'tower') {
    ctx.fillStyle = '#c9c9c1';
    ctx.fillRect(
      x - 2,
      y - h / 2 - verticalLift - 8,
      4,
      8,
    );
  }

  ctx.restore();
}

function drawTree(ctx, x, y, seed = 0) {
  ctx.fillStyle = '#3c342b';
  ctx.fillRect(x - 2, y, 4, 9);

  ctx.fillStyle =
    seed % 2 === 0
      ? '#2f713d'
      : '#3b8148';

  ctx.fillRect(x - 7, y - 9, 14, 12);
  ctx.fillRect(x - 5, y - 13, 10, 6);
}

function drawPark(ctx, district) {
  const { x, y } = district.stop;

  ctx.fillStyle = '#24352a';
  ctx.fillRect(
    x + 34,
    y - 118,
    112,
    72,
  );

  ctx.strokeStyle = '#436449';
  ctx.lineWidth = 2;
  ctx.strokeRect(
    x + 34,
    y - 118,
    112,
    72,
  );

  for (let index = 0; index < 7; index += 1) {
    drawTree(
      ctx,
      x + 48 + (index % 4) * 25,
      y - 102 + Math.floor(index / 4) * 32,
      index,
    );
  }
}

function drawDistrictBuildings(ctx, district, stage) {
  if (district.theme === 'park') {
    drawPark(ctx, district);
  }

  const offsets =
    siteOffsets(district.theme);

  offsets.forEach(
    ([dx, dy], index) => {
      if (
        stage <= district.minStage
        && index > 3
      ) {
        return;
      }

      const profile =
        buildingProfile(
          district.theme,
          stage,
          index,
        );

      drawBuilding(
        ctx,
        district.stop.x + dx,
        district.stop.y + dy,
        profile,
        stage,
        index + district.minStage * 11,
      );
    },
  );
}

function drawCrosswalk(ctx, x, y, horizontal = true) {
  ctx.save();
  ctx.fillStyle = '#c4c4bc';
  ctx.globalAlpha = 0.62;

  for (let index = -2; index <= 2; index += 1) {
    if (horizontal) {
      ctx.fillRect(
        x - 9,
        y + index * 4,
        18,
        2,
      );
    } else {
      ctx.fillRect(
        x + index * 4,
        y - 9,
        2,
        18,
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
  const carCount = clamp(
    1 + stage,
    1,
    7,
  );

  for (
    let index = 0;
    index < carCount;
    index += 1
  ) {
    const route =
      roadRoutes[index % roadRoutes.length];

    if (!route || route.total <= 0) continue;

    const speed =
      20 + (index % 3) * 6;

    const distanceAlong =
      (
        timeSeconds * speed
        + index * 83
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

    ctx.fillStyle = '#0c0c0c';
    ctx.fillRect(
      -7,
      -4,
      14,
      8,
    );

    ctx.fillStyle =
      index % 3 === 0
        ? '#b9b8ad'
        : index % 3 === 1
          ? '#687782'
          : '#87685f';

    ctx.fillRect(
      -6,
      -3,
      12,
      6,
    );

    ctx.fillStyle = '#d8e6e8';
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

  const activeDistricts =
    getActiveDistricts(state);

  const roadRoutes =
    getVisibleRoadSegments(state);

  for (const district of activeDistricts) {
    drawDistrictRoads(
      ctx,
      district,
      stage,
    );
  }

  for (const road of roadRoutes) {
    drawRoad(ctx, road);
  }

  if (
    state.line1.stopCount >= 3
    || state.depot.built
  ) {
    drawRoad(
      ctx,
      getDepotSpurRoute(),
      { local: true },
    );
  }

  for (const district of activeDistricts) {
    drawDistrictBuildings(
      ctx,
      district,
      stage,
    );

    drawCrosswalk(
      ctx,
      district.stop.x,
      district.stop.y,
      district.key !== 'market',
    );
  }

  if (roadRoutes.length > 0) {
    drawAmbientCars(
      ctx,
      roadRoutes,
      stage,
      timeSeconds,
    );
  }
}
