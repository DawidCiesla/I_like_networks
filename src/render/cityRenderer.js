import {
  WORLD,
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
  if (!state.city) return 0;

  return Math.max(
    0,
    state.city.districts.filter(
      (district) =>
        district.status === 'active',
    ).length - 1,
  );
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

function roadMetrics(road) {
  return routeMetrics(
    road.points,
  );
}

function partialRoute(
  metrics,
  progress,
) {
  const target =
    metrics.total
    * clamp(progress, 0, 1);

  const points = [];

  if (metrics.points.length > 0) {
    points.push({
      ...metrics.points[0],
    });
  }

  for (const segment of metrics.segments) {
    const segmentEnd =
      segment.start
      + segment.length;

    if (segmentEnd <= target) {
      points.push({
        ...segment.b,
      });
      continue;
    }

    if (target > segment.start) {
      const local =
        (target - segment.start)
        / segment.length;

      points.push({
        x:
          segment.a.x
          + segment.dx * local,
        y:
          segment.a.y
          + segment.dy * local,
      });
    }

    break;
  }

  return routeMetrics(points);
}

function roadWidths(road) {
  if (road.class === 'arterial') {
    return {
      sidewalk: 42,
      edge: 36,
      surface: 31,
    };
  }

  if (road.class === 'service') {
    return {
      sidewalk: 19,
      edge: 16,
      surface: 12,
    };
  }

  return {
    sidewalk: 23,
    edge: 19,
    surface: 15,
  };
}

function drawRoadSurface(
  ctx,
  metrics,
  road,
) {
  if (
    !metrics
    || metrics.points.length < 2
  ) {
    return;
  }

  const widths =
    roadWidths(road);

  ctx.save();
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';

  ctx.strokeStyle = SIDEWALK;
  ctx.lineWidth =
    widths.sidewalk;
  traceRoute(ctx, metrics);
  ctx.stroke();

  ctx.strokeStyle = ROAD_EDGE;
  ctx.lineWidth =
    widths.edge;
  traceRoute(ctx, metrics);
  ctx.stroke();

  ctx.strokeStyle = ROAD_SURFACE;
  ctx.lineWidth =
    widths.surface;
  traceRoute(ctx, metrics);
  ctx.stroke();

  if (road.class === 'arterial') {
    ctx.setLineDash([9, 13]);
    ctx.strokeStyle =
      ROAD_MARKING;
    ctx.globalAlpha = 0.45;
    ctx.lineWidth = 1.2;
    traceRoute(ctx, metrics);
    ctx.stroke();
  }

  ctx.restore();
}

function drawPlannedRoad(
  ctx,
  metrics,
) {
  if (
    !metrics
    || metrics.points.length < 2
  ) {
    return;
  }

  ctx.save();
  ctx.setLineDash([5, 8]);
  ctx.strokeStyle = '#41443f';
  ctx.globalAlpha = 0.45;
  ctx.lineWidth = 2;
  traceRoute(ctx, metrics);
  ctx.stroke();
  ctx.restore();
}

function drawRoadConstruction(
  ctx,
  road,
) {
  const metrics =
    roadMetrics(road);

  drawPlannedRoad(
    ctx,
    metrics,
  );

  const builtMetrics =
    partialRoute(
      metrics,
      road.constructionProgress
      ?? 0,
    );

  drawRoadSurface(
    ctx,
    builtMetrics,
    road,
  );

  const head =
    pointOnRoute(
      metrics,
      metrics.total
      * clamp(
        road.constructionProgress
        ?? 0,
        0,
        1,
      ),
    );

  ctx.fillStyle = '#e5aa32';
  ctx.fillRect(
    head.x - 5,
    head.y - 5,
    10,
    10,
  );

  ctx.fillStyle = '#111';
  ctx.fillRect(
    head.x - 2,
    head.y - 2,
    4,
    4,
  );
}

function profileSize(profile) {
  if (profile.kind === 'tower') {
    return {
      w: 34,
      h: 34,
    };
  }

  if (
    profile.kind === 'midrise'
    || profile.kind === 'apartment'
  ) {
    return {
      w: 40,
      h: 32,
    };
  }

  if (
    profile.kind === 'warehouse'
    || profile.kind === 'campus'
    || profile.kind === 'civic'
  ) {
    return {
      w: 52,
      h: 32,
    };
  }

  if (
    profile.kind === 'shop'
  ) {
    return {
      w: 34,
      h: 26,
    };
  }

  return {
    w: 30,
    h: 26,
  };
}

function drawConstructionSite(
  ctx,
  building,
) {
  const { w, h } =
    profileSize(
      building.profile,
    );

  const progress =
    clamp(
      building.constructionProgress
      ?? 0,
      0,
      1,
    );

  ctx.save();

  ctx.setLineDash([4, 4]);
  ctx.strokeStyle = '#c99b32';
  ctx.lineWidth = 1.5;

  ctx.strokeRect(
    building.x - w / 2 - 4,
    building.y - h / 2 - 4,
    w + 8,
    h + 8,
  );

  ctx.setLineDash([]);

  if (progress < 0.22) {
    ctx.fillStyle = '#50493a';
    ctx.fillRect(
      building.x - w / 2,
      building.y + h / 2 - 5,
      w,
      5,
    );
  } else {
    const frameHeight =
      Math.max(
        7,
        (h + 18)
        * Math.min(
          1,
          (progress - 0.18) / 0.82,
        ),
      );

    ctx.strokeStyle = '#8f918c';
    ctx.lineWidth = 2;

    const left =
      building.x - w / 2;
    const top =
      building.y
      + h / 2
      - frameHeight;

    ctx.strokeRect(
      left,
      top,
      w,
      frameHeight,
    );

    const columns =
      Math.max(
        2,
        Math.floor(w / 13),
      );

    for (
      let index = 1;
      index < columns;
      index += 1
    ) {
      const x =
        left
        + index * w / columns;

      ctx.beginPath();
      ctx.moveTo(
        x,
        top,
      );
      ctx.lineTo(
        x,
        building.y + h / 2,
      );
      ctx.stroke();
    }

    for (
      let y =
        building.y + h / 2 - 8;
      y > top;
      y -= 8
    ) {
      ctx.beginPath();
      ctx.moveTo(left, y);
      ctx.lineTo(
        left + w,
        y,
      );
      ctx.stroke();
    }
  }

  ctx.fillStyle = '#d9b348';
  ctx.font =
    '7px "Lucida Console", monospace';
  ctx.textAlign = 'center';

  ctx.fillText(
    `${Math.round(progress * 100)}%`,
    building.x,
    building.y + h / 2 + 13,
  );

  ctx.restore();
}

function buildingWall(profile) {
  if (profile.kind === 'warehouse') {
    return '#70736f';
  }

  if (profile.kind === 'tower') {
    return '#a3a9aa';
  }

  if (
    profile.kind === 'campus'
    || profile.kind === 'civic'
  ) {
    return '#828d90';
  }

  if (profile.kind === 'shop') {
    return '#8e8174';
  }

  return '#918d82';
}

function drawBuiltBuilding(
  ctx,
  building,
  cityTime,
) {
  const profile =
    building.profile;

  const { w, h } =
    profileSize(profile);

  const lift =
    Math.max(
      0,
      (profile.floors ?? 1) - 1,
    ) * 4;

  ctx.save();

  ctx.fillStyle = '#111';
  ctx.fillRect(
    building.x - w / 2 - 3,
    building.y - h / 2 - lift - 3,
    w + 6,
    h + lift + 6,
  );

  ctx.fillStyle =
    buildingWall(profile);

  ctx.fillRect(
    building.x - w / 2,
    building.y - h / 2 - lift,
    w,
    h + lift,
  );

  if (
    profile.kind === 'house'
    || profile.kind === 'townhouse'
  ) {
    ctx.fillStyle = '#625c55';
    ctx.beginPath();
    ctx.moveTo(
      building.x - w / 2 - 2,
      building.y - h / 2 - lift,
    );
    ctx.lineTo(
      building.x,
      building.y - h / 2 - lift - 9,
    );
    ctx.lineTo(
      building.x + w / 2 + 2,
      building.y - h / 2 - lift,
    );
    ctx.closePath();
    ctx.fill();
  }

  const rows =
    clamp(
      profile.floors ?? 1,
      1,
      8,
    );

  const columns =
    Math.max(
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
        building.x - w / 2
        + 6
        + col * 12;

      const wy =
        building.y + h / 2
        - 13
        - row * 8;

      if (
        wx + 5
        >= building.x + w / 2 - 3
      ) {
        continue;
      }

      const lit =
        (
          row * 5
          + col * 3
          + building.id.length
          + Math.floor(
            cityTime / 12,
          )
        ) % 5 < 2;

      ctx.fillStyle =
        lit
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

  if (profile.kind === 'shop') {
    ctx.fillStyle = '#30444a';
    ctx.fillRect(
      building.x - w / 2 + 4,
      building.y + h / 2 - 10,
      w - 8,
      6,
    );
  }

  if (profile.kind === 'tower') {
    ctx.fillStyle = '#c7c8c2';
    ctx.fillRect(
      building.x - 2,
      building.y - h / 2 - lift - 8,
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

function drawCityPark(
  ctx,
  state,
) {
  const district =
    state.city.districts.find(
      (candidate) =>
        candidate.id === 'park',
    );

  if (
    !district
    || district.status
      !== 'active'
  ) {
    return;
  }

  const age =
    state.city.timeSeconds
    - (district.activatedAt ?? 0);

  if (age < 6) return;

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

function activeStopPoints(state) {
  const result = [];

  for (
    let index = 0;
    index < state.line1.stopCount;
    index += 1
  ) {
    result.push(
      WORLD.line1Stops[index],
    );
  }

  if (state.line2.built) {
    for (
      let index = 1;
      index < state.line2.stopCount;
      index += 1
    ) {
      result.push(
        WORLD.line2Stops[index],
      );
    }
  }

  return result;
}

function drawCrosswalk(
  ctx,
  x,
  y,
  horizontal = true,
) {
  ctx.save();
  ctx.fillStyle = '#c7c7bf';
  ctx.globalAlpha = 0.45;

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
  state,
  timeSeconds,
) {
  const roads =
    state.city.roads.filter(
      (road) =>
        road.status === 'built'
        && road.class === 'arterial',
    );

  if (roads.length === 0) return;

  const cityMaturity =
    state.city.buildings.filter(
      (building) =>
        building.status === 'built',
    ).length;

  const carCount =
    clamp(
      1 + Math.floor(
        cityMaturity / 5,
      ),
      1,
      6,
    );

  for (
    let index = 0;
    index < carCount;
    index += 1
  ) {
    const metrics =
      roadMetrics(
        roads[
          index % roads.length
        ],
      );

    if (metrics.total <= 0) {
      continue;
    }

    const distanceAlong =
      (
        timeSeconds
        * (16 + index * 2)
        + index * 89
      ) % metrics.total;

    const point =
      pointOnRoute(
        metrics,
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

export function getCityLots(state) {
  if (!state.city) return [];

  return state.city.parcels.map(
    (parcel) => ({
      key: parcel.id,
      id: parcel.id,
      districtId:
        parcel.districtId,
      x: parcel.x,
      y: parcel.y,
      w: parcel.w,
      h: parcel.h,
      zone: parcel.zone,
      status: parcel.status,
      buildingId:
        parcel.buildingId,
      box: {
        x:
          parcel.x - parcel.w / 2,
        y:
          parcel.y - parcel.h / 2,
        w: parcel.w,
        h: parcel.h,
      },
    }),
  );
}

export function drawCity(
  ctx,
  state,
  timeSeconds,
) {
  if (!state.city) return;

  for (
    const road
    of state.city.roads
  ) {
    const district =
      state.city.districts.find(
        (candidate) =>
          candidate.id
          === road.districtId,
      );

    if (
      road.status === 'planned'
      && district?.status === 'active'
      && road.source === 'city'
    ) {
      drawPlannedRoad(
        ctx,
        roadMetrics(road),
      );
      continue;
    }

    if (
      road.status === 'constructing'
    ) {
      drawRoadConstruction(
        ctx,
        road,
      );
      continue;
    }

    if (road.status === 'built') {
      drawRoadSurface(
        ctx,
        roadMetrics(road),
        road,
      );
    }
  }

  drawCityPark(
    ctx,
    state,
  );

  for (
    const building
    of state.city.buildings
  ) {
    if (
      building.status
      === 'constructing'
    ) {
      drawConstructionSite(
        ctx,
        building,
      );
    } else if (
      building.status
      === 'built'
    ) {
      drawBuiltBuilding(
        ctx,
        building,
        state.city.timeSeconds,
      );
    }
  }

  activeStopPoints(
    state,
  ).forEach(
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
    state,
    timeSeconds,
  );
}
