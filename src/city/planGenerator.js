import {
  WORLD,
  getDepotSpurRoute,
  getSegmentRoute,
} from '../render/transportLayout.js';

const DISTRICT_SPECS = Object.freeze([
  {
    id: 'oldTown',
    name: 'Old Town',
    lineKey: 'line1',
    stopIndex: 0,
    theme: 'residential',
    parentRoadId: 'arterial-oldTown-existing',
    branchSide: 1,
    depth: 220,
    arm: 180,
    roadTier: 1,
  },
  {
    id: 'market',
    name: 'Market Square',
    lineKey: 'line1',
    stopIndex: 1,
    theme: 'mixed',
    parentRoadId: 'arterial-line1-0',
    branchSide: -1,
    depth: 250,
    arm: 210,
    roadTier: 2,
  },
  {
    id: 'park',
    name: 'City Park',
    lineKey: 'line1',
    stopIndex: 2,
    theme: 'park',
    parentRoadId: 'arterial-line1-1',
    branchSide: 1,
    depth: 230,
    arm: 190,
    roadTier: 1,
  },
  {
    id: 'university',
    name: 'University',
    lineKey: 'line1',
    stopIndex: 3,
    theme: 'campus',
    parentRoadId: 'arterial-line1-2',
    branchSide: -1,
    depth: 260,
    arm: 220,
    roadTier: 2,
  },
  {
    id: 'central',
    name: 'Central',
    lineKey: 'line1',
    stopIndex: 4,
    theme: 'central',
    parentRoadId: 'arterial-line1-3',
    branchSide: 1,
    depth: 300,
    arm: 250,
    roadTier: 3,
  },
  {
    id: 'riverside',
    name: 'Riverside',
    lineKey: 'line2',
    stopIndex: 1,
    theme: 'riverside',
    parentRoadId: 'arterial-line2-0',
    branchSide: 1,
    depth: 240,
    arm: 200,
    roadTier: 1,
  },
  {
    id: 'museum',
    name: 'Museum',
    lineKey: 'line2',
    stopIndex: 2,
    theme: 'mixed',
    parentRoadId: 'arterial-line2-1',
    branchSide: -1,
    depth: 260,
    arm: 220,
    roadTier: 2,
  },
  {
    id: 'harbor',
    name: 'Harbor',
    lineKey: 'line2',
    stopIndex: 3,
    theme: 'industrial',
    parentRoadId: 'arterial-line2-2',
    branchSide: 1,
    depth: 300,
    arm: 260,
    roadTier: 2,
  },
]);

function hashString(value) {
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

function unitRandom(seed, key) {
  return (
    hashString(
      `${seed}:${key}`,
    )
    / 0xffffffff
  );
}

function normalize(dx, dy) {
  const length =
    Math.hypot(dx, dy);

  if (length <= 1e-9) {
    return {
      x: 1,
      y: 0,
    };
  }

  return {
    x: dx / length,
    y: dy / length,
  };
}

function add(point, vector, scale) {
  return {
    x:
      point.x
      + vector.x * scale,
    y:
      point.y
      + vector.y * scale,
  };
}

function getStop(spec) {
  return WORLD[
    spec.lineKey + 'Stops'
  ][spec.stopIndex];
}

function roadNodeKey(point) {
  return (
    `${Math.round(point.x * 10)}:`
    + `${Math.round(point.y * 10)}`
  );
}

function ensureNode(
  nodes,
  nodeByKey,
  point,
) {
  const key =
    roadNodeKey(point);

  if (nodeByKey.has(key)) {
    return nodeByKey.get(key);
  }

  const id =
    `node-${nodes.length + 1}`;

  nodes.push({
    id,
    x: point.x,
    y: point.y,
  });

  nodeByKey.set(
    key,
    id,
  );

  return id;
}

function makeEdge(
  nodes,
  nodeByKey,
  {
    id,
    districtId,
    roadClass,
    points,
    unlock = null,
    buildOrder = 0,
    source = 'city',
    parentRoadIds = [],
  },
) {
  const first =
    points[0];

  const last =
    points[points.length - 1];

  return {
    id,
    districtId,
    class: roadClass,
    source,
    fromNodeId:
      ensureNode(
        nodes,
        nodeByKey,
        first,
      ),
    toNodeId:
      ensureNode(
        nodes,
        nodeByKey,
        last,
      ),
    points:
      points.map(
        (point) => ({
          ...point,
        }),
      ),
    unlock,
    buildOrder,
    parentRoadIds:
      [...parentRoadIds],
    status: 'planned',
    constructionProgress: 0,
  };
}

function getIncomingDirection(
  spec,
) {
  if (spec.id === 'oldTown') {
    return {
      x: 1,
      y: 0,
    };
  }

  const route =
    spec.lineKey === 'line1'
      ? getSegmentRoute(
        'line1',
        spec.stopIndex - 1,
        spec.stopIndex,
      )
      : getSegmentRoute(
        'line2',
        spec.stopIndex - 1,
        spec.stopIndex,
      );

  const last =
    route.segments.at(-1);

  return normalize(
    last?.dx ?? 1,
    last?.dy ?? 0,
  );
}

function getPrimaryRoadSpecs() {
  const specs = [];

  const oldTown =
    WORLD.line1Stops[0];

  specs.push({
    id:
      'arterial-oldTown-existing',
    districtId: 'oldTown',
    roadClass: 'arterial',
    points: [
      {
        x: oldTown.x - 320,
        y: oldTown.y,
      },
      {
        x: oldTown.x,
        y: oldTown.y,
      },
    ],
    unlock: null,
    buildOrder: -20,
    source: 'existing-arterial',
    parentRoadIds: [],
  });

  for (
    let segment = 0;
    segment < 4;
    segment += 1
  ) {
    specs.push({
      id:
        `arterial-line1-${segment}`,
      districtId:
        DISTRICT_SPECS[
          segment + 1
        ].id,
      roadClass: 'arterial',
      points:
        getSegmentRoute(
          'line1',
          segment,
          segment + 1,
        ).points,
      unlock: {
        lineKey: 'line1',
        stopCount:
          segment + 2,
      },
      buildOrder: -10,
      source:
        'transport-corridor',
      parentRoadIds: [
        segment === 0
          ? 'arterial-oldTown-existing'
          : `arterial-line1-${segment - 1}`,
      ],
    });
  }

  for (
    let segment = 0;
    segment < 3;
    segment += 1
  ) {
    specs.push({
      id:
        `arterial-line2-${segment}`,
      districtId:
        DISTRICT_SPECS[
          segment + 5
        ].id,
      roadClass: 'arterial',
      points:
        getSegmentRoute(
          'line2',
          segment,
          segment + 1,
        ).points,
      unlock: {
        lineKey: 'line2',
        stopCount:
          segment + 2,
      },
      buildOrder: -10,
      source:
        'transport-corridor',
      parentRoadIds: [
        segment === 0
          ? 'arterial-line1-1'
          : `arterial-line2-${segment - 1}`,
      ],
    });
  }

  specs.push({
    id: 'depot-access',
    districtId: 'park',
    roadClass: 'service',
    points:
      getDepotSpurRoute().points,
    unlock: {
      lineKey: 'line1',
      stopCount: 3,
      requiresDepot: true,
    },
    buildOrder: 50,
    source: 'depot-access',
    parentRoadIds: [
      'arterial-line1-1',
    ],
  });

  return specs;
}

function localRoadBlueprints(
  spec,
) {
  const anchor =
    getStop(spec);

  const tangent =
    getIncomingDirection(spec);

  const normal = {
    x:
      -tangent.y
      * spec.branchSide,
    y:
      tangent.x
      * spec.branchSide,
  };

  const branchEnd =
    add(
      anchor,
      normal,
      spec.depth,
    );

  const leftEnd =
    add(
      branchEnd,
      tangent,
      -spec.arm,
    );

  const rightEnd =
    add(
      branchEnd,
      tangent,
      spec.arm,
    );

  const roads = [
    {
      id:
        `local-${spec.id}-spine`,
      points: [
        {
          x: anchor.x,
          y: anchor.y,
        },
        branchEnd,
      ],
      parentRoadIds: [
        spec.parentRoadId,
      ],
      buildOrder: 0,
    },
    {
      id:
        `local-${spec.id}-west`,
      points: [
        branchEnd,
        leftEnd,
      ],
      parentRoadIds: [
        `local-${spec.id}-spine`,
      ],
      buildOrder: 1,
    },
    {
      id:
        `local-${spec.id}-east`,
      points: [
        branchEnd,
        rightEnd,
      ],
      parentRoadIds: [
        `local-${spec.id}-spine`,
      ],
      buildOrder: 1,
    },
  ];

  if (spec.roadTier >= 2) {
    const outerDepth =
      spec.depth * 0.72;

    const leftOuter =
      add(
        leftEnd,
        normal,
        outerDepth,
      );

    const rightOuter =
      add(
        rightEnd,
        normal,
        outerDepth,
      );

    roads.push(
      {
        id:
          `local-${spec.id}-west-outer`,
        points: [
          leftEnd,
          leftOuter,
        ],
        parentRoadIds: [
          `local-${spec.id}-west`,
        ],
        buildOrder: 2,
      },
      {
        id:
          `local-${spec.id}-east-outer`,
        points: [
          rightEnd,
          rightOuter,
        ],
        parentRoadIds: [
          `local-${spec.id}-east`,
        ],
        buildOrder: 2,
      },
      {
        id:
          `local-${spec.id}-outer-link`,
        points: [
          leftOuter,
          rightOuter,
        ],
        parentRoadIds: [
          `local-${spec.id}-west-outer`,
          `local-${spec.id}-east-outer`,
        ],
        buildOrder: 3,
      },
    );
  }

  if (spec.roadTier >= 3) {
    const farDepth =
      spec.depth * 0.65;

    const farStart =
      add(
        leftEnd,
        tangent,
        -spec.arm * 0.65,
      );

    const farEnd =
      add(
        farStart,
        normal,
        farDepth,
      );

    roads.push({
      id:
        `local-${spec.id}-far-branch`,
      points: [
        leftEnd,
        farStart,
        farEnd,
      ],
      parentRoadIds: [
        `local-${spec.id}-west`,
      ],
      buildOrder: 4,
    });
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

  const t =
    Math.min(
      1,
      Math.max(
        0,
        (
          (point.x - a.x) * dx
          + (point.y - a.y) * dy
        ) / lengthSquared,
      ),
    );

  return Math.hypot(
    point.x
      - (a.x + dx * t),
    point.y
      - (a.y + dy * t),
  );
}

function distancePointToRoad(
  point,
  road,
) {
  let minimum =
    Number.POSITIVE_INFINITY;

  for (
    let index = 0;
    index < road.points.length - 1;
    index += 1
  ) {
    minimum =
      Math.min(
        minimum,
        distancePointToSegment(
          point,
          road.points[index],
          road.points[index + 1],
        ),
      );
  }

  return minimum;
}

function roadLength(road) {
  let total = 0;

  for (
    let index = 0;
    index < road.points.length - 1;
    index += 1
  ) {
    total += Math.hypot(
      road.points[index + 1].x
        - road.points[index].x,
      road.points[index + 1].y
        - road.points[index].y,
    );
  }

  return total;
}

function pointOnRoad(
  road,
  distanceAlong,
) {
  let remaining =
    Math.max(
      0,
      distanceAlong,
    );

  for (
    let index = 0;
    index < road.points.length - 1;
    index += 1
  ) {
    const a =
      road.points[index];

    const b =
      road.points[index + 1];

    const dx =
      b.x - a.x;

    const dy =
      b.y - a.y;

    const length =
      Math.hypot(dx, dy);

    if (
      remaining <= length
      || index
        === road.points.length - 2
    ) {
      const local =
        length <= 1e-9
          ? 0
          : Math.min(
            1,
            remaining / length,
          );

      const tangent =
        normalize(dx, dy);

      return {
        x:
          a.x + dx * local,
        y:
          a.y + dy * local,
        tx: tangent.x,
        ty: tangent.y,
      };
    }

    remaining -= length;
  }

  const last =
    road.points.at(-1);

  return {
    x: last.x,
    y: last.y,
    tx: 1,
    ty: 0,
  };
}

function parcelFootprint(
  zone,
  density,
) {
  if (zone === 'industrial') {
    return {
      w: 62,
      h: 48,
    };
  }

  if (zone === 'civic') {
    return {
      w: 58,
      h: 48,
    };
  }

  if (
    zone === 'commercial'
    || zone === 'mixed'
  ) {
    return {
      w:
        density >= 3
          ? 52
          : 44,
      h:
        density >= 3
          ? 46
          : 38,
    };
  }

  return {
    w:
      density >= 2
        ? 42
        : 34,
    h:
      density >= 2
        ? 38
        : 30,
  };
}

function densityForTheme(theme) {
  if (theme === 'central') return 3;
  if (theme === 'campus') return 2;
  if (theme === 'mixed') return 2;
  if (theme === 'industrial') return 2;
  return 1;
}

function zoneFor(
  theme,
  roadIndex,
  sampleIndex,
  side,
) {
  const selector =
    (
      roadIndex * 5
      + sampleIndex * 3
      + (side > 0 ? 1 : 0)
    ) % 7;

  if (theme === 'industrial') {
    return (
      selector === 0
        ? 'mixed'
        : 'industrial'
    );
  }

  if (theme === 'campus') {
    return (
      selector < 2
        ? 'civic'
        : selector === 2
          ? 'mixed'
          : 'residential'
    );
  }

  if (theme === 'central') {
    return (
      selector < 3
        ? 'commercial'
        : 'mixed'
    );
  }

  if (theme === 'mixed') {
    return (
      selector < 2
        ? 'commercial'
        : selector < 5
          ? 'mixed'
          : 'residential'
    );
  }

  if (theme === 'park') {
    return (
      selector === 0
        ? 'commercial'
        : 'residential'
    );
  }

  if (theme === 'riverside') {
    return (
      selector === 0
        ? 'mixed'
        : 'residential'
    );
  }

  return (
    selector === 0
      ? 'mixed'
      : 'residential'
  );
}

function createReservations() {
  const parkStop =
    WORLD.line1Stops[2];

  return [
    {
      id: 'reservation-bus-depot',
      type: 'facility',
      facilityType: 'bus-depot',
      x: WORLD.depot.x,
      y: WORLD.depot.y,
      w: 230,
      h: 170,
      padding: 28,
      status: 'reserved',
    },
    {
      id: 'reservation-city-park',
      type: 'open-space',
      facilityType: 'park',
      x: parkStop.x - 190,
      y: parkStop.y - 210,
      w: 250,
      h: 190,
      padding: 18,
      status: 'reserved',
    },
  ];
}

function boxesOverlap(
  a,
  b,
  margin = 8,
) {
  return !(
    a.x + a.w + margin
      < b.x
    || b.x + b.w + margin
      < a.x
    || a.y + a.h + margin
      < b.y
    || b.y + b.h + margin
      < a.y
  );
}

function reservationBox(
  reservation,
) {
  const padding =
    reservation.padding ?? 0;

  return {
    x:
      reservation.x
      - reservation.w / 2
      - padding,
    y:
      reservation.y
      - reservation.h / 2
      - padding,
    w:
      reservation.w
      + padding * 2,
    h:
      reservation.h
      + padding * 2,
  };
}

function createParcelCandidates(
  seed,
  spec,
  localRoads,
) {
  const density =
    densityForTheme(
      spec.theme,
    );

  const candidates = [];

  localRoads.forEach(
    (road, roadIndex) => {
      const length =
        roadLength(road);

      const spacing =
        spec.theme === 'central'
          ? 72
          : spec.theme === 'industrial'
            ? 92
            : 82;

      const start =
        Math.min(
          55,
          length * 0.3,
        );

      const end =
        Math.max(
          start,
          length - 38,
        );

      let sampleIndex = 0;

      for (
        let distance = start;
        distance <= end;
        distance += spacing
      ) {
        const point =
          pointOnRoad(
            road,
            distance,
          );

        for (
          const side
          of [-1, 1]
        ) {
          const key =
            `${spec.id}:${road.id}:`
            + `${sampleIndex}:${side}`;

          const zone =
            zoneFor(
              spec.theme,
              roadIndex,
              sampleIndex,
              side,
            );

          const localDensity =
            Math.min(
              4,
              density
              + (
                unitRandom(
                  seed,
                  key + ':density',
                ) > 0.8
                  ? 1
                  : 0
              ),
            );

          const footprint =
            parcelFootprint(
              zone,
              localDensity,
            );

          const offset =
            (
              road.class === 'local'
                ? 46
                : 54
            )
            + footprint.h / 2;

          const normal = {
            x:
              -point.ty * side,
            y:
              point.tx * side,
          };

          const jitterAlong =
            (
              unitRandom(
                seed,
                key + ':along',
              ) - 0.5
            ) * 12;

          const jitterAway =
            (
              unitRandom(
                seed,
                key + ':away',
              ) - 0.5
            ) * 8;

          candidates.push({
            id:
              `parcel-${spec.id}-`
              + `${candidates.length + 1}`,
            districtId: spec.id,
            blockId: null,
            x:
              point.x
              + point.tx * jitterAlong
              + normal.x
                * (offset + jitterAway),
            y:
              point.y
              + point.ty * jitterAlong
              + normal.y
                * (offset + jitterAway),
            w:
              footprint.w + 12,
            h:
              footprint.h + 12,
            frontage:
              Math.max(
                18,
                Math.min(
                  spacing - 10,
                  footprint.w,
                ),
              ),
            setback:
              6
              + Math.round(
                unitRandom(
                  seed,
                  key + ':setback',
                ) * 6,
              ),
            zone,
            density:
              localDensity,
            developmentOrder:
              unitRandom(
                seed,
                key + ':order',
              ),
            status: 'vacant',
            buildingId: null,
            reservedAt: null,
            frontageRoadId:
              road.id,
            frontageSide:
              side,
          });
        }

        sampleIndex += 1;
      }
    },
  );

  return candidates;
}

function validateParcels(
  candidates,
  roads,
  reservations,
) {
  const stops = [
    ...WORLD.line1Stops,
    ...WORLD.line2Stops.slice(1),
  ];

  const accepted = [];

  for (
    const parcel
    of candidates
  ) {
    const parcelBox = {
      x:
        parcel.x
        - parcel.w / 2,
      y:
        parcel.y
        - parcel.h / 2,
      w: parcel.w,
      h: parcel.h,
    };

    const reservedCollision =
      reservations.some(
        (reservation) =>
          boxesOverlap(
            parcelBox,
            reservationBox(
              reservation,
            ),
            0,
          ),
      );

    if (reservedCollision) {
      continue;
    }

    const stopCollision =
      stops.some(
        (stop) =>
          Math.hypot(
            parcel.x - stop.x,
            parcel.y - stop.y,
          ) < 72,
      );

    if (stopCollision) {
      continue;
    }

    const unrelatedRoadCollision =
      roads.some(
        (road) => {
          if (
            road.id
            === parcel.frontageRoadId
          ) {
            return false;
          }

          const clearance =
            road.class === 'arterial'
              ? 38
              : 24;

          return (
            distancePointToRoad(
              parcel,
              road,
            )
            < Math.max(
              parcel.w,
              parcel.h,
            ) / 2
              + clearance
          );
        },
      );

    if (unrelatedRoadCollision) {
      continue;
    }

    const parcelCollision =
      accepted.some(
        (candidate) =>
          boxesOverlap(
            parcelBox,
            {
              x:
                candidate.x
                - candidate.w / 2,
              y:
                candidate.y
                - candidate.h / 2,
              w: candidate.w,
              h: candidate.h,
            },
            10,
          ),
      );

    if (parcelCollision) {
      continue;
    }

    accepted.push(parcel);
  }

  return accepted;
}

function makeBlocks(
  parcels,
  districts,
) {
  const blocks = [];

  for (
    const district
    of districts
  ) {
    const districtParcels =
      parcels.filter(
        (parcel) =>
          parcel.districtId
          === district.id,
      );

    const groups =
      new Map();

    for (
      const parcel
      of districtParcels
    ) {
      const key =
        `${parcel.frontageRoadId}:`
        + `${parcel.frontageSide}`;

      if (!groups.has(key)) {
        groups.set(
          key,
          [],
        );
      }

      groups.get(key).push(
        parcel,
      );
    }

    const blockIds = [];

    let blockIndex = 1;

    for (
      const group
      of groups.values()
    ) {
      const id =
        `block-${district.id}-`
        + blockIndex;

      blockIds.push(id);

      const parcelIds =
        group.map(
          (parcel) =>
            parcel.id,
        );

      blocks.push({
        id,
        districtId:
          district.id,
        parcelIds,
        status: 'planned',
      });

      for (
        const parcel
        of group
      ) {
        parcel.blockId = id;
      }

      blockIndex += 1;
    }

    district.blockIds =
      blockIds;

    district.parcelIds =
      districtParcels.map(
        (parcel) =>
          parcel.id,
      );
  }

  return blocks;
}

export function generateCityMasterPlan(
  seed = 284731,
) {
  const nodes = [];
  const nodeByKey =
    new Map();

  const roads = [];
  const districts = [];
  const allCandidates = [];

  for (
    const spec
    of getPrimaryRoadSpecs()
  ) {
    roads.push(
      makeEdge(
        nodes,
        nodeByKey,
        spec,
      ),
    );
  }

  for (
    const spec
    of DISTRICT_SPECS
  ) {
    const blueprints =
      localRoadBlueprints(
        spec,
      );

    const roadIds = [];

    for (
      const blueprint
      of blueprints
    ) {
      roadIds.push(
        blueprint.id,
      );

      const road =
        makeEdge(
          nodes,
          nodeByKey,
          {
            id: blueprint.id,
            districtId:
              spec.id,
            roadClass: 'local',
            points:
              blueprint.points,
            unlock: {
              districtId:
                spec.id,
            },
            buildOrder:
              blueprint.buildOrder,
            source: 'city',
            parentRoadIds:
              blueprint.parentRoadIds,
          },
        );

      roads.push(road);
    }

    const localRoads =
      roads.filter(
        (road) =>
          roadIds.includes(
            road.id,
          ),
      );

    allCandidates.push(
      ...createParcelCandidates(
        seed,
        spec,
        localRoads,
      ),
    );

    const stop =
      getStop(spec);

    districts.push({
      id: spec.id,
      name: spec.name,
      lineKey:
        spec.lineKey,
      stopIndex:
        spec.stopIndex,
      theme:
        spec.theme,
      anchor: {
        x: stop.x,
        y: stop.y,
      },
      parentRoadId:
        spec.parentRoadId,
      roadIds,
      blockIds: [],
      parcelIds: [],
      status: 'locked',
      activatedAt: null,
      developmentLevel: 0,
    });
  }

  const reservations =
    createReservations();

  const parcels =
    validateParcels(
      allCandidates,
      roads,
      reservations,
    );

  const blocks =
    makeBlocks(
      parcels,
      districts,
    );

  return {
    seed,
    nodes,
    roads,
    districts,
    blocks,
    parcels,
    reservations,
  };
}

export function getDistrictDefinitions() {
  return DISTRICT_SPECS.map(
    (district) => ({
      id: district.id,
      name: district.name,
      lineKey:
        district.lineKey,
      stopIndex:
        district.stopIndex,
      theme:
        district.theme,
      parentRoadId:
        district.parentRoadId,
    }),
  );
}
